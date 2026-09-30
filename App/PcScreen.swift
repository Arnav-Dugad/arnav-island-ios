import AVFoundation
import AVKit
import CoreMedia
import IslandKit
import SwiftUI
import VideoToolbox

// ---- your PC's screen here ----

/// The PC's screen as it arrives (island 0.24): H.264 frames put back together, handed to the iPhone's hardware decoder
/// through a sample-buffer layer (which also gives Picture in Picture), with the PC told how it's keeping up.
final class ScreenStreamer: NSObject, Typist, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    enum State: Equatable { case connecting, showing(Int, Int), failed(String), ended }
    let layer = AVSampleBufferDisplayLayer()
    var onState: (State) -> Void = { _ in }
    var onStats: (Int, Int) -> Void = { _, _ in }
    private var session: ScreenSession?
    private var stopped = false
    private var format: CMVideoFormatDescription?
    private var waitingKey = true, askedKey = Date.distantPast
    private let sendQueue = DispatchQueue(label: "screen-send")

    override init() { super.init(); layer.videoGravity = .resizeAspect; layer.backgroundColor = UIColor.black.cgColor }

    func start(peer: String, pcName: String, revision: Int, longest: Int, shortest: Int) {
        Task { @MainActor in
            guard let opened = await Hub.shared.openScreen(ScreenWire.askPc(longest: longest, shortest: shortest, fps: 60)) else {
                self.onState(.failed(revision < 7 ? "Update Arnav Island on \(pcName) to 0.24 or later" : "Couldn’t reach \(pcName)")); return
            }
            let (s, answer) = opened
            if self.stopped { s.close(); return }
            let r = ScreenWire.reply(answer)
            guard let r, r.status == 0 else {
                self.onState(.failed(r?.status == 1 ? "Turn on “My phone can control this PC” on \(pcName)’s island" : r?.status == 2 ? "Update Arnav Island on \(pcName)" : "\(pcName) couldn’t show its screen")); s.close(); return
            }
            self.session = s; self.onState(.showing(r.width, r.height))
            Thread.detachNewThread { self.run(s, pcName: pcName) }
        }
    }
    private func send(_ f: [UInt8]) { let s = session; sendQueue.async { _ = s?.send(f) } }
    func frame(_ f: [UInt8]) { send(ScreenWire.input(f)) }
    func point(_ x: Double, _ y: Double) { frame(Frames.point(x, y)) }
    func button(_ b: Int, _ s: Int) { frame(Frames.button(b, s)) }
    func scroll(_ v: Int, _ h: Int) { frame(Frames.scroll(v, h)) }
    private func askKey() { if Date().timeIntervalSince(askedKey) > 0.5 { askedKey = Date(); send([UInt8(Proto.screenKeyframe)]) } }
    func stop() {
        stopped = true; let s = session; session = nil
        sendQueue.async { _ = s?.send([UInt8(Proto.screenStop)]); Thread.sleep(forTimeInterval: 0.2); s?.close() }
        layer.flushAndRemoveImage()
    }

    private func run(_ s: ScreenSession, pcName: String) {
        let assembler = ScreenWire.Assembler()
        var last = 0, shown = 0, bytes = 0, told = Date(), heard = Date()
        while !stopped && s.open {
            let now = Date()
            if now.timeIntervalSince(told) >= 0.5 {
                let secs = now.timeIntervalSince(told), kbps = Int(Double(bytes * 8) / 1000 / secs), fps = Int(Double(shown) / secs)
                send(ScreenWire.feedback(last: last, decodeMs: 4, kbps: kbps, fps: fps))
                DispatchQueue.main.async { self.onStats(fps, kbps) }
                told = now; shown = 0; bytes = 0
            }
            // The PC says something every second at least (frames, or a word when its screen is still).
            if now.timeIntervalSince(heard) > 6 { DispatchQueue.main.async { self.onState(.failed("Lost \(pcName)")) }; break }
            guard let f = s.receive(timeout: 0.25), !f.isEmpty else { continue }
            heard = Date()
            if f[0] == UInt8(Proto.screenStop) { DispatchQueue.main.async { self.onState(.ended) }; break }
            guard f[0] == UInt8(Proto.screenVideo) else { continue }
            bytes += f.count
            guard let frame = assembler.add(f) else { continue }
            last = frame.number
            if layer.status == .failed { layer.flush(); waitingKey = true; askKey() }
            if waitingKey && !frame.key { askKey(); continue }
            if enqueue(frame) { waitingKey = false; shown += 1 } else { waitingKey = true; askKey() }
        }
        if !s.open && !stopped { DispatchQueue.main.async { self.onState(.failed("Lost \(pcName)")) } }
        s.close()
    }

    /// An Annex B frame as a sample: its parameter sets (on key frames) make the format; its slices get length prefixes.
    private func enqueue(_ frame: ScreenWire.Frame) -> Bool {
        let d = frame.data; let units = ScreenWire.nals(d)
        var sps: [UInt8]?, pps: [UInt8]?, avcc: [UInt8] = []
        for (type, start, end) in units {
            switch type {
            case 7: sps = Array(d[start..<end])
            case 8: pps = Array(d[start..<end])
            case 9, 6: continue
            default:
                let n = end - start; avcc.append(contentsOf: [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)]); avcc.append(contentsOf: d[start..<end])
            }
        }
        if let sps, let pps {
            var f: CMVideoFormatDescription?
            let ok = sps.withUnsafeBufferPointer { s in pps.withUnsafeBufferPointer { p -> OSStatus in
                let pointers = [s.baseAddress!, p.baseAddress!], sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &f)
            } }
            if ok == noErr, let f { format = f }
        }
        guard let format, !avcc.isEmpty else { return false }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return false }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?; var size = avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(frame.pts), timescale: 10_000_000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !frame.key { CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()) }
        }
        layer.enqueue(sample)
        return layer.status != .failed
    }

    // Picture in Picture: live, always playing.
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}

/// The sample-buffer layer as a view.
struct ScreenLayerView: UIViewRepresentable {
    let streamer: ScreenStreamer
    func makeUIView(context: Context) -> Host { let v = Host(); v.backgroundColor = .black; v.layer.addSublayer(streamer.layer); return v }
    func updateUIView(_ v: Host, context: Context) {}
    final class Host: UIView { override func layoutSubviews() { super.layoutSubviews(); CATransaction.begin(); CATransaction.setDisableActions(true); layer.sublayers?.forEach { $0.frame = bounds }; CATransaction.commit() } }
}

/// Your PC's screen here, as sharp and smooth as the path allows. Touch it like a touchscreen: a tap clicks, a long press
/// right-clicks, a drag drags, two fingers scroll, and pinching zooms in here (not on the PC). Picture in Picture keeps it
/// showing over other apps. The screen stays awake while it shows.
struct PcScreenView: View {
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss
    @State private var streamer = ScreenStreamer()
    @State private var state: ScreenStreamer.State = .connecting
    @State private var stats = (0, 0)
    @State private var bar = true
    @State private var typing = false
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var attempt = 0
    @State private var pip: AVPictureInPictureController?
    @State private var hideBar: Task<Void, Never>?

    var body: some View {
        let pc = hub.pc()
        GeometryReader { g in
            ZStack {
                Color.black.ignoresSafeArea()
                ScreenLayerView(streamer: streamer).id(ObjectIdentifier(streamer))
                    .scaleEffect(zoom).offset(pan)
                    .opacity(isShowing ? 1 : 0).animation(.easeOut(duration: 0.3), value: isShowing)
                    .ignoresSafeArea()
                ScreenTouch(size: g.size, video: videoSize, zoom: zoom, pan: pan, streamer: streamer, onTouch: touched,
                            onPinch: { scale, delta, began in
                                if began { zoomStart = zoom; panStart = pan }
                                let z = max(1, min(4, zoomStart * scale)); zoom = z
                                pan = z <= 1.01 ? .zero : CGSize(width: panStart.width + delta.width, height: panStart.height + delta.height)
                            })
                    .ignoresSafeArea()
                overlay(pc)
                VStack(spacing: 8) {
                    if bar || !isShowing { topBar(pc).transition(.move(edge: .top).combined(with: .opacity)) }
                    Spacer()
                    if typing { VStack(spacing: 8) { KeysRow(input: streamer); TypingField(input: streamer, pcName: pc?.name ?? "your PC") }.padding(.horizontal, 12).transition(.move(edge: .bottom).combined(with: .opacity)) }
                    if !bar && isShowing && !typing { Capsule().fill(.white.opacity(0.5)).frame(width: 60, height: 5).padding(.bottom, 6).onTapGesture { touched() } }
                }
                .padding(.top, 6).padding(.bottom, 8)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: bar)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: typing)
            }
        }
        .statusBarHidden(!bar)
        .persistentSystemOverlays(.hidden)
        .onAppear { start() }
        .onDisappear { streamer.stop(); UIApplication.shared.isIdleTimerDisabled = false; KeepAlive.shared.restoreSession() }
        .onChange(of: attempt) { _, _ in streamer.stop(); streamer = ScreenStreamer(); start() }
    }

    private var isShowing: Bool { if case .showing = state { return true }; return false }
    private var videoSize: CGSize { if case let .showing(w, h) = state { return CGSize(width: w, height: h) }; return CGSize(width: 16, height: 9) }
    private func start() {
        guard let pc = hub.pc() else { state = .failed("Pair with your PC first"); return }
        UIApplication.shared.isIdleTimerDisabled = true
        let screen = DeviceInfo.currentScreen, scale = min(3, screen?.scale ?? 3), b = screen?.bounds.size ?? CGSize(width: 393, height: 852)
        streamer.onState = { s in withAnimation { state = s } }
        streamer.onStats = { fps, kbps in stats = (fps, kbps) }
        state = .connecting
        streamer.start(peer: pc.id, pcName: pc.name, revision: pc.revision, longest: Int(max(b.width, b.height) * scale), shortest: Int(min(b.width, b.height) * scale))
        // Picture in Picture, when the iPhone has it.
        if AVPictureInPictureController.isPictureInPictureSupported() {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers]); try? AVAudioSession.sharedInstance().setActive(true)
            let c = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: streamer.layer, playbackDelegate: streamer))
            c.canStartPictureInPictureAutomaticallyFromInline = true; pip = c
        }
        touched()
    }
    private func touched() {
        bar = true; hideBar?.cancel()
        hideBar = Task { try? await Task.sleep(for: .seconds(3.5)); if !Task.isCancelled && !typing { bar = false } }
    }

    @ViewBuilder private func overlay(_ pc: PeerView?) -> some View {
        switch state {
        case .connecting:
            VStack(spacing: 12) {
                Radar(size: 60)
                Text("Opening \(pc?.name ?? "your PC")’s screen…").font(TypeScale.body).foregroundStyle(.white)
                Text(pc?.lan == true ? "On this Wi-Fi" : "Through the relay: it takes a moment to start").font(TypeScale.caption).foregroundStyle(.white.opacity(0.6))
            }
        case .failed(let why):
            VStack(spacing: 14) {
                Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 44)).foregroundStyle(t.warn)
                Text(why).font(TypeScale.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    GlassButton(action: { dismiss() }) { Text("Close").font(TypeScale.bodyStrong) }
                    GlassButton(prominent: true, action: { attempt += 1 }) { Text("Try again").font(TypeScale.bodyStrong) }
                }
            }
            .padding(32)
        case .ended:
            VStack(spacing: 16) { Text("\(pc?.name ?? "Your PC") stopped showing its screen").font(TypeScale.headline).foregroundStyle(.white); GlassButton(action: { dismiss() }) { Text("Close").font(TypeScale.bodyStrong) } }
        case .showing: EmptyView()
        }
    }
    private func topBar(_ pc: PeerView?) -> some View {
        HStack(spacing: 10) {
            GlassIconButton(symbol: "chevron.down", label: "Close", size: 40, iconSize: 16) { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text(pc?.name ?? "Your PC").font(TypeScale.bodyStrong).foregroundStyle(.white).lineLimit(1)
                Text([pc.map { Quality.of($0, t).text } ?? "", isShowing ? "\(Int(videoSize.width))×\(Int(videoSize.height))" : "", stats.0 > 0 ? "\(stats.0) fps" : "", stats.1 > 0 ? String(format: "%.1f Mbps", Double(stats.1) / 1000) : ""].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(TypeScale.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
            if zoom > 1.01 { GlassIconButton(symbol: "arrow.down.right.and.arrow.up.left", label: "Fit the screen", size: 40, iconSize: 15) { withAnimation(.spring(response: 0.4)) { zoom = 1; pan = .zero } } }
            if let pip { GlassIconButton(symbol: "pip.enter", label: "Picture in Picture", size: 40, iconSize: 16) { pip.startPictureInPicture() } }
            GlassIconButton(symbol: "keyboard", label: typing ? "Hide the keyboard" : "Type", size: 40, iconSize: 16, prominent: typing) { typing.toggle(); touched() }
        }
        .padding(8)
        .glass(Capsule(), .bar)
        .padding(.horizontal, 12)
        .environment(\.colorScheme, .dark)
    }
}

/// Touches on the PC's screen, turned into its pointer: where on its screen each lands (through the zoom and the letterbox).
struct ScreenTouch: UIViewRepresentable {
    let size: CGSize; let video: CGSize; let zoom: CGFloat; let pan: CGSize; let streamer: ScreenStreamer
    let onTouch: () -> Void; let onPinch: (CGFloat, CGSize, Bool) -> Void
    func makeUIView(context: Context) -> Surface { let v = Surface(); v.isMultipleTouchEnabled = true; v.backgroundColor = .clear; update(v); return v }
    func updateUIView(_ v: Surface, context: Context) { update(v) }
    private func update(_ v: Surface) { v.video = video; v.zoom = zoom; v.pan = pan; v.streamer = streamer; v.onTouch = onTouch; v.onPinch = onPinch }
    final class Surface: UIView {
        var video = CGSize(width: 16, height: 9), zoom: CGFloat = 1, pan = CGSize.zero
        weak var streamer: ScreenStreamer?
        var onTouch: () -> Void = {}, onPinch: (CGFloat, CGSize, Bool) -> Void = { _, _, _ in }
        private var active = Set<UITouch>(), mode = 0, start = CGPoint.zero, t0: TimeInterval = 0, long: DispatchWorkItem?
        private var spanStart: CGFloat = 1, centreStart = CGPoint.zero, centreLast = CGPoint.zero, wheel: CGFloat = 0, zooming = false
        private func toScreen(_ p: CGPoint) -> (Double, Double) {
            let s = min(bounds.width / video.width, bounds.height / video.height), w = video.width * s, h = video.height * s
            let rx = (bounds.width - w) / 2, ry = (bounds.height - h) / 2, cx = bounds.width / 2, cy = bounds.height / 2
            let qx = (p.x - pan.width - cx) / zoom + cx, qy = (p.y - pan.height - cy) / zoom + cy
            return (Double(max(0, min(1, (qx - rx) / w))), Double(max(0, min(1, (qy - ry) / h))))
        }
        private var points: [CGPoint] { active.map { $0.location(in: self) } }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            active.formUnion(touches); MainActor.assumeIsolated { onTouch() }
            if active.count == 1, let t = touches.first {
                mode = 0; start = t.location(in: self); t0 = t.timestamp; wheel = 0; zooming = false
                long?.cancel()
                // Held still: a right click.
                let w = DispatchWorkItem { [weak self] in guard let self, self.mode == 0, self.active.count == 1 else { return }; self.mode = 3; let p = self.toScreen(self.start); self.streamer?.point(p.0, p.1); self.streamer?.button(1, 2); MainActor.assumeIsolated { Haptics.thud() } }
                long = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
            } else if active.count == 2 {
                long?.cancel()
                if mode == 1 { streamer?.button(0, 0) }
                let p = points; mode = 2; spanStart = max(1, hypot(p[0].x - p[1].x, p[0].y - p[1].y))
                centreStart = CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2); centreLast = centreStart
                MainActor.assumeIsolated { onPinch(1, .zero, true) }
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if active.count >= 2 && mode == 2 {
                let p = points, span = hypot(p[0].x - p[1].x, p[0].y - p[1].y), c = CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2)
                // Spreading or pinching zooms the picture here; moving together scrolls on the PC (or pans a zoomed picture).
                if !zooming && abs(span / spanStart - 1) > 0.08 { zooming = true }
                if zooming || zoom > 1.01 { let d = CGSize(width: c.x - centreStart.x, height: c.y - centreStart.y); MainActor.assumeIsolated { onPinch(zooming ? span / spanStart : 1, d, false) } }
                else { wheel += (c.y - centreLast.y) * 3; let w = Int(wheel / 40); if w != 0 { streamer?.scroll(w * 40, 0); wheel -= CGFloat(w * 40) } }
                centreLast = c; return
            }
            guard let t = touches.first else { return }
            let now = t.location(in: self)
            if mode == 0 && hypot(now.x - start.x, now.y - start.y) > 8 { mode = 1; long?.cancel(); let p0 = toScreen(start); streamer?.point(p0.0, p0.1); streamer?.button(0, 1) }
            if mode == 1 { let p = toScreen(now); streamer?.point(p.0, p.1) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            active.subtract(touches); guard active.isEmpty, let t = touches.first else { return }
            long?.cancel()
            if mode == 0 && t.timestamp - t0 < 0.45 { let p = toScreen(start); streamer?.point(p.0, p.1); streamer?.button(0, 2); MainActor.assumeIsolated { Haptics.tick() } }
            if mode == 1 { let p = toScreen(t.location(in: self)); streamer?.point(p.0, p.1); streamer?.button(0, 0) }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { active.subtract(touches); long?.cancel(); if mode == 1 && active.isEmpty { streamer?.button(0, 0) } }
    }
}

// ---- this iPhone's camera on your PC ----

/// This iPhone's camera in a window on your PC (island 0.24): encoded as H.264 by the iPhone's own encoder, sent as the
/// "phone screen" the island shows in its floating window. Sized and paced for the path: 1280 on its long side at 30 frames
/// a second, its bit rate following the PC's feedback.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let capture = AVCaptureSession()
    var onState: (String?) -> Void = { _ in }
    private var session: ScreenSession?
    private var compressor: VTCompressionSession?
    private var running = false, wantKey = true, number = 0, acked = 0, heard = false, lastHeard = Date(), lastSent = Date()
    private var bitrate = 1_200_000, lastCheck = Date(), lastUp = Date(), slow = 0
    private let fps = 30, least = 300_000, most = 3_000_000
    private let queue = DispatchQueue(label: "camera"), sendQueue = DispatchQueue(label: "camera-send")
    private var width = 1280, height = 720
    var front = false

    func start(peer: PeerView, name: String) {
        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .video) else { self.onState("Allow the camera in Settings › Arnav Island"); return }
            guard let opened = await Hub.shared.openScreen(ScreenWire.offerPhone(width: self.width, height: self.height, fps: self.fps, name: "\(name)’s camera")) else {
                self.onState(peer.revision < 7 ? "Update Arnav Island on \(peer.name) to 0.24 or later" : "Couldn’t reach \(peer.name)"); return
            }
            let (s, answer) = opened
            guard let r = ScreenWire.reply(answer), r.status == 0 else { s.close(); self.onState("Turn on “My phone can control this PC” on \(peer.name)’s island"); return }
            self.session = s; self.running = true
            self.queue.async { self.setUp() }
            Thread.detachNewThread { self.listen(s) }
            self.onState(nil)
        }
    }
    private func setUp() {
        capture.beginConfiguration(); capture.sessionPreset = .hd1280x720
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back), let input = try? AVCaptureDeviceInput(device: cam), capture.canAddInput(input) {
            capture.addInput(input)
            if (try? cam.lockForConfiguration()) != nil { cam.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps)); cam.unlockForConfiguration() }
        }
        let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(self, queue: queue)
        if capture.canAddOutput(out) { capture.addOutput(out) }
        if let c = out.connection(with: .video) { if c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 }; if front { c.isVideoMirrored = true } }
        capture.commitConfiguration()
        makeCompressor()
        capture.startRunning()
    }
    private func makeCompressor() {
        var c: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &c)
        guard let c else { return }
        VTSessionSetProperty(c, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(c, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(c, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(c, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(c, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(c, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTCompressionSessionPrepareToEncodeFrames(c); compressor = c
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let c = compressor, let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        var props: CFDictionary?
        if wantKey { wantKey = false; props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary }
        VTCompressionSessionEncodeFrame(c, imageBuffer: image, presentationTimeStamp: pts, duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, buffer in
            guard let self, status == noErr, let buffer else { return }
            self.encoded(buffer)
        }
        pace()
    }
    /// An encoded frame as Annex B (start codes, parameter sets before key frames), in the frames that carry it.
    private func encoded(_ b: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(b, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        // A PC two seconds behind: nothing more until a key frame, so it catches up instead of lagging.
        if heard && number - acked > fps * 2 && !key { wantKey = true; return }
        var out: [UInt8] = []
        let start: [UInt8] = [0, 0, 0, 1]
        if key, let f = CMSampleBufferGetFormatDescription(b) {
            for i in 0..<2 {
                var p: UnsafePointer<UInt8>?; var n = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(f, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p { out += start; out += UnsafeBufferPointer(start: p, count: n) }
            }
        }
        guard let data = CMSampleBufferGetDataBuffer(b) else { return }
        var length = 0; var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { return }
        let raw = UnsafeRawPointer(pointer)
        var at = 0
        while at + 4 <= length {
            let n = Int(raw.load(fromByteOffset: at, as: UInt32.self).bigEndian); at += 4
            guard n > 0, at + n <= length else { break }
            out += start; out += UnsafeRawBufferPointer(start: raw + at, count: n).map { $0 }; at += n
        }
        number += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(b)
        let frames = ScreenWire.frames(number: number, key: key, pts100ns: UInt64(max(0, pts.seconds) * 10_000_000), data: out)
        let s = session; let t0 = Date()
        sendQueue.async { [weak self] in for f in frames { _ = s?.send(f) }; self?.lastSent = Date(); if Date().timeIntervalSince(t0) > 1.5 / Double(self?.fps ?? 30) { self?.slow += 1 } else { self?.slow = max(0, (self?.slow ?? 1) - 1) } }
    }
    /// The bit rate follows the path; a word every second keeps the PC from giving up.
    private func pace() {
        let now = Date()
        if now.timeIntervalSince(lastSent) >= 1 { let s = session; let l = ScreenWire.limits(width: width, height: height, fps: fps); sendQueue.async { _ = s?.send(l) }; lastSent = now }
        guard now.timeIntervalSince(lastCheck) >= 0.5, let c = compressor else { return }
        lastCheck = now; let behind = heard && number - acked > fps
        var next = bitrate
        if slow >= 3 || behind { next = max(least, bitrate * 3 / 4); slow = 0; lastUp = now } else if now.timeIntervalSince(lastUp) >= 4 && bitrate < most { next = min(most, bitrate * 115 / 100); lastUp = now }
        if next != bitrate { bitrate = next; VTSessionSetProperty(c, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate)) }
    }
    private func listen(_ s: ScreenSession) {
        while running && s.open {
            guard let f = s.receive(timeout: 0.5), !f.isEmpty else { if Date().timeIntervalSince(lastHeard) > 8 { break }; continue }
            lastHeard = Date(); let r = Reader(f)
            switch r.u8() {
            case Proto.screenFeedback: acked = r.u32() ?? 0; heard = true
            case Proto.screenKeyframe: wantKey = true
            case Proto.screenStop: running = false
            default: break
            }
        }
        if running { DispatchQueue.main.async { self.onState("The camera stopped on your PC") } }
        stop()
    }
    func stop() {
        guard running || session != nil else { return }
        running = false
        queue.async { [weak self] in
            guard let self else { return }
            self.capture.stopRunning()
            if let c = self.compressor { VTCompressionSessionInvalidate(c) }; self.compressor = nil
            let s = self.session; self.session = nil
            self.sendQueue.async { _ = s?.send([UInt8(Proto.screenStop)]); Thread.sleep(forTimeInterval: 0.3); s?.close() }
        }
    }
}

/// The camera's own view while it shows on the PC: a live preview, flip, and stop.
struct CameraToPCView: View {
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss
    @State private var streamer = CameraStreamer()
    @State private var problem: String?
    @State private var live = false
    var body: some View {
        let pc = hub.pc()
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: streamer.capture).id(ObjectIdentifier(streamer)).ignoresSafeArea()
            VStack {
                HStack {
                    GlassIconButton(symbol: "xmark", label: "Stop", size: 44, iconSize: 16) { streamer.stop(); dismiss() }
                    Spacer()
                    if live { Label("LIVE ON \((pc?.name ?? "YOUR PC").uppercased())", systemImage: "record.circle").font(TypeScale.micro).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8).background(Capsule().fill(.red.opacity(0.85))).symbolEffect(.pulse) }
                    Spacer()
                    GlassIconButton(symbol: "arrow.triangle.2.circlepath.camera", label: "Flip the camera", size: 44, iconSize: 17) { flip() }
                }
                .padding(16)
                Spacer()
                if let problem {
                    Text(problem).font(TypeScale.bodyStrong).foregroundStyle(.white).multilineTextAlignment(.center).padding(18).glass(RoundedRectangle(cornerRadius: 22, style: .continuous), .bar).padding(24)
                } else if !live { HStack(spacing: 10) { ProgressView().tint(.white); Text("Opening a window on \(pc?.name ?? "your PC")…").foregroundStyle(.white) }.padding(16).glassCapsule(.bar, interactive: false).padding(24) }
                else { Text("In a window on \(pc?.name ?? "your PC"). Close this to stop.").font(TypeScale.caption).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 30) }
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { go() }
        .onDisappear { streamer.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func go() {
        guard let pc = hub.pc() else { problem = "Pair with your PC first"; return }
        UIApplication.shared.isIdleTimerDisabled = true
        streamer.onState = { p in withAnimation { problem = p; live = p == nil } ; if p == nil { Haptics.success() } }
        streamer.start(peer: pc, name: hub.phoneName())
    }
    private func flip() { Haptics.tap(); let front = !streamer.front; streamer.stop(); live = false; let s = CameraStreamer(); s.front = front; streamer = s; go() }
}
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> V { let v = V(); v.preview.session = session; v.preview.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ v: V, context: Context) { v.preview.session = session }
    final class V: UIView { override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }; var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer } }
}

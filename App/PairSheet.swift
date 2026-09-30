import AVFoundation
import IslandKit
import SwiftUI

/// Pairing, from anywhere: the island's own code (Shelf › Nearby › Pair with a code), scanned from its QR code (which names
/// that PC's key, so only the PC asks to confirm) or typed. Both then show the same six digits, which roll in here.
struct PairSheet: View {
    @State var start: PairStart
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss
    @State private var mode: PairStart = .scan

    private enum Stage: Equatable { case type, scan, finding, code, done }
    private var stage: Stage {
        if hub.pairResult?.ok == true { return .done }
        if hub.pairCode != nil { return .code }
        switch mode { case .type: return .type; case .scan: return .scan; case .finding: return .finding }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch stage {
                case .type: CodeEntry(connecting: hub.codePairing != nil, error: error, onScan: { hub.pairResult = nil; mode = .scan }) { hub.pairWithCode($0) }
                case .scan: ScanPane(onLink: { l in Haptics.success(); hub.pairWithCode(l.code, key: l.key); mode = .finding }, onType: { hub.pairResult = nil; mode = .type })
                case .finding: finding
                case .code: codeView
                case .done: done
                }
            }
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(y: 12)), removal: .opacity.combined(with: .scale(scale: 1.02))))
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.84), value: stage)
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .onAppear { mode = start; if start != .finding { hub.pairResult = nil } }
        .onChange(of: hub.codePairing) { _, c in if c != nil && mode != .type { mode = .finding } }
        .onChange(of: hub.pairResult?.ok) { _, ok in if ok == true { Task { try? await Task.sleep(for: .seconds(1.6)); dismiss() } } }
        .onDisappear { if let c = hub.pairCode, !c.confirmed { hub.confirmPair(false) } }
    }
    private var error: String? { hub.pairResult.flatMap { $0.ok ? nil : $0.detail } }

    /// A scanned (or opened) pairing link's PC being found over the internet: a laptop in glass with the radar sweeping round it.
    private var finding: some View {
        VStack(spacing: 6) {
            Text(error == nil ? "Finding your PC" : "Not paired").font(TypeScale.title).foregroundStyle(t.text)
            Text(error ?? "Over the internet, end-to-end encrypted. Keep the code showing on your PC").font(TypeScale.caption).foregroundStyle(error == nil ? t.muted : t.danger).multilineTextAlignment(.center)
            ZStack {
                if error == nil { Radar(size: 230) }
                Image(systemName: "laptopcomputer").font(.system(size: 28, weight: .semibold)).foregroundStyle(error == nil ? t.accent : t.danger)
                    .frame(width: 70, height: 70).glass(Circle(), .control, tint: error == nil ? t.accent : t.danger)
                    .symbolEffect(.pulse, options: .repeating, isActive: error == nil)
            }
            .frame(height: error == nil ? 260 : 150)
            if error != nil {
                HStack(spacing: 10) {
                    GlassButton(prominent: true, action: { hub.pairResult = nil; mode = .scan }) { Image(systemName: "qrcode.viewfinder"); Text("Scan again").font(TypeScale.caption) }
                    GlassButton(action: { hub.pairResult = nil; mode = .type }) { Image(systemName: "keyboard"); Text("Type the code").font(TypeScale.caption) }
                }
            } else { GlassButton(action: { dismiss() }) { Text("Hide").font(TypeScale.caption) } }
        }
    }
    private var codeView: some View {
        let c = hub.pairCode!
        let digits = String(format: "%06d", c.code)
        return VStack(spacing: 6) {
            Text(c.confirmed ? "Confirm on \(c.name)" : "Pair with \(c.name)?").font(TypeScale.title).foregroundStyle(t.text).multilineTextAlignment(.center)
            Text(c.confirmed ? "It shows the same code. Choose Pair there to finish" : "Check that \(c.name) shows the same code").font(TypeScale.caption).foregroundStyle(t.muted).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                ForEach(Array(digits.enumerated()), id: \.offset) { i, ch in
                    if i == 3 { Spacer().frame(width: 8) }
                    Text(String(ch)).font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(t.text)
                        .frame(width: 40, height: 62).glass(RoundedRectangle(cornerRadius: 14, style: .continuous), .control)
                        .transition(.asymmetric(insertion: .push(from: .bottom), removal: .opacity))
                        .id("\(i)\(ch)")
                }
            }
            .padding(.top, 26)
            .onAppear { Haptics.notify() }
            Spacer().frame(height: 30)
            if c.confirmed {
                HStack(spacing: 10) { ProgressView(); Text("Waiting for \(c.name)…").font(TypeScale.caption).foregroundStyle(t.muted) }
            } else {
                HStack(spacing: 12) {
                    GlassButton(action: { hub.confirmPair(false); dismiss() }) { Text("Not now").font(TypeScale.bodyStrong) }.frame(maxWidth: .infinity)
                    GlassButton(prominent: true, action: { Haptics.success(); hub.confirmPair(true) }) { Text("Pair").font(TypeScale.bodyStrong) }.frame(maxWidth: .infinity)
                }
            }
        }
    }
    private var done: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 50, weight: .bold)).foregroundStyle(t.good)
                .frame(width: 100, height: 100).background(Circle().fill(t.good.opacity(0.2)))
                .symbolEffect(.bounce, options: .nonRepeating).padding(.top, 30)
                .transition(.scale.combined(with: .opacity))
            Text("Paired with \(hub.pairResult?.name.isEmpty == false ? hub.pairResult!.name : "your PC")").font(TypeScale.title).foregroundStyle(t.text).padding(.top, 18)
            Text("Files, music and the remote are ready").font(TypeScale.caption).foregroundStyle(t.muted)
        }
        .sensoryFeedback(.success, trigger: hub.pairResult?.ok)
    }
}

/// A radar sweeping round, looking.
struct Radar: View {
    var size: CGFloat = 40
    @Environment(\.tokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40, paused: reduce)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3) { i in
                    let k = (time / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(t.accent.opacity(0.5 * (1 - k)), lineWidth: 1.5).scaleEffect(0.2 + 0.8 * k)
                }
                Circle().fill(AngularGradient(colors: [t.accent.opacity(0.35), .clear, .clear], center: .center)).rotationEffect(.degrees(time * 120))
                    .mask(Circle())
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// The island's pairing code, typed: eight letters and digits in two groups, each landing in its own glass cell.
struct CodeEntry: View {
    let connecting: Bool; let error: String?; var onScan: () -> Void; var onCode: (String) -> Void
    @Environment(\.tokens) private var t
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 6) {
            Text("Pair with a code").font(TypeScale.title).foregroundStyle(t.text)
            Text("On your PC, open the island’s Shelf › Nearby › Pair with a code, then type the code it shows. Any network works.").font(TypeScale.caption).foregroundStyle(t.muted).multilineTextAlignment(.center)
            ZStack {
                TextField("", text: $text).focused($focused).keyboardType(.asciiCapable).textInputAutocapitalization(.characters).autocorrectionDisabled().textContentType(.oneTimeCode)
                    .opacity(0.02).frame(width: 1, height: 1).disabled(connecting)
                    .onChange(of: text) { old, v in
                        let clean = String(v.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
                        if clean != v { text = clean; return }
                        if clean.count > old.count { Haptics.tick() }
                        if clean.count == 8 && !connecting, let code = Pairing.code(clean) { onCode(code) }
                    }
                HStack(spacing: 6) {
                    ForEach(0..<8, id: \.self) { i in
                        if i == 4 { Text("–").font(TypeScale.headline).foregroundStyle(t.faint).padding(.horizontal, 4) }
                        let ch = i < text.count ? String(text[text.index(text.startIndex, offsetBy: i)]) : ""
                        Text(ch).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(t.text)
                            .frame(width: 34, height: 48)
                            .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), .control, tint: i == text.count && !connecting && focused ? t.accent : nil)
                            .scaleEffect(ch.isEmpty ? 1 : 1.0).animation(.spring(response: 0.25, dampingFraction: 0.5), value: ch)
                    }
                }
                .contentShape(Rectangle()).onTapGesture { focused = true }
            }
            .padding(.top, 22)
            Group {
                if connecting { HStack(spacing: 10) { ProgressView(); Text("Finding your PC over the internet…").font(TypeScale.caption).foregroundStyle(t.muted) } }
                else if let error { Text(error).font(TypeScale.caption).foregroundStyle(t.danger).multilineTextAlignment(.center) }
                else { Text("Encrypted end to end. The relay passes sealed bytes only.").font(TypeScale.caption).foregroundStyle(t.faint) }
            }
            .padding(.top, 20)
            GlassButton(action: onScan) { Image(systemName: "qrcode.viewfinder"); Text("Scan instead").font(TypeScale.caption) }.padding(.top, 16)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
        .onChange(of: error) { _, e in if e != nil { text = "" } }
    }
}

/// The camera, reading the island's QR code (a pairing link) as soon as it's in view.
struct ScanPane: View {
    var onLink: (PairLink) -> Void; var onType: () -> Void
    @Environment(\.tokens) private var t
    @State private var state = "looking"
    @State private var found = false
    var body: some View {
        VStack(spacing: 6) {
            Text("Scan the QR code").font(TypeScale.title).foregroundStyle(t.text)
            Text("On your PC: the island’s Shelf › Nearby › Pair with a code").font(TypeScale.caption).foregroundStyle(t.muted).multilineTextAlignment(.center)
            ZStack {
                QRScanner { text in
                    if let l = Pairing.link(text) { found = true; onLink(l); return true }
                    if state != "wrong" { state = "wrong"; Haptics.error(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state = "looking" } }
                    return false
                } denied: { state = "denied" }
                Finder(found: found)
                if state == "denied" {
                    VStack(spacing: 8) { Image(systemName: "camera.fill").font(.system(size: 28)); Text("Allow the camera in Settings › Arnav Island, or type the code").font(TypeScale.caption).multilineTextAlignment(.center) }
                        .foregroundStyle(.white).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.7))
                } else if state == "wrong" {
                    Text("That isn’t an island’s pairing code").font(TypeScale.caption).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8).glassCapsule(interactive: false)
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(.white.opacity(0.15)))
            .padding(.top, 16)
            .animation(.spring(response: 0.4), value: state)
            HStack(spacing: 10) {
                GlassButton(action: onType) { Image(systemName: "keyboard"); Text("Type the code").font(TypeScale.caption) }
                GlassButton(action: {
                    if let s = UIPasteboard.general.string, let l = Pairing.link(s) { onLink(l) } else { state = "wrong"; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state = "looking" } }
                }) { Image(systemName: "doc.on.clipboard"); Text("Paste a link").font(TypeScale.caption) }
            }
            .padding(.top, 16)
            Text("Or point the iPhone’s own Camera at the island’s QR code: it opens here.").font(TypeScale.caption).foregroundStyle(t.faint).multilineTextAlignment(.center).padding(.top, 10)
        }
    }
}
/// The finder's corners, breathing; they close in on the code once it's read.
struct Finder: View {
    let found: Bool
    @Environment(\.tokens) private var t
    @State private var breathe = false
    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height) * (found ? 0.5 : breathe ? 0.66 : 0.62), len = side * 0.18
            ZStack {
                ForEach(0..<4) { i in
                    Path { p in p.move(to: CGPoint(x: 0, y: len)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: len, y: 0)) }
                        .stroke(found ? t.good : .white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .frame(width: len, height: len)
                        .rotationEffect(.degrees(Double(i) * 90))
                        .offset(x: (i == 0 || i == 3 ? -1 : 1) * (side / 2 - len / 2), y: (i < 2 ? -1 : 1) * (side / 2 - len / 2))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: found)
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true } }
        .allowsHitTesting(false)
    }
}

/// The camera looking for QR codes (AVFoundation's own reader).
struct QRScanner: UIViewRepresentable {
    /// A code seen: true when it was the one wanted (the camera stops).
    let onCode: (String) -> Bool
    let denied: () -> Void
    func makeUIView(context: Context) -> Preview { let v = Preview(); v.start(onCode: onCode, denied: denied); return v }
    func updateUIView(_ v: Preview, context: Context) {}
    static func dismantleUIView(_ v: Preview, coordinator: ()) { v.stop() }

    final class Preview: UIView, AVCaptureMetadataOutputObjectsDelegate {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private let session = AVCaptureSession()
        private var onCode: ((String) -> Bool)?
        private var last = ""
        func start(onCode: @escaping (String) -> Bool, denied: @escaping () -> Void) {
            self.onCode = onCode
            (layer as! AVCaptureVideoPreviewLayer).session = session
            (layer as! AVCaptureVideoPreviewLayer).videoGravity = .resizeAspectFill
            AVCaptureDevice.requestAccess(for: .video) { ok in
                guard ok else { DispatchQueue.main.async { denied() }; return }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self, let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), let input = try? AVCaptureDeviceInput(device: cam) else { return }
                    self.session.beginConfiguration()
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    let out = AVCaptureMetadataOutput()
                    if self.session.canAddOutput(out) { self.session.addOutput(out); out.setMetadataObjectsDelegate(self, queue: .main); out.metadataObjectTypes = [.qr] }
                    self.session.commitConfiguration()
                    if (try? cam.lockForConfiguration()) != nil { if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }; cam.unlockForConfiguration() }
                    self.session.startRunning()
                }
            }
        }
        func stop() { let s = session; DispatchQueue.global().async { s.stopRunning() } }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, code != last else { return }
            last = code
            if onCode?(code) == true { stop() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.last = "" } }
        }
    }
}

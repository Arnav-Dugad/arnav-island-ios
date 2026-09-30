import AVFoundation
import MediaPlayer
import UIKit

/// Find my iPhone, from your PC: a bright chime that rings even on silent and at full volume, a heartbeat felt in the hand,
/// the flashlight blinking, and a glowing screen, until it's found (or a minute passes).
@MainActor
final class Ringer {
    static let shared = Ringer()
    private(set) var ringing = false
    private var engine: AVAudioEngine?, node: AVAudioPlayerNode?
    private let pulse = HapticPulse()
    private var torch: Task<Void, Never>?, timeout: Task<Void, Never>?
    private var volumeBefore: Float?
    private init() {}

    func start(from name: String) {
        if ringing { return }
        ringing = true; Hub.shared.ringing = name
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.duckOthers]); try? s.setActive(true)
        volumeBefore = s.outputVolume; SystemVolume.set(1)
        let e = AVAudioEngine(), n = AVAudioPlayerNode(); e.attach(n)
        if let buffer = Self.chime() {
            e.connect(n, to: e.mainMixerNode, format: buffer.format)
            n.scheduleBuffer(buffer, at: nil, options: .loops)
            if (try? e.start()) != nil { n.play(); engine = e; node = n }
        }
        pulse.start()
        if UIApplication.shared.applicationState == .active { torch = Task { await blink() } } else { Notify.ring(name: name) }
        timeout = Task { try? await Task.sleep(for: .seconds(60)); if !Task.isCancelled { stop() } }
    }
    func stop() {
        guard ringing else { return }
        ringing = false; Hub.shared.ringing = nil
        node?.stop(); engine?.stop(); engine = nil; node = nil
        pulse.stop(); torch?.cancel(); torch = nil; timeout?.cancel(); timeout = nil; setTorch(false)
        if let v = volumeBefore { SystemVolume.set(v) }; volumeBefore = nil
        Notify.cancel(Notify.ringId)
        KeepAlive.shared.restoreSession()
        Haptics.success()
    }

    private func blink() async {
        var on = false
        while !Task.isCancelled && ringing { on.toggle(); setTorch(on); try? await Task.sleep(for: .milliseconds(on ? 140 : 520)) }
        setTorch(false)
    }
    private func setTorch(_ on: Bool) {
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
        if on { try? d.setTorchModeOn(level: 1) } else { d.torchMode = .off }
        d.unlockForConfiguration()
    }

    /// Two bell notes (a bright E, then a B below it) made of a bell's partials, dying away; then a pause. Made here, so no
    /// sound file is needed.
    static func chime() -> AVAudioPCMBuffer? {
        let rate = 44_100.0, seconds = 2.2
        guard let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1), let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(rate * seconds)) else { return nil }
        b.frameLength = b.frameCapacity
        let out = b.floatChannelData![0]; let n = Int(b.frameLength)
        let notes: [(Double, Double)] = [(0.0, 1318.5), (0.34, 987.8), (0.9, 1318.5), (1.24, 987.8)]
        let partials: [(Double, Double, Double)] = [(1, 1, 2.6), (2.0, 0.45, 4.2), (2.76, 0.32, 5.5), (5.4, 0.12, 8)]
        for i in 0..<n {
            let t = Double(i) / rate; var v = 0.0
            for (start, freq) in notes where t >= start {
                let dt = t - start; let attack = min(1, dt / 0.004)
                for (k, amp, decay) in partials { v += amp * attack * exp(-dt * decay) * sin(2 * .pi * freq * k * dt) }
            }
            out[i] = Float(max(-1, min(1, v * 0.32)))
        }
        return b
    }
}

/// The iPhone's media volume, set through the system's own volume control (shown for a moment as it changes).
@MainActor
enum SystemVolume {
    private static let view: MPVolumeView = { let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10)); v.alpha = 0.01; return v }()
    static func set(_ value: Float) {
        if view.superview == nil, let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first { w.addSubview(view) }
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { slider.setValue(value, animated: false); slider.sendActions(for: .valueChanged) }
    }
}

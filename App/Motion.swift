import CoreHaptics
import CoreMotion
import Observation
import SwiftUI
import UIKit

/// How the iPhone is tilted, smoothed (x left and right, y towards and away, each -1…1): the glass's light and the
/// background's depth follow it. Off with Reduce Motion or the app's own switch, and while the app isn't on screen.
@Observable @MainActor
final class Tilt {
    static let shared = Tilt()
    var x = 0.0
    var y = 0.0
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var rest: (Double, Double)?
    private init() {}
    func start() {
        guard Hub.shared.prefs.tilt, !UIAccessibility.isReduceMotionEnabled, motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            // Relative to how the iPhone is usually held (it settles to where it rests).
            let gx = g.x, gy = g.y + 0.62
            let r = self.rest ?? (gx, gy); let nr = (r.0 * 0.995 + gx * 0.005, r.1 * 0.995 + gy * 0.005); self.rest = nr
            let tx = max(-1, min(1, (gx - nr.0) * 2.2)), ty = max(-1, min(1, (gy - nr.1) * 2.2))
            let nx = self.x * 0.82 + tx * 0.18, ny = self.y * 0.82 + ty * 0.18
            if abs(nx - self.x) > 0.002 || abs(ny - self.y) > 0.002 { self.x = nx; self.y = ny }
        }
    }
    func stop() { motion.stopDeviceMotionUpdates(); withAnimation(.easeOut(duration: 0.6)) { x = 0; y = 0 } }
}

/// The app's touch feedback, as the Android app's: a tick for choices, a tap for buttons, a thud for big moments.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light), soft = UIImpactFeedbackGenerator(style: .soft), rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator(), notice = UINotificationFeedbackGenerator()
    private static var on: Bool { Hub.shared.prefs.haptics }
    static func tick() { guard on else { return }; selection.selectionChanged() }
    static func tap() { guard on else { return }; light.impactOccurred(intensity: 0.8) }
    static func soft(_ i: CGFloat = 0.6) { guard on else { return }; soft.impactOccurred(intensity: i) }
    static func thud() { guard on else { return }; rigid.impactOccurred(intensity: 0.9) }
    static func success() { guard on else { return }; notice.notificationOccurred(.success) }
    static func error() { guard on else { return }; notice.notificationOccurred(.error) }
    static func notify() { guard on else { return }; notice.notificationOccurred(.warning) }
    /// A detent crossed while turning a dial or scrubbing (sharper at the ends).
    static func detent(edge: Bool = false) { guard on else { return }; (edge ? rigid : light).impactOccurred(intensity: edge ? 1 : 0.45) }
}

/// A pattern felt while your PC rings this iPhone: a heartbeat of taps that swells, over and over.
@MainActor
final class HapticPulse {
    private var engine: CHHapticEngine?, player: CHHapticAdvancedPatternPlayer?
    func start() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, Hub.shared.prefs.haptics else { return }
        do {
            let e = try CHHapticEngine(); try e.start(); engine = e
            var events: [CHHapticEvent] = []
            for (i, t) in [0.0, 0.16, 0.9, 1.06].enumerated() {
                events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [.init(parameterID: .hapticIntensity, value: i % 2 == 0 ? 1 : 0.7), .init(parameterID: .hapticSharpness, value: 0.5)], relativeTime: t))
            }
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [.init(parameterID: .hapticIntensity, value: 0.35), .init(parameterID: .hapticSharpness, value: 0.2)], relativeTime: 1.3, duration: 0.5))
            let p = try e.makeAdvancedPlayer(with: CHHapticPattern(events: events, parameters: []))
            p.loopEnabled = true; p.loopEnd = 2.2; try p.start(atTime: 0); player = p
        } catch { engine = nil }
    }
    func stop() { try? player?.stop(atTime: 0); engine?.stop(); engine = nil; player = nil }
}

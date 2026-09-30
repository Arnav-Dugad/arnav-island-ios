import Foundation
import IslandKit

/// What Siri, Shortcuts, the Action button, Control Center, widgets and Live Activities ask the app to do. iOS runs them
/// here (waking the app in the background if need be), where the keys to your PC are.
@MainActor
enum IntentActions {
    /// The link up and the chosen PC reachable (waited for briefly: a woken app has to reconnect first).
    private static func ready() async -> PeerView? {
        let hub = Hub.shared
        guard await hub.start() != nil else { return nil }
        for _ in 0..<80 { if let p = hub.pc(), p.online { return p }; try? await Task.sleep(for: .milliseconds(100)) }
        return hub.pc().flatMap { $0.online ? $0 : nil }
    }
    static func media(_ action: Int) async {
        guard await ready() != nil else { return }
        await Hub.shared.command(Proto.cmdMedia, [UInt8(action)], quiet: true)
        await Hub.shared.refreshStatus()
    }
    static func volume(by step: Int) async {
        guard await ready() != nil else { return }
        let now = await Hub.shared.refreshStatus()?.volume ?? 50
        await Hub.shared.setVolume(now + step)
        await Hub.shared.refreshStatus()
    }
    static func lock() async -> String {
        guard let p = await ready() else { return unreachable }
        return await Hub.shared.command(Proto.cmdLock, quiet: true)?.ok == true ? "Locked \(p.name)." : "\(p.name) didn't lock. Is “My phone can control this PC” on?"
    }
    static func ring() async -> String {
        guard let p = await ready() else { return unreachable }
        return await Hub.shared.command(Proto.cmdRingPc, quiet: true)?.ok == true ? "\(p.name) is chiming now." : "\(p.name) didn't answer."
    }
    static func summary() async -> String {
        guard let p = await ready() else { return unreachable }
        let hub = Hub.shared
        guard let s = await hub.refreshStatus() else { return "\(p.name) is here, but didn't answer." }
        var parts: [String] = []
        if s.available && !s.title.isEmpty { parts.append("\(s.playing ? "Playing" : "Paused on") \(s.title)\(s.artist.isEmpty ? "" : " by \(s.artist)")") } else { parts.append("Nothing's playing") }
        if s.batteryPresent { parts.append("battery \(s.battery)%\(s.charging ? " and charging" : "")") }
        if s.cpu >= 0 { parts.append("CPU at \(s.cpu)%") }
        parts.append("volume \(s.muted ? "muted" : "\(s.volume)%")")
        return "\(p.name): " + parts.joined(separator: ", ") + "."
    }
    static func open(_ place: String) async { Hub.shared.request = place }
    private static var unreachable: String { Hub.shared.pairedPCs.isEmpty ? "Pair with your PC in Arnav Island first." : "Your PC isn't reachable right now." }
}

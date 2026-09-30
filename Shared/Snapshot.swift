import Foundation

/// What the widgets, the Live Activities and Siri show of your PC, as the app last saw it (kept in the app group).
struct Snapshot: Codable, Equatable {
    var pcId = "", pcName = "", online = false
    var title = "", artist = "", app = "", playing = false, position = 0.0, duration = 0.0, at = Date.distantPast
    var volume = -1, muted = false, battery = -1, charging = false, cpu = -1
    var gpu = -1.0, ram = -1.0, weather = ""
    var accent = "A5D8C5", accent2 = "8FA8FF", deep = "0B1220"
    var updated = Date.distantPast

    func positionNow(_ now: Date = Date()) -> Double { playing && duration > 0 ? min(duration, position + now.timeIntervalSince(at)) : position }

    static var file: URL { AppGroup.container.appendingPathComponent("snapshot.json") }
    static var coverFile: URL { AppGroup.container.appendingPathComponent("cover.jpg") }
    static func load() -> Snapshot { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot() }
    func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Snapshot.file, options: .atomic) } }
}

import Foundation

/// What the share sheet hands the app when it couldn't send itself (the PC was away, or the sheet was closed first): files
/// copied into the app group with a note of where they go; the app sends them when it next opens.
struct ShareNote: Codable { var peer: String; var toShelf: Bool; var files: [String]; var page: String?; var title: String?; var scroll: Double? }

enum ShareInbox {
    static var root: URL { let u = AppGroup.container.appendingPathComponent("ShareInbox"); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }
    /// Leaves files (and a page) for the app to send.
    @discardableResult static func leave(peer: String, toShelf: Bool, files: [URL], page: String? = nil, title: String? = nil, scroll: Double? = nil) -> Bool {
        let dir = root.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var names: [String] = []
            for f in files { let dest = dir.appendingPathComponent(f.lastPathComponent); try FileManager.default.copyItem(at: f, to: dest); names.append(f.lastPathComponent) }
            let note = ShareNote(peer: peer, toShelf: toShelf, files: names, page: page, title: title, scroll: scroll)
            try JSONEncoder().encode(note).write(to: dir.appendingPathComponent("note.json"))
            return true
        } catch { try? FileManager.default.removeItem(at: dir); return false }
    }
    /// Everything left, oldest first (each taken away as it's handed over).
    static func take() -> [(ShareNote, URL)] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return dirs.sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .compactMap { d in (try? Data(contentsOf: d.appendingPathComponent("note.json"))).flatMap { try? JSONDecoder().decode(ShareNote.self, from: $0) }.map { ($0, d) } }
    }
}

import Foundation

extension ShareInbox {
    /// Sends what the share sheet left (the app has just come forward). Files are moved out of the app group first, so a
    /// second look doesn't send them twice.
    @MainActor static func collect() {
        let waiting = take(); guard !waiting.isEmpty else { return }
        Task {
            let hub = Hub.shared
            guard await hub.start() != nil else { return }
            for _ in 0..<60 where hub.pairedPCs.first(where: { $0.online }) == nil { try? await Task.sleep(for: .milliseconds(100)) }
            for (note, dir) in waiting {
                let target = hub.peers.first { $0.id == note.peer && $0.paired } ?? hub.pc()
                guard let target, target.online else { continue }
                if let page = note.page, let url = URL(string: page) {
                    let prior = hub.selected; hub.choose(target.id)
                    _ = await hub.pageToPC(url, title: note.title ?? "", scroll: note.scroll ?? 0)
                    if let prior { hub.choose(prior) }
                }
                if !note.files.isEmpty {
                    let out = Sources.outgoing()
                    let files = note.files.compactMap { name -> URL? in let dest = out.appendingPathComponent(name); return (try? FileManager.default.moveItem(at: dir.appendingPathComponent(name), to: dest)) != nil ? dest : nil }
                    await hub.send(target.id, files: files, toShelf: note.toShelf)
                }
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
}

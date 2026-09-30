import XCTest
@testable import IslandKit

/// The link against the Windows island's own engine (share_peer, driven on a PC elsewhere), live over the internet through
/// the public relay. Runs only when ISLAND_CODE (and ISLAND_KEY, from the island's QR link) are given: the PC's side hosts
/// that code, then, once paired, sends a file, hands its music over, pushes its clipboard, rings and hands a page over.
final class InteropTests: XCTestCase {
    final class Memory: LinkStore {
        var identity: StoredIdentity?; var peers: [StoredPeer] = []
        func loadIdentity() -> StoredIdentity? { identity }
        func saveIdentity(_ i: StoredIdentity) -> Bool { identity = i; return true }
        func loadPeers() -> [StoredPeer] { peers }
        func savePeers(_ p: [StoredPeer]) { peers = p }
    }
    final class Folder: Inbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("island-interop-\(UUID().uuidString)")
        init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func folder(_ name: String) -> String { name }
        func create(_ parts: [String], size: Int64) -> Sink? { FileSink(root.appendingPathComponent(parts.joined(separator: "/"))) }
        func song(_ name: String, size: Int64) -> Sink? { FileSink(root.appendingPathComponent(name)) }
        func room(_ bytes: Int64) -> Bool { true }
    }
    final class FileSink: Sink {
        let url: URL; let h: FileHandle?
        init(_ url: URL) { self.url = url; try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); FileManager.default.createFile(atPath: url.path, contents: nil); h = try? FileHandle(forWritingTo: url) }
        func write(_ b: ArraySlice<UInt8>) -> Bool { (try? h?.write(contentsOf: Data(b))) != nil }
        func commit() -> URL? { try? h?.close(); return url }
        func abort() { try? h?.close(); try? FileManager.default.removeItem(at: url) }
    }
    /// Events, and waiting for one.
    final class Events {
        private let cond = NSCondition(); private var list: [LinkEvent] = []
        func add(_ e: LinkEvent) { cond.lock(); list.append(e); cond.broadcast(); cond.unlock() }
        func wait<T>(_ seconds: TimeInterval, _ pick: (LinkEvent) -> T?) -> T? {
            cond.lock(); defer { cond.unlock() }
            let until = Date().addingTimeInterval(seconds); var seen = 0
            while true {
                while seen < list.count { if let v = pick(list[seen]) { list.remove(at: seen); return v }; seen += 1 }
                if !cond.wait(until: until) { return nil }
            }
        }
    }

    func testAgainstTheIsland() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["ISLAND_CODE"], !code.isEmpty else { throw XCTSkip("ISLAND_CODE isn't set") }
        let keyPrint = env["ISLAND_KEY"].flatMap { $0.unhex }
        let events = Events(); let store = Memory(); let inbox = Folder()
        let link = Link(store: store, name: "iOS Test iPhone", inbox: inbox, options: Link.Options(direct: false), onEvent: events.add)
        var queries: [Int] = []; let qlock = NSLock()
        link.onQuery = { _, cmd, payload in qlock.lock(); queries.append(cmd); qlock.unlock(); return cmd == Proto.queryReadings ? Wire().string("Battery\t80%").u32(0).build() : [] }
        var clipboard = ""; link.onClipboard = { t, _ in clipboard = t; return true }
        XCTAssertTrue(link.start())
        XCTAssertTrue(link.waitConnected(20), "on the relay")
        print("relay: \(link.relayBroker ?? "none")")
        Thread.sleep(forTimeInterval: 3)

        // Pairing: the code and the QR key, so this side says yes at once.
        XCTAssertTrue(link.pairWithCode(code, key: keyPrint))
        let shown = events.wait(90) { if case let .pairCode(_, name, c, confirmed) = $0 { return (name, c, confirmed) }; return nil }
        XCTAssertNotNil(shown, "both show the code"); print("pair code \(shown.map { String($0.1) } ?? "-") with \(shown?.0 ?? "-"), confirmed \(shown?.2 ?? false)")
        if keyPrint == nil { link.confirmPair(true) }
        let paired = events.wait(60) { if case let .paired(peer, name, ok, detail) = $0 { return (peer, name, ok, detail) }; return nil }
        XCTAssertEqual(paired?.2, true, "paired: \(paired?.3 ?? "no answer")")
        let pc = try XCTUnwrap(paired?.0); XCTAssertEqual(store.peers.count, 1, "the pairing is kept")

        var online = false
        for _ in 0..<60 { if link.peerViews().contains(where: { $0.id == pc && $0.online && $0.revision >= 8 }) { online = true; break }; Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(online, "the PC is online through the relay, revision 8")

        // The remote.
        let st = link.status(pc, haveCover: nil, previous: nil)
        XCTAssertNotNil(st?.title, "status"); print("status: \(st?.title ?? "-") · \(st?.artist ?? "-"), volume \(st?.volume ?? -1), cover \(st?.cover?.count ?? 0) bytes")
        let again = link.status(pc, haveCover: st?.coverHash, previous: st); XCTAssertEqual(again?.cover, st?.cover, "an unchanged cover isn't sent again")
        XCTAssertEqual(link.remote(pc, Proto.cmdVolume, [64])?.status, Proto.ok, "volume")
        XCTAssertEqual(link.remote(pc, Proto.cmdMedia, [1])?.status, Proto.ok, "play/pause")
        XCTAssertNotNil(link.remote(pc, Proto.cmdClipGet), "the PC's clipboard")
        XCTAssertEqual(link.remote(pc, Proto.cmdClipSet, Array("from iPhone ✓".utf8))?.status, Proto.ok, "to the PC's clipboard")
        XCTAssertNotNil(link.lyrics(pc), "lyrics")
        XCTAssertEqual(link.remote(pc, Proto.cmdPage, Frames.page(url: "https://example.com/from-iphone", title: "From the iPhone", scroll: 0.42))?.status, Proto.ok, "a page to the PC")

        // The whole island.
        let stats = link.stats(pc); XCTAssertNotNil(stats, "stats"); print("stats: CPU \(Int(stats?.cpu ?? -1))%, \(stats?.cores.count ?? 0) cores, \(stats?.name ?? "-")")
        let battery = link.battery(pc); XCTAssertNotNil(battery, "battery"); print("battery: \(battery?.percent ?? -1)%, \(battery?.day.count ?? 0) readings")
        let settings = link.islandSettings(pc); XCTAssertNotNil(settings, "settings"); print("settings: \(settings?.items.count ?? 0) in \(settings?.sections.count ?? 0) sections")
        XCTAssertEqual(link.setIslandSetting(pc, "hoverDelay", 9999), 700, "a setting kept within its range")
        XCTAssertNotNil(link.controls(pc), "controls")
        XCTAssertEqual(link.setControl(pc, IslandWire.brightness, 30)?.brightness, 30, "brightness set")
        XCTAssertTrue(link.queryCommands(pc, "usd")?.rows.contains { $0.kind == 37 } ?? false, "the command bar")
        XCTAssertEqual(link.outputs(pc)?.count, 2, "audio outputs")
        XCTAssertEqual(link.selectOutput(pc, "buds"), Proto.ok, "an output chosen")
        XCTAssertTrue(link.openIslandPage(pc, 2), "an island page opened")
        XCTAssertTrue(link.notice(pc, Frames.status(battery: 81, charging: true)), "battery to the island")
        XCTAssertTrue(link.notice(pc, Frames.details([("Model", "iPhone"), ("iOS", "26.5")])), "details to the island")

        // Files: here to the PC's Shelf, with a picture.
        var bytes = [UInt8](repeating: 0, count: 600_000); for i in 0..<bytes.count { bytes[i] = UInt8((i * 31 + (i >> 9)) & 255) }
        let file = inbox.root.appendingPathComponent("iphone-photo.bin"); try Data(bytes).write(to: file)
        let preview: [UInt8] = [0xFF, 0xD8] + [UInt8](repeating: 7, count: 1500) + [0xFF, 0xD9]
        _ = link.send(pc, items: [Source(rel: "iphone-photo.bin", size: Int64(bytes.count), url: file)], title: "iphone-photo.bin", toShelf: true, preview: preview)
        let sent = events.wait(120) { if case let .sent(_, _, _, title, _, size) = $0 { return (title, size) }; if case let .failed(_, _, _, _, detail, true) = $0 { return (detail, -1) }; return nil }
        XCTAssertEqual(sent?.1, Int64(bytes.count), "sent to the Shelf: \(sent?.0 ?? "no answer")")

        // The PC's Shelf, listed and taken.
        let shelf = link.shelf(pc); print("shelf: \(shelf.items.map { $0.name })")
        if let i = shelf.items.firstIndex(where: { !$0.folder }) {
            _ = link.take(pc, index: i, name: shelf.items[i].name)
            let taken = events.wait(90) { if case let .received(_, _, _, _, _, size, files, true) = $0 { return (size, files) }; return nil }
            XCTAssertNotNil(taken, "taken from the Shelf"); if let t = taken { XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: t.1[0].path)[.size] as? Int64) ?? -1, t.0, "whole") }
        } else { XCTFail("the Shelf has an item to take") }

        // What the PC's side does once paired: a file, music, the clipboard, a ring and a page.
        let offer = events.wait(120) { if case let .offer(transfer, _, _, title, count, size, _) = $0 { return (transfer, title, count, size) }; return nil }
        XCTAssertNotNil(offer, "the PC offers a file"); if let o = offer { print("offer: \(o.1), \(o.3) bytes"); link.answer(o.0, accept: true) }
        let got = events.wait(120) { if case let .received(_, _, _, _, _, size, files, false) = $0 { return (size, files) }; return nil }
        XCTAssertNotNil(got, "the file arrives whole")
        let music = events.wait(120) { if case let .music(transfer, _, _, m) = $0 { return (transfer, m) }; return nil }
        XCTAssertNotNil(music, "music handed here"); if let m = music { print("music: \(m.1.title), cover \(m.1.cover?.count ?? 0) bytes"); link.answerMusic(m.0, 1) }
        let ring = events.wait(120) { if case let .ring(_, name) = $0 { return name }; return nil }
        XCTAssertNotNil(ring, "the PC rings this iPhone")
        for _ in 0..<150 where clipboard.isEmpty { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(clipboard.isEmpty, "the PC's clipboard pushed here"); print("clipboard: \(clipboard)")
        for _ in 0..<150 { qlock.lock(); let q = queries.contains(Proto.queryPage); qlock.unlock(); if q { break }; Thread.sleep(forTimeInterval: 0.2) }
        qlock.lock(); XCTAssertTrue(queries.contains(Proto.queryPage), "a page from the PC"); qlock.unlock()

        // The trackpad.
        let input = link.openInput(pc); XCTAssertNotNil(input, "the trackpad connects")
        XCTAssertEqual(input?.send(Frames.move(12, -5)), true); XCTAssertEqual(input?.send(Frames.button(0, 2)), true); XCTAssertEqual(input?.send(Frames.text("hi")), true)
        Thread.sleep(forTimeInterval: 2); input?.close()

        // The PC's screen (a made-up moving picture, never the real one).
        if let (screen, reply) = link.openScreen(pc, request: ScreenWire.askPc(longest: 1280, shortest: 720, fps: 30)) {
            let r = ScreenWire.reply(reply); XCTAssertEqual(r?.status, 0, "the screen answers"); print("screen: \(r?.width ?? 0)x\(r?.height ?? 0)")
            let assembler = ScreenWire.Assembler(); var frames = 0, keys = 0; let until = Date().addingTimeInterval(20)
            while Date() < until && frames < 15 {
                guard let f = screen.receive(timeout: 1), f.first == UInt8(Proto.screenVideo) else { continue }
                if let whole = assembler.add(f) { frames += 1; if whole.key { keys += 1 }; if frames % 5 == 0 { _ = screen.send(ScreenWire.feedback(last: whole.number, decodeMs: 8, kbps: 2000, fps: 30)) } }
            }
            XCTAssertGreaterThanOrEqual(frames, 5, "frames arrive"); XCTAssertGreaterThanOrEqual(keys, 1, "with a key frame"); print("screen: \(frames) frames, \(keys) key")
            XCTAssertEqual(screen.send(ScreenWire.input(Frames.point(0.5, 0.5))), true)
            Thread.sleep(forTimeInterval: 1.5); _ = screen.send([UInt8(Proto.screenStop)]); screen.close()
        } else { XCTFail("the PC's screen opens") }

        link.forget(pc); XCTAssertTrue(store.peers.isEmpty, "forgotten")
        link.stop()
    }
}

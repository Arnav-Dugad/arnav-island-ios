import SwiftUI
import IslandKit
import Observation
import UIKit
import WidgetKit

/// A transfer under way, either way. rate: bytes a second, smoothed.
struct Transfer: Identifiable, Equatable {
    let id: Int; var peer: String; var name: String; var title: String; var done: Int64; var total: Int64; var outgoing: Bool
    var rate = 0.0; var sampledAt = Date(); var sampledDone: Int64 = 0
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}
/// Something that happened between this iPhone and a PC, for the Send tab's history. kind: 0 received, 1 sent, 2 taken from a Shelf.
struct Moment: Codable, Identifiable, Equatable {
    var id = UUID(); var kind: Int; var title: String; var from: String; var count: Int; var size: Int64; var at: Date
    /// Where the files are, relative to the app's Documents folder.
    var files: [String]
}
/// A glass banner that drops from the app's island.
struct Banner: Identifiable, Equatable {
    enum Kind { case received, sent, failed, paired, info, music, ring, clipboard, photo, internet, page }
    let id = UUID(); let kind: Kind; let title: String; var detail = ""
    var symbol: String {
        switch kind {
        case .received: return "arrow.down.circle.fill"; case .sent: return "checkmark.circle.fill"; case .failed: return "exclamationmark.circle.fill"
        case .paired: return "link.circle.fill"; case .info: return "info.circle.fill"; case .music: return "music.note"; case .ring: return "bell.and.waves.left.and.right.fill"
        case .clipboard: return "doc.on.clipboard.fill"; case .photo: return "camera.fill"; case .internet: return "globe"; case .page: return "safari.fill"
        }
    }
}
struct PairCodeShown: Equatable { let peer: String; let name: String; let code: Int; let confirmed: Bool }
struct PairOutcome: Equatable { let peer: String; let name: String; let ok: Bool; let detail: String }
struct Offer: Identifiable, Equatable { var id: Int { transfer }; let transfer: Int; let peer: String; let name: String; let title: String; let count: Int; let size: Int64; let folder: Bool }
struct MusicOffer: Identifiable, Equatable { var id: Int { transfer }; let transfer: Int; let peer: String; let name: String; let music: Handoff; var fetching = false }
struct PageArrival: Identifiable, Equatable { let id = UUID(); let from: String; let peer: String; let url: URL; let title: String; let scroll: Double }
struct StatsPoint: Equatable { let at: Date; let cpu: Double; let gpu: Double; let download: Double; let upload: Double }

/// The app's choices, kept in the app group (the widgets and share sheet read some).
struct Prefs: Codable, Equatable {
    var internet = true, autoAccept = false, battery = true, details = true, clipAuto = false, recentPhotos = false
    var stayReachable = false, faceID = false, liveActivity = true, haptics = true, solidGlass = false, tilt = true
    /// Photos as JPEG (a PC may not open HEIC), as iOS's own "Most Compatible".
    var compatible = true
    var weather = true
    var theme = 0 // 0 system, 1 dark, 2 light
    var name = ""
    var onboarded = false
    static let key = "prefs"
    init() {}
    /// Missing keys (from an older version) keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); let d = Prefs()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        internet = v(.internet, d.internet); autoAccept = v(.autoAccept, d.autoAccept); battery = v(.battery, d.battery); details = v(.details, d.details)
        clipAuto = v(.clipAuto, d.clipAuto); recentPhotos = v(.recentPhotos, d.recentPhotos); stayReachable = v(.stayReachable, d.stayReachable); faceID = v(.faceID, d.faceID)
        liveActivity = v(.liveActivity, d.liveActivity); haptics = v(.haptics, d.haptics); solidGlass = v(.solidGlass, d.solidGlass); tilt = v(.tilt, d.tilt)
        compatible = v(.compatible, d.compatible); weather = v(.weather, d.weather); theme = v(.theme, d.theme); name = v(.name, d.name); onboarded = v(.onboarded, d.onboarded)
    }
    static func load() -> Prefs { AppGroup.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) } ?? Prefs() }
    func save() { if let d = try? JSONEncoder().encode(self) { AppGroup.defaults.set(d, forKey: Prefs.key) } }
}

/// Runs blocking work (the link's calls block) on a background queue, off Swift's cooperative threads.
func io<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) } }
}

/**
 * Everything the app knows, for every screen, the widgets and Siri: the link with your PCs, what it reports, and the
 * actions the screens take, as the Android app's Hub. Lives on the main actor; the link's blocking calls run on
 * background queues and its events come back here.
 */
@Observable @MainActor
final class Hub {
    static let shared = Hub()

    @ObservationIgnored private(set) var link: IslandKit.Link?
    var running = false
    var failure: String?
    var peers: [PeerView] = []
    var pairCode: PairCodeShown?
    var pairResult: PairOutcome?
    /// The code this iPhone is pairing with through the relay (typed, scanned or opened as a link), until its digits or an answer come.
    var codePairing: String?
    var offers: [Offer] = []
    var music: MusicOffer?
    var transfers: [Int: Transfer] = [:]
    var moments: [Moment] = []
    var banner: Banner?
    @ObservationIgnored private var bannerQueue: [Banner] = []
    var ringing: String?
    var status: PcStatus?
    var statusError: String?
    var selected: String?
    /// Connected to the relay: paired PCs on other networks are reachable.
    var internet = false
    var lyrics: Lyrics?
    /// Something a screen should open now ("camera": a PC asked for a photo while the app was on screen; "screen", "trackpad"...).
    var request: String?
    var page: PageArrival?
    var visible = false
    var prefs = Prefs.load()
    /// The colours of what plays on the PC, and its cover.
    var palette = Palette.standard
    var cover: UIImage?
    /// How each send ended (its transfer, and whether it arrived), for the share rings.
    var outcomes: [Int: Bool] = [:]

    // the whole island
    var pcStats: PcStats?
    var pcControls: PcControls?
    @ObservationIgnored var controlsAt = Date()
    var islandSettings: IslandSettings?
    var outputs: [AudioOutput] = []
    var pcBattery: PcBattery?
    var statsTrail: [StatsPoint] = []
    var focus: FocusClock?
    @ObservationIgnored private var trailPc: String?
    @ObservationIgnored private var batteryTick = 0
    @ObservationIgnored private var statsCache: [String: PcStats] = [:]

    private init() {
        if Demo.on { prefs = Prefs(); prefs.theme = Demo.argument("theme").flatMap(Int.init) ?? 0 }
        selected = AppGroup.defaults.string(forKey: "pc")
        moments = loadMoments()
        focus = loadFocus()
        if let snap = Optional(Snapshot.load()), !snap.accent.isEmpty, let a = Color(hexString: snap.accent), let b = Color(hexString: snap.accent2), let d = Color(hexString: snap.deep) {
            palette = Palette(accent: a, accent2: b, deep: d)
        }
        cover = (try? Data(contentsOf: Snapshot.coverFile)).flatMap(UIImage.init(data:))
    }

    func update(_ change: (inout Prefs) -> Void) {
        let before = prefs; change(&prefs); guard prefs != before else { return }; prefs.save()
        if prefs.internet != before.internet { restart() }
        if prefs.name != before.name { link?.displayName = phoneName() }
        if prefs.stayReachable != before.stayReachable { KeepAlive.shared.sync() }
        if prefs.recentPhotos != before.recentPhotos { RecentPhotos.shared.sync() }
        if prefs.liveActivity != before.liveActivity { LiveActivities.shared.sync() }
    }
    func pref<T>(_ key: WritableKeyPath<Prefs, T>) -> Binding<T> { Binding(get: { self.prefs[keyPath: key] }, set: { v in self.update { $0[keyPath: key] = v } }) }

    /// The name your PCs know this iPhone by: yours, else its model ("iPhone 15").
    func phoneName() -> String { let n = prefs.name.trimmingCharacters(in: .whitespaces); return n.isEmpty ? DeviceInfo.modelName : n }

    // ---- the link ----
    @discardableResult func start() async -> IslandKit.Link? {
        if let link { return link }
        if Demo.on { return nil }
        if starting { for _ in 0..<80 { try? await Task.sleep(for: .milliseconds(100)); if let link { return link } }; return link }
        starting = true; defer { starting = false }
        let options = IslandKit.Link.Options(phone: true, direct: true)
        let l = IslandKit.Link(store: KeychainStore.shared, name: phoneName(), inbox: FolderInbox.shared, options: options) { e in DispatchQueue.main.async { Hub.shared.handle(e) } }
        l.onQuery = { peer, command, payload in Hub.answerQuery(peer, command, payload) }
        l.onClipboard = { text, sensitive in Hub.clipboardIn(text, sensitive) }
        let ok = await io { l.start() }
        guard ok else { failure = l.failure ?? "The link couldn't start"; return nil }
        link = l; running = true; failure = nil
        peers = l.peerViews(); pickDefault()
        return l
    }
    @ObservationIgnored private var starting = false
    func stop() { let l = link; link = nil; running = false; internet = false; peers = []; Task.detached { l?.stop() } }
    func restart() { guard link != nil else { return }; stop(); Task { await start() } }
    /// The iPhone moved to another network, or came back from the background: reconnect at once.
    func networkChanged() { let l = link; DispatchQueue.global().async { l?.networkChanged() } }

    // ---- your PCs ----
    /// The PC the remote and sends go to: the chosen one while it is paired, else the first paired PC that is here.
    func pc(_ list: [PeerView]? = nil, chosen: String? = nil) -> PeerView? {
        let list = list ?? peers; let chosen = chosen ?? selected
        return list.first { $0.id == chosen && $0.paired } ?? list.first { $0.paired && $0.online && !$0.phone } ?? list.first { $0.paired && !$0.phone }
    }
    var pairedPCs: [PeerView] { peers.filter { $0.paired && !$0.phone } }
    private func pickDefault() { if let p = pc(), p.id != selected { choose(p.id) } }
    func choose(_ peer: String) {
        if selected != peer { clearIsland(); status = nil; lyrics = nil }
        selected = peer; AppGroup.defaults.set(peer, forKey: "pc")
    }

    @ObservationIgnored private var lastOnline = Set<String>()
    private func handle(_ e: LinkEvent) {
        switch e {
        case .peers(let list):
            let wasInternet = internet
            peers = list; pickDefault(); internet = link?.internet == true
            if wasInternet != internet && !internet && running && prefs.internet { /* the relay reconnects by itself */ }
            // A PC that just came online hears this iPhone's battery and details at once.
            let online = Set(list.filter { $0.paired && $0.online && $0.remote }.map(\.id))
            let arrived = online.subtracting(lastOnline); lastOnline = online
            if !arrived.isEmpty { sendBattery(force: true); sendDetails(force: true) }
            Snapshotter.shared.peersChanged()
        case .pairCode(let peer, let name, let code, let confirmed):
            codePairing = nil; pairCode = PairCodeShown(peer: peer, name: name, code: code, confirmed: confirmed)
            if !visible { Notify.pairing(name: name, code: code) }
        case .paired(let peer, let name, let ok, let detail):
            codePairing = nil; pairCode = nil; pairResult = PairOutcome(peer: peer, name: name, ok: ok, detail: detail); Notify.cancel(Notify.pair)
            if ok {
                if selected == nil || pc()?.id == nil { choose(peer) }
                Haptics.success(); if !Demo.quiet { Notify.ask() }
                show(Banner(kind: .paired, title: "Paired with \(name)", detail: "Files, music and the remote are ready, on any network"))
                sendBattery(force: true); sendDetails(force: true)
            } else { Haptics.error(); show(Banner(kind: .failed, title: name.isEmpty ? "Not paired" : "Not paired with \(name)", detail: detail)) }
        case .offer(let transfer, let peer, let name, let title, let count, let size, let folder):
            if prefs.autoAccept { let l = link; DispatchQueue.global().async { l?.answer(transfer, accept: true) }; return }
            offers.append(Offer(transfer: transfer, peer: peer, name: name, title: title, count: count, size: size, folder: folder))
            Haptics.notify()
            if !visible { Notify.offer(transfer: transfer, name: name, title: title, size: size) }
        case .progress(let transfer, let peer, let name, let title, let done, let total, let outgoing):
            let now = Date()
            if var t = transfers[transfer] {
                t.done = done; t.total = total; t.title = title
                let dt = now.timeIntervalSince(t.sampledAt)
                if dt >= 0.3 && done >= t.sampledDone { let speed = Double(done - t.sampledDone) / dt; t.rate = t.rate > 0 ? t.rate * 0.7 + speed * 0.3 : speed; t.sampledAt = now; t.sampledDone = done }
                transfers[transfer] = t
            } else { transfers[transfer] = Transfer(id: transfer, peer: peer, name: name, title: title, done: done, total: total, outgoing: outgoing, sampledAt: now, sampledDone: done) }
            LiveActivities.shared.transfer(transfers[transfer]!)
        case .received(let transfer, _, let name, let title, let count, let size, let files, let taken):
            let t = transfers.removeValue(forKey: transfer); offers.removeAll { $0.transfer == transfer }
            if let t { LiveActivities.shared.transferEnded(t, ok: true) }
            remember(Moment(kind: taken ? 2 : 0, title: title, from: name, count: count, size: size, at: Date(), files: files.prefix(20).compactMap(FolderInbox.relative)))
            Haptics.success()
            show(Banner(kind: .received, title: taken ? "Took \(title)" : "Received \(title)", detail: "From \(name)  ·  \(sizeText(size))"))
            if !visible { Notify.received(name: name, title: title, size: size, first: files.first) }
        case .sent(let transfer, _, let name, let title, let count, let size):
            let t = transfers.removeValue(forKey: transfer); outcomes[transfer] = true
            if let t { LiveActivities.shared.transferEnded(t, ok: true) }
            remember(Moment(kind: 1, title: title, from: name, count: count, size: size, at: Date(), files: []))
            Haptics.success()
            show(Banner(kind: .sent, title: "Sent \(title)", detail: "To \(name)  ·  \(sizeText(size))"))
        case .failed(let transfer, _, _, let title, let detail, let outgoing):
            if outgoing { outcomes[transfer] = false }
            let t = transfers.removeValue(forKey: transfer); offers.removeAll { $0.transfer == transfer }; Notify.cancel(Notify.offer + "\(transfer)")
            if let t { LiveActivities.shared.transferEnded(t, ok: false) }
            if music?.transfer == transfer { music = nil }
            if detail != "You stopped it" { Haptics.error(); show(Banner(kind: .failed, title: title.isEmpty ? "Couldn't share" : "Couldn't share \(title)", detail: detail)) }
        case .music(let transfer, let peer, let name, let m):
            musicOfferedAt = Date(); music = MusicOffer(transfer: transfer, peer: peer, name: name, music: m)
            Haptics.notify()
            if !visible { Notify.music(transfer: transfer, name: name, title: m.title, artist: m.artist) }
        case .musicFile(let transfer, let peer, let name, let m, let file):
            transfers.removeValue(forKey: transfer); Notify.cancel(Notify.musicId); music = nil
            // Played from where the PC was when it was answered (it kept playing until then, and paused while the song came).
            let start = max(0, m.position + min(600, max(0, musicAnsweredAt.timeIntervalSince(musicOfferedAt))))
            Player.shared.play(m, file: file, peer: peer, pcName: name, from: start)
        case .ring(_, let name):
            Ringer.shared.start(from: name)
        case .photoRequested(let peer, let name):
            photoFor = peer
            if visible { request = "camera" } else { Notify.photo(name: name) }
        case .internet(let on):
            internet = on
        }
    }

    // ---- banners ----
    func show(_ b: Banner) {
        if banner == nil { withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { banner = b }; scheduleBannerEnd(b) }
        else { bannerQueue.append(b); if bannerQueue.count > 4 { bannerQueue.removeFirst() } }
    }
    private func scheduleBannerEnd(_ b: Banner) {
        Task { try? await Task.sleep(for: .seconds(b.kind == .failed ? 4.2 : 3.2)); if banner?.id == b.id { dismissBanner() } }
    }
    func dismissBanner() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { banner = nil }
        guard !bannerQueue.isEmpty else { return }
        let next = bannerQueue.removeFirst()
        Task { try? await Task.sleep(for: .milliseconds(280)); if banner == nil { withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { banner = next }; scheduleBannerEnd(next) } else { show(next) } }
    }

    // ---- music from a PC ----
    @ObservationIgnored private var musicOfferedAt = Date()
    @ObservationIgnored private var musicAnsweredAt = Date()
    /// Continues a PC's music here: from the song's own file when the PC has one (it arrives, then plays from where the PC
    /// was), else in Apple Music or Spotify by searching for it.
    func answerMusic(_ offer: MusicOffer, play: Bool) {
        guard let l = link else { return }
        musicAnsweredAt = Date(); Notify.cancel(Notify.musicId)
        if !play { DispatchQueue.global().async { l.answerMusic(offer.transfer, 0) }; music = nil; return }
        if offer.music.fileSize > 0 { DispatchQueue.global().async { l.answerMusic(offer.transfer, 2) }; music?.fetching = true; return }
        DispatchQueue.global().async { l.answerMusic(offer.transfer, 1) }; music = nil
        Player.playFromSearch(offer.music)
    }
    /// Hands what plays here back to a PC.
    func handBack(_ m: Handoff, to peer: String) {
        guard let l = link else { return }
        Task {
            let code = await io { l.handoff(peer, music: m) }
            if code == nil { show(Banner(kind: .failed, title: "Couldn't reach the PC")) }
            else if code == 0 { show(Banner(kind: .info, title: "The PC said not now")) }
            else { Player.shared.stop(); show(Banner(kind: .music, title: "Playing on your PC", detail: m.title)) }
        }
    }

    // ---- pairing ----
    private let busy = "Another pairing is under way. Finish it first"
    /// Pairs with the PC showing this code on its island (any network): its six digits then show here. [key], from the
    /// island's QR code: that PC is then known for sure, and only it asks to confirm.
    func pairWithCode(_ code: String, key: [UInt8]? = nil) {
        pairResult = nil
        guard prefs.internet else { pairResult = PairOutcome(peer: "", name: "", ok: false, detail: "Turn on Devices › Reach my PCs anywhere first"); return }
        codePairing = code
        Task {
            guard let l = await start() else { codePairing = nil; pairResult = PairOutcome(peer: "", name: "", ok: false, detail: "Starting… try again in a moment"); return }
            _ = await io { l.waitConnected(8) }
            let ok = await io { l.pairWithCode(code, key: key) }
            if !ok { codePairing = nil; pairResult = PairOutcome(peer: "", name: "", ok: false, detail: busy) }
        }
    }
    /// A pairing link (the island's QR code, scanned by the Camera app or in the app).
    func open(pairLink text: String) -> Bool {
        guard let p = Pairing.link(text) else { return false }
        pairWithCode(p.code, key: p.key); return true
    }
    func confirmPair(_ yes: Bool) { let l = link; DispatchQueue.global().async { l?.confirmPair(yes) }; if !yes { pairCode = nil } }
    func cancelCodePairing() { codePairing = nil; if pairCode?.confirmed == true { confirmPair(false) } }
    func forget(_ peer: String) {
        let l = link; DispatchQueue.global().async { l?.forget(peer) }
        if selected == peer { selected = nil; AppGroup.defaults.removeObject(forKey: "pc"); status = nil; clearIsland() }
        peers.removeAll { $0.id == peer }; pickDefault()
    }
    func rename(_ peer: String, to name: String) { let l = link; DispatchQueue.global().async { l?.rename(peer, to: name) } }

    // ---- files ----
    func answer(_ offer: Offer, accept: Bool) {
        let l = link; DispatchQueue.global().async { l?.answer(offer.transfer, accept: accept) }
        offers.removeAll { $0.transfer == offer.transfer }; Notify.cancel(Notify.offer + "\(offer.transfer)")
    }
    func answer(transfer: Int, accept: Bool) { if let o = offers.first(where: { $0.transfer == transfer }) { answer(o, accept: accept) } else { let l = link; DispatchQueue.global().async { l?.answer(transfer, accept: accept) } } }
    func cancel(_ transfer: Int) { let l = link; DispatchQueue.global().async { l?.cancel(transfer) } }

    /// Files (already on this iPhone, copied in from Photos, Files or another app) to a PC, in one transfer.
    /// [toShelf]: onto its island's Shelf. The transfer's number, or nil.
    @discardableResult func send(_ peer: String, files: [URL], toShelf: Bool = false, ask: Int = 0, title given: String? = nil) async -> Int? {
        guard !files.isEmpty else { return nil }
        guard let l = await start() else { show(Banner(kind: .failed, title: "Not connected", detail: "Try again in a moment")); return nil }
        let sources = await io { Sources.of(files) }
        guard !sources.isEmpty else { show(Banner(kind: .failed, title: "Couldn't read those files")); return nil }
        let names = files.map(\.lastPathComponent)
        let title = given ?? (names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more")
        let preview = await Previews.of(files[0])
        let folder = files.count == 1 && (try? files[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let id = await io { l.send(peer, items: sources, title: title, folder: folder, toShelf: toShelf, preview: preview, ask: ask) }
        let name = peers.first { $0.id == peer }?.name ?? "your PC"
        transfers[id] = Transfer(id: id, peer: peer, name: name, title: title, done: 0, total: sources.reduce(0) { $0 + $1.size }, outgoing: true)
        LiveActivities.shared.transfer(transfers[id]!)
        return id
    }
    /// Takes an item from a PC's Shelf onto this iPhone.
    func take(_ peer: String, index: Int, item: ShelfItem) { let l = link; DispatchQueue.global().async { _ = l?.take(peer, index: index, name: item.name) } }
    func shelf(_ peer: String) async -> ShelfList { if Demo.on { return Sample.shelf(preview: Demo.shelfPreview) }; guard let l = link else { return ShelfList(shared: false, items: [], error: "Not connected yet") }; return await io { l.shelf(peer) } }

    private func remember(_ m: Moment) { moments.insert(m, at: 0); if moments.count > 40 { moments.removeLast(moments.count - 40) }; saveMoments() }
    private func saveMoments() { if let d = try? JSONEncoder().encode(moments) { AppGroup.defaults.set(d, forKey: "moments") } }
    private func loadMoments() -> [Moment] { AppGroup.defaults.data(forKey: "moments").flatMap { try? JSONDecoder().decode([Moment].self, from: $0) } ?? [] }
    func clearMoments() { withAnimation { moments = [] }; saveMoments() }

    // ---- the remote ----
    /// One remote command to the chosen PC; nil (with a banner saying why) when it couldn't be done.
    @discardableResult func command(_ cmd: Int, _ payload: [UInt8] = [], quiet: Bool = false) async -> RemoteReply? {
        guard let l = link, let p = pc() else { if !quiet { show(Banner(kind: .failed, title: "No PC yet", detail: "Pair with your PC first")) }; return nil }
        if !p.remote && p.online { if !quiet { show(Banner(kind: .failed, title: "Update Arnav Island on \(p.name)", detail: "The remote needs version 0.19 or later")) }; return nil }
        let reply = await io { l.remote(p.id, cmd, payload) }
        if quiet { return reply }
        if reply == nil { show(Banner(kind: .failed, title: "\(p.name) didn't answer", detail: l.lastRemoteError.isEmpty ? "Is Arnav Island running there?" : l.lastRemoteError)) }
        else if reply!.status == Proto.notAllowed { show(Banner(kind: .failed, title: "\(p.name) said no", detail: "Turn on “My phone can control this PC” in the island’s Settings")) }
        else if !reply!.ok { show(Banner(kind: .failed, title: "\(p.name) couldn't do that")) }
        return reply
    }
    /// The chosen PC's status (its media with the cover, sound, battery...), refreshed while the remote shows.
    @discardableResult func refreshStatus() async -> PcStatus? {
        guard let l = link, let p = pc() else { return nil }
        if !p.online { statusError = "\(p.name) is away"; return nil }
        if !p.remote { statusError = "Update Arnav Island on \(p.name) for the remote"; return nil }
        let previous = status.flatMap { $0.pcName.isEmpty ? nil : $0 }
        let s = await io { l.status(p.id, haveCover: previous?.coverHash, previous: previous) }
        guard let s else { statusError = l.lastRemoteError.isEmpty ? "\(p.name) didn't answer" : l.lastRemoteError; return nil }
        statusError = nil
        let coverChanged = s.coverHash != status?.coverHash || (cover == nil && s.cover != nil)
        status = s
        if coverChanged { coverArrived(s.cover) }
        lyricsFor(p, s)
        Snapshotter.shared.status(s, pc: p)
        LiveActivities.shared.nowPlaying(s, pc: p)
        return s
    }
    private func coverArrived(_ bytes: [UInt8]?) {
        guard let bytes, !bytes.isEmpty, let image = UIImage(data: Data(bytes)) else {
            withAnimation(.easeInOut(duration: 1.2)) { cover = nil; palette = .standard }; return
        }
        let p = Art.palette(image) ?? .standard
        withAnimation(.easeInOut(duration: 1.2)) { cover = image; palette = p }
    }
    /// Seconds into the song now, run on from the last status.
    func position(_ now: Date = Date()) -> Double { status?.positionNow(now) ?? 0 }

    func media(_ action: Int) async { Haptics.tap(); if await command(Proto.cmdMedia, [UInt8(action)])?.ok == true, action == 1, var s = status { s.playing.toggle(); s.position = s.positionNow(); s.at = Date(); status = s }; try? await Task.sleep(for: .milliseconds(250)); await refreshStatus() }
    func setVolume(_ v: Int) async { let v = min(100, max(0, v)); status?.volume = v; await command(Proto.cmdVolume, [UInt8(v)], quiet: true) }
    func toggleMute() async { status?.muted.toggle(); await command(Proto.cmdMute); await refreshStatus() }
    func seek(to seconds: Double) async { if var s = status { s.position = seconds; s.at = Date(); status = s }; await command(Proto.cmdSeek, Wire().f64(seconds).build(), quiet: true) }
    func lockPC() async -> Bool { await command(Proto.cmdLock)?.ok == true }
    func openOnPC(_ url: URL) async -> Bool { await command(Proto.cmdOpen, Array(url.absoluteString.utf8))?.ok == true }
    /// A page to the PC, at the same place (island 0.25).
    func pageToPC(_ url: URL, title: String, scroll: Double) async -> Bool {
        guard let p = pc() else { show(Banner(kind: .failed, title: "No PC yet", detail: "Pair with your PC first")); return false }
        if p.revision < 8 { return await openOnPC(url) }
        let ok = await command(Proto.cmdPage, Frames.page(url: url.absoluteString, title: title, scroll: Float(scroll)))?.ok == true
        if ok { Haptics.success(); show(Banner(kind: .page, title: "Opened on \(p.name)", detail: title.isEmpty ? (url.host ?? "") : title)) }
        return ok
    }
    /// The PC's clipboard, here.
    func clipboardFromPC() async {
        guard let r = await command(Proto.cmdClipGet), r.ok else { return }
        let text = String(decoding: r.payload, as: UTF8.self)
        if text.isEmpty { show(Banner(kind: .info, title: "Nothing to paste", detail: "The PC's clipboard has no text")); return }
        UIPasteboard.general.string = text; Haptics.success()
        show(Banner(kind: .clipboard, title: "Copied from your PC", detail: String(text.split(separator: "\n").first ?? "").prefix(60).description))
    }
    /// Text to the PC's clipboard.
    func clipboardToPC(_ text: String) async {
        guard !text.isEmpty else { return }
        if await command(Proto.cmdClipSet, Array(text.prefix(100_000).utf8))?.ok == true {
            Haptics.success(); show(Banner(kind: .clipboard, title: "On \(pc()?.name ?? "your PC")’s clipboard", detail: String(text.split(separator: "\n").first ?? "").prefix(60).description))
        }
    }
    /// With automatic copies on, a new copy here goes to the PC when the app comes forward (iOS asks once to allow pasting).
    @ObservationIgnored private var lastPasteboard = UIPasteboard.general.changeCount
    func clipboardOut() {
        guard prefs.clipAuto, let p = pc(), p.online else { return }
        let count = UIPasteboard.general.changeCount; guard count != lastPasteboard else { return }; lastPasteboard = count
        guard UIPasteboard.general.hasStrings else { return }
        Task {
            var s = status; for _ in 0..<30 where s == nil { try? await Task.sleep(for: .milliseconds(100)); s = status }
            guard s?.clipboard == true, let text = UIPasteboard.general.string, !text.isEmpty, text != lastFromPC else { return }
            await clipboardToPC(text)
        }
    }
    @ObservationIgnored fileprivate var lastFromPC: String?

    // ---- lyrics, find my PC ----
    @ObservationIgnored private var lyricsKey: String?
    @ObservationIgnored private var lyricsAsked = Date.distantPast
    @ObservationIgnored private var lyricsTries = 0
    /// The lyrics follow the song: asked when it changes, and again (a few times) while the PC is still looking.
    private func lyricsFor(_ p: PeerView, _ s: PcStatus) {
        if !s.available || p.revision < 3 { lyrics = nil; lyricsKey = nil; return }
        let key = s.title + "\t" + s.artist; let now = Date()
        let again = key == lyricsKey && lyrics?.state == 1 && now.timeIntervalSince(lyricsAsked) > 2.5 && lyricsTries < 12
        if key == lyricsKey && !again { return }
        if key != lyricsKey { lyricsKey = key; lyricsTries = 0; if lyrics?.key != key { lyrics = nil } }
        lyricsAsked = now; lyricsTries += 1
        guard let l = link else { return }
        Task { let got = await io { l.lyrics(p.id) }; if var got, lyricsKey == key { got.key = key; withAnimation(.easeInOut(duration: 0.4)) { lyrics = got } } }
    }
    /// Rings the chosen PC (its island chimes and says "Here I am").
    @discardableResult func ringPC() async -> Bool {
        guard let p = pc() else { show(Banner(kind: .failed, title: "No PC yet", detail: "Pair with your PC first")); return false }
        if p.online && p.revision < 3 { show(Banner(kind: .failed, title: "Update Arnav Island on \(p.name)", detail: "Find my PC needs version 0.20 or later")); return false }
        let ok = await command(Proto.cmdRingPc)?.ok == true
        if ok { Haptics.success(); show(Banner(kind: .ring, title: "Ringing \(p.name)", detail: "Its island chimes and lights up")) }
        return ok
    }

    // ---- the whole island (revision 5, island 0.22) ----
    func islandReady(_ p: PeerView? = nil) -> Bool { guard let p = p ?? pc() else { return false }; return p.online && p.revision >= 5 }
    /// The PC's controls (and, while its numbers show, its stats): asked once a second while the Island tab shows.
    func refreshIsland(withStats: Bool) async {
        guard let l = link, let p = pc(), islandReady(p) else { return }
        if withStats, let s = await io({ l.stats(p.id) }) {
            if trailPc != p.id { trailPc = p.id; statsTrail = [] }
            pcStats = s; statsCache[p.id] = s
            statsTrail.append(StatsPoint(at: Date(), cpu: s.cpu, gpu: s.gpu, download: s.download, upload: s.upload))
            if statsTrail.count > 300 { statsTrail.removeFirst(statsTrail.count - 300) }
            Snapshotter.shared.stats(s)
        }
        if let c = await io({ l.controls(p.id) }) { pcControls = c; controlsAt = Date() }
        if withStats && p.revision >= 6 { batteryTick += 1; if batteryTick % 3 == 1, let b = await io({ l.battery(p.id) }) { pcBattery = b } }
    }
    func cachedStats(_ peer: String) -> PcStats? { statsCache[peer] }
    /// Forgets what was shown for the last PC (another one was chosen).
    func clearIsland() { pcBattery = nil; islandSettings = nil; outputs = []; statsTrail = []; trailPc = nil; batteryTick = 0 }
    /// Changes a control at once here ([seen]: what it looks like meanwhile), then on the PC; what the PC says wins.
    func setControl(_ control: Int, _ value: Int, seen: (inout PcControls) -> Void = { _ in }) {
        if var c = pcControls { seen(&c); pcControls = c }
        guard let l = link, let p = pc(), islandReady(p) else { return }
        Task {
            if let c = await io({ l.setControl(p.id, control, value) }) { pcControls = c; controlsAt = Date() }
            else {
                show(Banner(kind: .failed, title: "\(p.name) couldn't do that", detail: l.lastRemoteError.isEmpty ? "Try again in a moment" : l.lastRemoteError))
                if let c = await io({ l.controls(p.id) }) { pcControls = c }
            }
        }
    }
    func setControlNow(_ control: Int, _ value: Int) async -> Bool {
        guard let l = link, let p = pc(), islandReady(p) else { return false }
        guard let c = await io({ l.setControl(p.id, control, value) }) else { return false }
        pcControls = c; controlsAt = Date(); return true
    }
    func loadIslandSettings() async { guard let l = link, let p = pc(), islandReady(p) else { return }; if let s = await io({ l.islandSettings(p.id) }) { islandSettings = s } }
    /// Changes one of the island's settings: shown at once, then set on the PC (which may keep it within its range).
    func setIslandSetting(_ key: String, _ value: Int) {
        func show(_ v: Int) { if var s = islandSettings { s.items = s.items.map { var i = $0; if i.key == key { i.value = v }; return i }; islandSettings = s } }
        let before = islandSettings?.items.first { $0.key == key }?.value; show(value)
        guard let l = link, let p = pc(), islandReady(p) else { return }
        Task {
            if let now = await io({ l.setIslandSetting(p.id, key, value) }) { show(now) }
            else { if let before { show(before) }; self.show(Banner(kind: .failed, title: "\(p.name) couldn't change that", detail: l.lastRemoteError.isEmpty ? "Try again in a moment" : l.lastRemoteError)) }
        }
    }
    func islandSettingAction(_ action: Int, done: String) {
        guard let l = link, let p = pc(), islandReady(p) else { return }
        Task { show(await io({ l.islandSettingAction(p.id, action) }) ? Banner(kind: .info, title: done, detail: "On \(p.name)") : Banner(kind: .failed, title: "\(p.name) couldn't do that")) }
    }
    /// The PC's command bar, asked again (briefly) until its results answer this text.
    func queryCommands(_ text: String) async -> CommandResults? {
        guard let l = link, let p = pc(), islandReady(p) else { return nil }
        var r = await io { l.queryCommands(p.id, text) }; var tries = 0
        while let cur = r, !cur.final, tries < 12 { tries += 1; try? await Task.sleep(for: .milliseconds(120)); r = await io { l.queryCommands(p.id, text) } }
        return r
    }
    func runCommand(_ text: String, _ index: Int, _ title: String, confirmed: Bool) async -> CommandOutcome? {
        guard let l = link, let p = pc(), islandReady(p) else { return nil }
        return await io { l.runCommand(p.id, text, index, title, confirmed: confirmed) }
    }
    func loadOutputs() async { guard let l = link, let p = pc(), islandReady(p) else { return }; if let o = await io({ l.outputs(p.id) }) { outputs = o } }
    /// Makes an output the PC's default; when the island's direct switching is off, says how to turn it on.
    func selectOutput(_ id: String) {
        outputs = outputs.map { var o = $0; o.current = o.id == id; return o }
        guard let l = link, let p = pc(), islandReady(p) else { return }
        Task {
            switch await io({ l.selectOutput(p.id, id) }) {
            case Proto.ok: Haptics.tick()
            case Proto.notAllowed: show(Banner(kind: .info, title: "Direct output switching is off", detail: "Turn it on below, in Media & sound"))
            default: show(Banner(kind: .failed, title: "\(p.name) couldn't switch the sound"))
            }
            try? await Task.sleep(for: .milliseconds(600)); if let o = await io({ l.outputs(p.id) }) { outputs = o }
        }
    }
    func openIslandPage(_ page: Int) { guard let l = link, let p = pc(), islandReady(p) else { return }; Task { if !(await io { l.openIslandPage(p.id, page) }) { show(Banner(kind: .failed, title: "\(p.name) couldn't open that")) } } }
    func closeIsland() { guard let l = link, let p = pc(), islandReady(p) else { return }; Task { _ = await io { l.closeIsland(p.id) } } }

    // ---- what a PC asks this iPhone (revision 6) ----
    private func loadFocus() -> FocusClock? {
        guard let d = AppGroup.defaults.data(forKey: "focus"), let f = try? JSONDecoder().decode(FocusClock.self, from: d) else { return nil }
        // A countdown that has run out while this iPhone wasn't told is over.
        return (!f.running || f.mode == 2 || focusEnd(f) > Date()) ? f : nil
    }
    func focusEnd(_ f: FocusClock) -> Date { f.at.addingTimeInterval(max(0, f.duration - f.shown)) }
    fileprivate func focusArrived(_ f: FocusClock) {
        focus = f; if let d = try? JSONEncoder().encode(f) { AppGroup.defaults.set(d, forKey: "focus") }
        LiveActivities.shared.focus(f); Snapshotter.shared.reload()
    }
    /// Called on a link thread: answers what a paired PC asks.
    nonisolated static func answerQuery(_ peer: String, _ command: Int, _ payload: [UInt8]) -> [UInt8]? {
        let paired = DispatchQueue.main.sync { MainActor.assumeIsolated { Hub.shared.peers.contains { $0.id == peer && $0.paired } } }
        guard paired else { return nil }
        switch command {
        case Proto.queryReadings:
            let lines = DispatchQueue.main.sync { MainActor.assumeIsolated { DeviceInfo.live() } }
            let text = Array(lines.map { $0.0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") + "\t" + $0.1.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n").prefix(12_000).utf8)
            let cover = DispatchQueue.main.sync { MainActor.assumeIsolated { Player.shared.coverJPEG() } } ?? []
            return Wire().u32(text.count).raw(text).u32(cover.count).raw(cover).build()
        case Proto.queryFocus:
            guard let f = IslandWire.focus(payload) else { return nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { Hub.shared.focusArrived(f) } }
            return []
        case Proto.queryPhoto:
            let r = Reader(payload); guard let id = r.u64() else { return nil }; let purpose = r.u8() ?? 1; let ask = r.u32() ?? 0
            guard RecentPhotos.told.has(peer, id) else { return nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { RecentPhotos.shared.send(peer: peer, id: id, toShelf: purpose == 2, ask: ask) } }
            return []
        case Proto.queryPage:
            let r = Reader(payload); let scroll = Double(r.f32() ?? 0)
            guard let s = r.string(4096), let url = URL(string: s), url.scheme == "https" || url.scheme == "http" else { return nil }
            let title = r.string(400) ?? ""
            DispatchQueue.main.async { MainActor.assumeIsolated { Hub.shared.pageArrived(peer: peer, url: url, title: title, scroll: scroll) } }
            return []
        default: return nil
        }
    }
    fileprivate func pageArrived(peer: String, url: URL, title: String, scroll: Double) {
        let from = peers.first { $0.id == peer }?.name ?? "your PC"
        Haptics.notify()
        page = PageArrival(from: from, peer: peer, url: url, title: title, scroll: max(0, min(1, scroll)))
        if !visible { Notify.page(from: from, url: url, title: title, scroll: scroll) }
    }
    /// Called on a link thread: the PC's universal clipboard pushed a copy.
    nonisolated static func clipboardIn(_ text: String, _ sensitive: Bool) -> Bool {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let hub = Hub.shared
                if sensitive { UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.expirationDate: Date().addingTimeInterval(120), .localOnly: true]) }
                else { UIPasteboard.general.string = text }
                hub.lastPasteboard = UIPasteboard.general.changeCount; hub.lastFromPC = text
                if hub.visible { hub.show(Banner(kind: .clipboard, title: "Copied from your PC", detail: sensitive ? "Hidden (a password): clears in 2 minutes" : String(String(text.split(separator: "\n").first ?? "").prefix(60)))) }
                return true
            }
        }
    }

    // ---- the camera, for a PC's Shelf ----
    /// The PC that asked for a photo (else the chosen one).
    @ObservationIgnored var photoFor: String?
    /// A photo just taken for a PC: onto its Shelf.
    func sendPhoto(_ file: URL) {
        let target = photoFor.flatMap { id in peers.first { $0.id == id && $0.paired } } ?? pc()
        photoFor = nil; Notify.cancel(Notify.photoId)
        guard let target else { show(Banner(kind: .failed, title: "No PC yet", detail: "Pair with your PC first")); return }
        Task { await send(target.id, files: [file], toShelf: target.revision >= 3) }
        show(Banner(kind: .photo, title: "On its way to \(target.name)", detail: target.revision >= 3 ? "It lands on the island’s Shelf" : "It goes to the PC’s Downloads"))
    }

    // ---- this iPhone for the island ----
    @ObservationIgnored private var sentBattery = -2
    @ObservationIgnored private var sentCharging = false
    /// The battery level (and whether it charges) to every paired PC that is here, when it changed.
    func sendBattery(force: Bool = false) {
        let (percent, charging) = DeviceInfo.battery()
        BatteryForecast.record(percent, charging)
        guard prefs.battery, let l = link else { return }
        if !force && percent == sentBattery && charging == sentCharging { return }
        sentBattery = percent; sentCharging = charging
        let frame = Frames.status(battery: max(0, percent), charging: charging)
        let targets = peers.filter { $0.paired && $0.online && $0.remote }.map(\.id)
        DispatchQueue.global().async { for t in targets { _ = l.notice(t, frame) } }
        sendDetails()
    }
    @ObservationIgnored private var sentDetails: [String]?
    @ObservationIgnored private var detailsAt = Date.distantPast
    /// This iPhone's readings to every paired island that shows them (0.20), when they changed, at least every five minutes
    /// while the iPhone is here, and at once when a PC arrives.
    func sendDetails(force: Bool = false) {
        guard prefs.details, let l = link else { return }
        let targets = peers.filter { $0.paired && $0.online && $0.revision >= 3 && !$0.phone }.map(\.id); guard !targets.isEmpty else { return }
        let d = DeviceInfo.read(); let compared = d.filter { $0.0 != "Uptime" }.map { $0.0 + "=" + $0.1 }; let now = Date()
        if !force && compared == sentDetails && now.timeIntervalSince(detailsAt) < 300 { return }
        sentDetails = compared; detailsAt = now
        let frame = Frames.details(d)
        DispatchQueue.global().async { for t in targets { _ = l.notice(t, frame) } }
    }
    /// A photo you just took, told to the PCs (its small picture).
    func notice(_ peer: String, _ frame: [UInt8]) async -> Bool { guard let l = link else { return false }; return await io { l.notice(peer, frame) } }

    // ---- sessions ----
    func openInput() async -> InputSession? { guard let l = link, let p = pc() else { return nil }; return await io { l.openInput(p.id) } }
    func openScreen(_ request: [UInt8]) async -> (ScreenSession, [UInt8])? { guard let l = link, let p = pc() else { return nil }; return await io { l.openScreen(p.id, request: request) } }
}

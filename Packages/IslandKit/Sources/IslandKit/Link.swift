import CryptoKit
import Foundation

/// Pairing codes and links, as an island shows them.
public enum Pairing {
    /// A typed code made canonical ("7k2p mx4q" becomes "7K2PMX4Q"), or nil when it can't be one.
    public static func code(_ typed: String) -> String? { Relay.code(typed) }
    /// An island's pairing link (its QR code): "arnavisland://pair/<code>?k=<key print>".
    public static func link(_ text: String) -> PairLink? { Relay.pairLink(text) }
}

/// A person's answer, waited for by a session thread (a CompletableFuture).
final class Decision {
    private let cond = NSCondition(); private var value: Int?
    func complete(_ v: Int) { cond.lock(); if value == nil { value = v; cond.broadcast() }; cond.unlock() }
    var done: Bool { cond.lock(); defer { cond.unlock() }; return value != nil }
    func get(_ timeout: TimeInterval) -> Int? {
        cond.lock(); defer { cond.unlock() }
        let until = Date().addingTimeInterval(timeout)
        while value == nil { if !cond.wait(until: until) { break } }
        return value
    }
}

/// Arnav Island's sharing protocol on an iPhone, exactly as the Windows island speaks it: two devices pair once (each
/// showing the same six-digit code, or this app scanning the PC's QR code); after that everything goes between them sealed
/// with AES-256-GCM under a key from both sides' static ECDH keys and fresh nonces. Every connection runs through the
/// relay's tunnels: through a broker, or straight to the PC over UDP when a direct path is up (on the same Wi-Fi, the LAN).
/// Methods block: call them from background queues.
public final class Link {
    public struct Options {
        public var phone = true, brokers = Relay.defaultBrokers, loseEvery = 0, direct = true, directLoopback = false
        /// A second copy of this device (the share sheet): sends, takes nothing, leaves quietly.
        public var guest = false
        public init(phone: Bool = true, loseEvery: Int = 0, direct: Bool = true, directLoopback: Bool = false, guest: Bool = false) { self.phone = phone; self.loseEvery = loseEvery; self.direct = direct; self.directLoopback = directLoopback; self.guest = guest }
    }
    private final class Peer { var name = "", key: [UInt8]?, phone = false, revision = 0 }
    private struct Target { let name: String; let key: [UInt8]; let revision: Int }
    private final class Kept { let c: Conn; let ss: Session; let path: Int; var used: Int64; init(_ c: Conn, _ ss: Session, _ path: Int, _ used: Int64) { self.c = c; self.ss = ss; self.path = path; self.used = used } }
    private final class Live { var stop = false; weak var conn: Conn? }

    private let store: LinkStore
    private let inbox: Inbox
    private let onEvent: (LinkEvent) -> Void
    private let options: Options
    public var displayName: String
    private var id: [UInt8] = []
    private var key: IdentityKey?
    public private(set) var publicKey: [UInt8] = []
    private let lock = NSLock()
    private var peers: [String: Peer] = [:]
    private var pairing: Decision?
    private var decisions: [Int: Decision] = [:]
    private var live: [Int: Live] = [:]
    private var nextTransfer = 1
    private var relay: Relay?
    private var kept: [String: Kept] = [:]
    private var keptLocks: [String: NSLock] = [:]
    public private(set) var lastRemoteError = ""
    public private(set) var failure: String?
    /// Revision 6: what a PC asks this device (peer, command, payload): the answer's payload, or nil when it can't.
    public var onQuery: ((String, Int, [UInt8]) -> [UInt8]?)?
    /// Revision 3: text a PC puts on this device's clipboard (and whether it's sensitive): true when it was kept.
    public var onClipboard: ((String, Bool) -> Bool)?

    public init(store: LinkStore, name: String, inbox: Inbox, options: Options = Options(), onEvent: @escaping (LinkEvent) -> Void) {
        self.store = store; self.inbox = inbox; self.options = options; self.onEvent = onEvent; displayName = cleanName(name)
    }
    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    public var identity: String { id.hex }
    public var internet: Bool { relay?.connected == true }
    public var relayBroker: String? { relay?.broker }
    public var relayBrokersUp: Int { relay?.brokersUp ?? 0 }

    // ---- life ----
    public func start() -> Bool {
        if let saved = store.loadIdentity(), saved.id.count == 16 { id = saved.id; key = saved.key }
        else {
            let k = IdentityKey.create(); let newId = Crypto.random(16)
            guard store.saveIdentity(StoredIdentity(id: newId, key: k)) else { failure = "The sharing key couldn't be kept"; return false }
            id = newId; key = k
        }
        publicKey = key!.publicXY
        locked {
            for p in store.loadPeers() where p.id.unhex?.count == 16 && p.key.count == 64 {
                let peer = Peer(); peer.key = p.key; peer.name = cleanName(p.name); peer.phone = p.phone; peer.revision = p.revision; peers[p.id] = peer
            }
        }
        let r = Relay(id: id, name: { [weak self] in self?.displayName ?? "iPhone" }, phone: options.phone, revision: Proto.revision, brokers: options.brokers,
                      loseEvery: options.loseEvery, direct: options.direct, directLoopback: options.directLoopback, guest: options.guest,
                      incoming: { [weak self] t, _ in let c = Conn(t); self?.incoming(c); c.close() },
                      changed: { [weak self] in self?.postPeers() })
        relay = r; r.start(); syncRelay()
        return true
    }
    public func stop() {
        dropKept(); relay?.stop(); relay = nil
        locked { pairing?.complete(0); for d in decisions.values { d.complete(0) }; for l in live.values { l.stop = true; l.conn?.close() } }
    }
    /// The network changed, or the app came back to the front: the relay reconnects at once.
    public func networkChanged() { relay?.kick(); dropKept() }
    public func waitConnected(_ seconds: TimeInterval) -> Bool { relay?.waitConnected(seconds) ?? false }
    /// The relay listens for every paired device; each pair's secret is the static ECDH of the two keys.
    private func syncRelay() {
        guard let r = relay, let k = key else { return }
        let keys = locked { peers.compactMap { (id, p) in p.key.map { (id, $0) } } }
        r.pairs(keys.compactMap { (peer, pub) in guard let agreed = k.agree(pub), let pid = peer.unhex else { return nil }; return Relay.RelayPair(peer: pid, agreed: agreed) })
    }
    private func savePeers() { store.savePeers(peers.compactMap { (id, p) in p.key.map { StoredPeer(id: id, key: $0, name: p.name, phone: p.phone, revision: p.revision) } }) }
    private func postPeers() { onEvent(.internet(internet)); onEvent(.peers(peerViews())) }

    public func peerViews() -> [PeerView] {
        let list: [(String, Peer)] = locked { peers.filter { $0.value.key != nil }.map { ($0.key, $0.value) } }
        return list.map { (id, p) in
            let r = relay?.presence(id); let path = relay?.path(id)
            return PeerView(id: id, name: p.name.isEmpty ? "A PC" : p.name, paired: true, online: r?.here == true, phone: p.phone || r?.phone == true, version: Proto.version,
                            revision: r?.here == true ? r!.revision : p.revision, internet: path?.lan != true, path: path?.kind ?? 0, rtt: path?.rtt ?? 0, relays: path?.brokers ?? 0,
                            v6: path?.v6 == true, lan: path?.lan == true)
        }.sorted { $0.online != $1.online ? $0.online : $0.name < $1.name }
    }

    // ---- sessions ----
    private func keys(_ ss: Session, initiator: Bool, mine: [UInt8], theirs: [UInt8]) -> Bool {
        guard let k = key, let secret = k.agree(ss.peerPub) else { return false }
        let nc = initiator ? mine : theirs, ns = initiator ? theirs : mine
        let pc = initiator ? publicKey : ss.peerPub, ps = initiator ? ss.peerPub : publicKey
        let ic = initiator ? id : ss.peerId, iss = initiator ? ss.peerId : id
        let sessionKey = Crypto.sha256("arnav-share-v1", secret, nc, ns, ic, iss)
        let c = Crypto.sha256("arnav-pair-v1", pc, ps, nc, ns)
        ss.code = Int((UInt32(c[0]) | UInt32(c[1]) << 8 | UInt32(c[2]) << 16 | UInt32(c[3]) << 24) % 1_000_000)
        ss.channel = Channel(key: sessionKey, initiator: initiator)
        return true
    }
    /// The opener commits to its nonce (a hash) before it sees the other's, so neither side can steer the code.
    private func greet(_ c: Conn, _ mode: Int, _ ss: Session) -> Bool {
        let nonce = Crypto.random(32)
        c.send(Wire().raw(Proto.magic).u8(Proto.version).u8(mode).raw(id).raw(publicKey).raw(Crypto.sha256(nonce)).text(displayName).build())
        guard let reply = try? c.recv(), reply.count >= 6, Array(reply[0..<4]) == Proto.magic else { return false }
        if Int(reply[4]) != Proto.version || reply[5] == 2 { ss.outdated = true; return false }
        if reply[5] != 0 { ss.rejected = true; return false }
        guard reply.count >= 6 + 16 + 64 + 32 else { return false }
        ss.peerId = Array(reply[6..<22]); ss.peerPub = Array(reply[22..<86]); let theirs = Array(reply[86..<118])
        ss.peerName = cleanName(Array(reply[118...]).utf8String)
        c.send(nonce)
        return keys(ss, initiator: true, mine: nonce, theirs: theirs)
    }
    private func welcome(_ c: Conn, _ ss: Session) -> (Int, Decision?)? {
        guard let hello = try? c.recv(), hello.count >= 6, Array(hello[0..<4]) == Proto.magic else { return nil }
        if Int(hello[4]) != Proto.version { c.send(Wire().raw(Proto.magic).u8(Proto.version).u8(2).build()); return nil }
        guard hello.count >= 6 + 16 + 64 + 32 else { return nil }
        let mode = Int(hello[5])
        ss.peerId = Array(hello[6..<22]); ss.peerPub = Array(hello[22..<86]); let commit = Array(hello[86..<118])
        ss.peerName = cleanName(Array(hello[118...]).utf8String); if sameBytes(ss.peerId, id) { return nil }
        var claim: Decision? = nil; var allowed = false
        locked {
            if mode == Proto.modePair && pairing == nil { claim = Decision(); pairing = claim; allowed = true }
            else if [Proto.modeSend, Proto.modeMusic, Proto.modeFind, Proto.modeList, Proto.modeTake, Proto.modeAction, Proto.modeClip, Proto.modeCamera, Proto.modeQuery].contains(mode) {
                if let k = peers[ss.peerId.hex]?.key { allowed = sameBytes(k, ss.peerPub) }
            }
        }
        if !allowed { c.send(Wire().raw(Proto.magic).u8(Proto.version).u8(1).build()); return nil }
        let nonce = Crypto.random(32)
        c.send(Wire().raw(Proto.magic).u8(Proto.version).u8(0).raw(id).raw(publicKey).raw(nonce).text(displayName).build())
        guard let theirs = try? c.recv(), theirs.count == 32, sameBytes(Crypto.sha256(theirs), commit), keys(ss, initiator: false, mine: nonce, theirs: theirs) else { if let d = claim { release(d) }; return nil }
        return (mode, claim)
    }
    private func release(_ d: Decision) { locked { if pairing === d { pairing = nil } } }

    private func incoming(_ c: Conn) {
        c.timeout = 15; let ss = Session()
        guard let (mode, claim) = welcome(c, ss) else { return }
        switch mode {
        case Proto.modePair: pairSession(c, ss, claim!, confirmed: false)
        case Proto.modeMusic: receiveMusic(c, ss)
        case Proto.modeFind: ringed(c, ss)
        case Proto.modeSend: receive(c, ss)
        // A phone keeps no Shelf of its own to show: it says so, and gives nothing.
        case Proto.modeList: _ = c.sealed(ss, Wire().u8(Proto.frameShelf).u8(0).u32(0).build()); Thread.sleep(forTimeInterval: 0.3)
        case Proto.modeTake: _ = c.sealed(ss, Wire().u8(Proto.frameOffer).u32(0).build()); Thread.sleep(forTimeInterval: 0.3)
        case Proto.modeAction:
            // Other apps' notification actions aren't this app's to run (iOS keeps them to itself): 1, gone.
            guard let f = c.opened(ss), f.first == UInt8(Proto.frameAction) else { return }
            _ = c.sealed(ss, [UInt8(Proto.frameActionAck), 1]); Thread.sleep(forTimeInterval: 0.3)
        case Proto.modeClip:
            guard let f = c.opened(ss) else { return }; let r = Reader(f); guard r.u8() == Proto.frameClip else { return }
            let sensitive = (r.u8() ?? 0) != 0; guard let text = r.string(256 * 1024) else { return }
            let done = onClipboard?(text, sensitive) ?? false
            _ = c.sealed(ss, [UInt8(Proto.frameClipAck), done ? 0 : 2]); Thread.sleep(forTimeInterval: 0.3)
        // Revision 6: a PC's questions, on a connection it keeps open while it asks (a minute apart at most).
        case Proto.modeQuery:
            let peer = ss.peerId.hex; c.timeout = 60
            while true {
                guard let f = c.opened(ss), f.count >= 2, Int(f[0]) == Proto.frameQuery else { break }
                let answer = onQuery?(peer, Int(f[1]), Array(f[2...]))
                if !c.sealed(ss, Wire().u8(Proto.frameQueryReply).u8(answer != nil ? Proto.ok : Proto.failed).raw(answer ?? []).build()) { break }
            }
        case Proto.modeCamera:
            guard let f = c.opened(ss), f.count == 1, Int(f[0]) == Proto.frameCamera else { return }
            _ = c.sealed(ss, [UInt8(Proto.frameCameraAck), 0])
            onEvent(.photoRequested(peer: ss.peerId.hex, name: nameOf(ss.peerId.hex, ss.peerName))); Thread.sleep(forTimeInterval: 0.3)
        default: break
        }
    }

    // ---- pairing ----
    /// Both devices show the code; each person's answer goes to the other, sealed. Paired only when both said yes.
    private func pairSession(_ c: Conn, _ ss: Session, _ d: Decision, confirmed: Bool) {
        let peer = ss.peerId.hex
        onEvent(.pairCode(peer: peer, name: ss.peerName, code: ss.code, confirmed: confirmed))
        c.timeout = 90
        let mine = d.get(60) ?? 0; d.complete(0)
        let theirs = c.sealed(ss, [mine == 1 ? 1 : 0]) ? c.opened(ss) : nil
        let talked = theirs?.count == 1
        let both = talked && mine == 1 && theirs![0] == 1
        if both {
            locked { let p = peers[peer] ?? Peer(); p.key = ss.peerPub; if p.name.isEmpty || p.name == "A PC" { p.name = ss.peerName }; peers[peer] = p; savePeers() }
            syncRelay(); relay?.stopHosting()
        }
        release(d)
        onEvent(.paired(peer: peer, name: ss.peerName, ok: both, detail: both ? "Paired" : !talked ? "The other device stopped answering" : mine != 1 ? "Not paired" : "Not confirmed on the other device"))
        postPeers()
    }
    public func confirmPair(_ yes: Bool) { locked { pairing }?.complete(yes ? 1 : 0) }
    public var pairingBusy: Bool { locked { pairing != nil } }
    public func forget(_ peer: String) { locked { peers[peer]?.key = nil; peers.removeValue(forKey: peer); savePeers() }; syncRelay(); postPeers() }
    public func rename(_ peer: String, to name: String) { locked { peers[peer]?.name = cleanName(name); savePeers() }; postPeers() }
    /// Offers a pairing code for ten minutes (blocks up to 8 s); nil when the relay can't be reached.
    public func hostPairing() -> String? { relay?.host() }
    public func stopHosting() { relay?.stopHosting() }
    /// Pairs with the device showing this code, through the relay. [key], from its QR code: the start of that device's key
    /// fingerprint. A device with another key is refused, and this device's yes is given at once (the PC still asks).
    public func pairWithCode(_ code: String, key keyPrint: [UInt8]? = nil) -> Bool {
        let d: Decision? = locked { if pairing != nil { return nil }; let d = Decision(); pairing = d; return d }
        guard let d else { return false }
        spawn("link-pair-code") { [weak self] in
            guard let self else { return }
            _ = self.relay?.waitConnected(15)
            // Asked up to three times: the other device may join a broker a moment after this one asked on it.
            for attempt in 1...3 {
                let (t, why) = self.relay?.openCode(code) ?? (nil, "Connecting over the internet is off")
                guard let tunnel = t else { self.release(d); self.onEvent(.paired(peer: "", name: "", ok: false, detail: why)); return }
                let c = Conn(tunnel); defer { c.close() }
                c.timeout = 8; let ss = Session()
                if self.greet(c, Proto.modePair, ss) {
                    guard let kp = keyPrint else { c.timeout = 20; self.pairSession(c, ss, d, confirmed: false); return }
                    if sameBytes(Crypto.keyPrint(ss.peerPub), kp) { d.complete(1); c.timeout = 20; self.pairSession(c, ss, d, confirmed: true); return }
                    // Not the PC whose code was scanned: someone else is answering it. Nothing more is said to them.
                    self.release(d); self.onEvent(.paired(peer: "", name: "", ok: false, detail: "Another device answered that code, so nothing was paired. Make a new code on your PC")); return
                }
                if ss.rejected || attempt == 3 { self.release(d); self.onEvent(.paired(peer: "", name: "", ok: false, detail: ss.rejected ? "That device is busy pairing" : "No device is showing that code. Check it, or make a new one")); return }
            }
        }
        return true
    }

    // ---- connecting to a paired device ----
    private func target(_ peer: String) -> (Target?, String) {
        let p = locked { peers[peer] }
        guard let p, let k = p.key else { return (nil, "Pair with this PC first") }
        guard let r = relay?.presence(peer), r.here else { return (nil, "\(p.name) isn't reachable right now") }
        if r.revision != p.revision { locked { p.revision = r.revision; savePeers() } }
        return (Target(name: p.name, key: k, revision: r.revision), "")
    }
    /// Reached, greeted and checked against the pairing: the connection and session, or why not.
    private func reach(_ peer: String, _ mode: Int, _ transfer: Int?) -> (Conn?, Session, String) {
        let ss = Session(); let (t, whyNot) = target(peer); guard let t else { return (nil, ss, whyNot) }
        let (tunnel, why) = relay?.open(peer) ?? (nil, "Couldn't reach \(t.name)")
        guard let tunnel else { return (nil, ss, why.isEmpty ? "Couldn't reach \(t.name)" : why) }
        let c = Conn(tunnel)
        if let tr = transfer { let l = locked { live[tr] }; if l == nil || l!.stop { c.close(); return (nil, ss, "You stopped it") }; l!.conn = c }
        c.timeout = 15
        if !greet(c, mode, ss) { c.close(); return (nil, ss, ss.outdated ? "Update Arnav Island on \(t.name) to share with it" : ss.rejected ? "\(t.name) doesn't have this iPhone paired. Pair again." : "Couldn't reach \(t.name)") }
        if ss.peerId.hex != peer || !sameBytes(ss.peerPub, t.key) { c.close(); return (nil, ss, "\(t.name) answered with a different key. Pair again.") }
        return (c, ss, "")
    }
    private func nameOf(_ peer: String, _ fallback: String) -> String { locked { peers[peer]?.name }.flatMap { $0.isEmpty ? nil : $0 } ?? cleanName(fallback) }
    private func newTransfer() -> Int { locked { let t = nextTransfer; nextTransfer += 1; live[t] = Live(); return t } }
    private func stopped(_ t: Int) -> Bool { locked { live[t]?.stop ?? true } }
    private func finish(_ t: Int) { locked { live.removeValue(forKey: t); decisions.removeValue(forKey: t) } }
    public func cancel(_ transfer: Int) { let (l, d) = locked { (live[transfer], decisions[transfer]) }; l?.stop = true; d?.complete(0); l?.conn?.close() }

    private final class Progress {
        let transfer: Int, peer: String, name: String, title: String, total: Int64, outgoing: Bool
        var done: Int64 = 0; private var shown = -1; private var at = Date.distantPast
        let emit: (LinkEvent) -> Void
        init(_ transfer: Int, _ peer: String, _ name: String, _ title: String, _ total: Int64, _ outgoing: Bool, _ emit: @escaping (LinkEvent) -> Void) { self.transfer = transfer; self.peer = peer; self.name = name; self.title = title; self.total = total; self.outgoing = outgoing; self.emit = emit }
        func add(_ n: Int64) {
            done += n; let percent = total > 0 ? Int(done * 100 / total) : 100; let now = Date()
            if percent != shown && (now.timeIntervalSince(at) >= 0.1 || done == total) { shown = percent; at = now; emit(.progress(transfer: transfer, peer: peer, name: name, title: title, done: done, total: total, outgoing: outgoing)) }
        }
    }

    // ---- sending files ----
    /// Sends these items to a paired PC in one transfer; returns its id (for cancel). [preview]: a small JPEG the PC shows as
    /// it arrives; [ask]: the PC's ask this answers; [toShelf]: onto its island's Shelf.
    public func send(_ peer: String, items: [Source], title: String, folder: Bool = false, toShelf: Bool = false, preview: [UInt8]? = nil, ask: Int = 0) -> Int {
        let transfer = newTransfer()
        spawn("link-send") { [weak self] in
            guard let self else { return }
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            let (c, ss, why0) = self.reach(peer, Proto.modeSend, transfer)
            var why = why0; var sent = false; let name = self.nameOf(peer, "")
            let revision = self.target(peer).0?.revision ?? 0
            let picture = preview.flatMap { revision >= 8 && !$0.isEmpty && $0.count <= 96 * 1024 ? $0 : nil }
            let flags = (folder ? Proto.offerFolder : 0) | (toShelf && revision >= 3 ? Proto.offerShelf : 0) | (picture != nil ? Proto.offerPicture : 0) | (ask != 0 && revision >= 8 ? Proto.offerAsked : 0)
            if let c { if let failed = self.offerBatch(c, ss, items, total, flags, title, peer, name, transfer, picture, ask) { why = failed } else { sent = true }; c.close() }
            self.finish(transfer)
            self.onEvent(sent ? .sent(transfer: transfer, peer: peer, name: name, title: title, count: items.count, size: total) : .failed(transfer: transfer, peer: peer, name: name, title: title, detail: why.isEmpty ? "It didn't go" : why, outgoing: true))
        }
        return transfer
    }
    private func offerBatch(_ c: Conn, _ ss: Session, _ items: [Source], _ total: Int64, _ flags: Int, _ title: String, _ peer: String, _ name: String, _ transfer: Int, _ picture: [UInt8]?, _ ask: Int) -> String? {
        c.timeout = 90
        // Revision 8: with a picture or an ask, each part carries its length (before, the title ran to the end).
        let offer = Wire().u8(Proto.frameOffer).u32(items.count).i64(total).u8(flags)
        if flags & (Proto.offerPicture | Proto.offerAsked) != 0 { offer.string(String(title.prefix(1000))); if flags & Proto.offerPicture != 0 { offer.blob(picture ?? []) }; if flags & Proto.offerAsked != 0 { offer.u32(ask) } }
        else { offer.text(title) }
        let reply = c.sealed(ss, offer.build()) ? c.opened(ss) : nil
        guard let reply, reply.count == 1 else { return stopped(transfer) ? "You stopped it" : "\(name) didn't answer" }
        if reply[0] == 2 { return "There isn't room on \(name)" }
        if reply[0] != 1 { return "\(name) declined it" }
        c.timeout = 30
        let progress = Progress(transfer, peer, name, title, total, true, onEvent)
        for item in items { if !streamFile(c, ss, item, progress, transfer) { return stopped(transfer) ? "You stopped it" : "The transfer to \(name) didn't finish" } }
        c.timeout = 60
        let ack = c.sealed(ss, [UInt8(Proto.frameBatchEnd)]) ? c.opened(ss) : nil
        return ack?.count == 1 && ack?[0] == 1 ? nil : "The transfer to \(name) didn't finish"
    }
    /// One file into the sealed stream: its header, its data in chunks, then its size and SHA-256.
    private func streamFile(_ c: Conn, _ ss: Session, _ item: Source, _ progress: Progress, _ transfer: Int) -> Bool {
        guard c.sealed(ss, Wire().u8(Proto.frameHeader).i64(item.size).text(item.rel).build()), let h = try? FileHandle(forReadingFrom: item.url) else { return false }
        defer { try? h.close() }
        var hash = Sha256Stream(); var done: Int64 = 0
        while done < item.size {
            if stopped(transfer) { return false }
            let want = Int(min(Int64(Proto.chunk), item.size - done))
            guard let d = try? h.read(upToCount: want), d.count == want else { return false }
            var frame = [UInt8](repeating: UInt8(Proto.frameData), count: 1); frame.append(contentsOf: d)
            if !c.sealed(ss, frame) { return false }
            hash.update(frame[1...]); done += Int64(want); progress.add(Int64(want))
            // Keeps what waits to go small: the relay's window paces the rest.
            while (c.pipe as? Relay.Tunnel)?.outbound.available ?? 0 > 4 << 20 && !c.closed { Thread.sleep(forTimeInterval: 0.02) }
        }
        return c.sealed(ss, Wire().u8(Proto.frameEnd).i64(item.size).raw(hash.finalize()).build())
    }

    // ---- receiving files ----
    private func receive(_ c: Conn, _ ss: Session) {
        let peer = ss.peerId.hex; let from = nameOf(peer, ss.peerName)
        guard let offer = c.opened(ss) else { return }
        let r = Reader(offer); guard r.u8() == Proto.frameOffer, let count = r.u32(), let total = r.i64(), let flags = r.u8() else { return }
        let title = flags & (Proto.offerPicture | Proto.offerAsked) != 0 ? cleanName(r.string(4096) ?? "") : cleanName(r.rest().utf8String)
        if count == 0 || count > Proto.maxFiles || total < 0 || total > Proto.maxTotal { return }
        let transfer = newTransfer(); locked { live[transfer]?.conn = c }
        let d = Decision(); locked { decisions[transfer] = d }
        onEvent(.offer(transfer: transfer, peer: peer, name: from, title: title, count: count, size: total, folder: flags & Proto.offerFolder != 0))
        c.timeout = 90
        var yes = decide(c, d)
        locked { _ = decisions.removeValue(forKey: transfer) }
        if yes == -1 { finish(transfer); onEvent(.failed(transfer: transfer, peer: peer, name: from, title: title, detail: "\(from) stopped sending it", outgoing: false)); return }
        if yes == 1 && !inbox.room(total) { yes = 2 }
        let told = c.sealed(ss, [UInt8(yes)])
        if !told || yes != 1 {
            let mine = stopped(transfer); finish(transfer)
            if yes == 2 { onEvent(.failed(transfer: transfer, peer: peer, name: from, title: title, detail: "There isn't room on this iPhone", outgoing: false)) }
            else if yes == 1 { onEvent(.failed(transfer: transfer, peer: peer, name: from, title: title, detail: mine ? "You stopped it" : "\(from) stopped sending it", outgoing: false)) }
            return
        }
        takeBatch(c, ss, peer, from, title, count, total, transfer, taken: false)
    }
    /// Waits (up to a minute) for the person's answer; -1 if the other side closes the connection meanwhile.
    private func decide(_ c: Conn, _ d: Decision) -> Int {
        for _ in 0..<240 {
            if let v = d.get(0.25) { return v }
            if c.ended { d.complete(0); return -1 }
        }
        d.complete(0); return 0
    }
    private func takeBatch(_ c: Conn, _ ss: Session, _ peer: String, _ from: String, _ title: String, _ count: Int, _ total: Int64, _ transfer: Int, taken: Bool) {
        c.timeout = 30
        let progress = Progress(transfer, peer, from, title, total, false, onEvent)
        var tops: [String: String] = [:]; var shown: [URL] = []; var files = 0; var whole = false
        while !stopped(transfer) {
            guard let f = c.opened(ss), !f.isEmpty else { break }
            if Int(f[0]) == Proto.frameBatchEnd { whole = files == count && progress.done == total; break }
            if Int(f[0]) != Proto.frameHeader || f.count < 10 || files >= count { break }
            let r = Reader(f, at: 1); let size = r.i64()!; var parts = safePath(r.rest().utf8String)
            if parts.isEmpty || size < 0 || size > Proto.maxFile || progress.done + size > total { break }
            if parts.count > 1 { let top = tops[parts[0]] ?? inbox.folder(parts[0]); tops[parts[0]] = top; parts[0] = top }
            guard let saved = takeFile(c, ss, size, parts, progress, transfer, song: false) else { break }
            files += 1; shown.append(saved)
        }
        let here = stopped(transfer)
        if whole { _ = c.sealed(ss, [1]) }
        finish(transfer)
        if !whole { onEvent(.failed(transfer: transfer, peer: peer, name: from, title: title, detail: here ? "You stopped it" : files > 0 ? "\(files) of \(count) files arrived from \(from)" : "It didn't arrive whole from \(from)", outgoing: false)); return }
        onEvent(.received(transfer: transfer, peer: peer, name: from, title: title, count: count, size: total, files: shown, taken: taken))
    }
    /// One incoming file (after its header), checked against its size and SHA-256 before it's kept.
    private func takeFile(_ c: Conn, _ ss: Session, _ size: Int64, _ parts: [String], _ progress: Progress, _ transfer: Int, song: Bool) -> URL? {
        guard let sink = song ? inbox.song(parts.last ?? "song", size: size) : inbox.create(parts, size: size) else { return nil }
        var hash = Sha256Stream(); var got: Int64 = 0; var done = false
        while !stopped(transfer) {
            guard let f = c.opened(ss), !f.isEmpty else { break }
            if Int(f[0]) == Proto.frameData {
                let n = Int64(f.count - 1); if got + n > size { break }
                if !sink.write(f[1...]) { break }; hash.update(f[1...]); got += n; progress.add(n)
            } else if Int(f[0]) == Proto.frameEnd && f.count == 1 + 8 + 32 { done = Reader(f, at: 1).i64() == size && got == size && sameBytes(hash.finalize(), Array(f[9..<41])); break }
            else { break }
        }
        if !done { sink.abort(); return nil }
        return sink.commit()
    }

    // ---- music ----
    private func receiveMusic(_ c: Conn, _ ss: Session) {
        let peer = ss.peerId.hex; let from = nameOf(peer, ss.peerName)
        guard let offer = c.opened(ss), offer.count >= 1 + 8 + 8 + 1 + 8 else { return }
        let r = Reader(offer); guard r.u8() == Proto.frameMusic else { return }
        let position = max(0, r.f64()!), duration = max(0, r.f64()!), playing = r.u8()! != 0, size = r.i64()!
        let rest = r.rest(); let nul = rest.firstIndex(of: 0)
        let cover: [UInt8]? = nul.flatMap { rest.count - $0 - 1 <= Proto.coverLimit ? Array(rest[($0 + 1)...]) : nil }
        let lines = Array(rest[0..<(nul ?? rest.count)]).utf8String.components(separatedBy: "\n").map { String($0.prefix(512)) } + ["", "", "", "", ""]
        let music = Handoff(title: lines[0], artist: lines[1], album: lines[2], app: lines[3], fileName: size > 0 ? safeName(lines[4]) : "", position: position, duration: duration, playing: playing, fileSize: size, cover: (cover?.isEmpty ?? true) ? nil : cover)
        if music.title.isEmpty || size < 0 || size > 2 << 30 { return }
        let transfer = newTransfer(); locked { live[transfer]?.conn = c }
        let d = Decision(); locked { decisions[transfer] = d }
        onEvent(.music(transfer: transfer, peer: peer, name: from, music: music))
        c.timeout = 90
        var code = decide(c, d); locked { _ = decisions.removeValue(forKey: transfer) }
        if code == -1 { finish(transfer); onEvent(.failed(transfer: transfer, peer: peer, name: from, title: music.title, detail: "\(from) took the music back", outgoing: false)); return }
        if code < 0 || code > 2 || (code == 2 && size == 0) { code = code == 2 ? 1 : 0 }
        if code == 2 && !inbox.room(size) { code = 1 }
        if !c.sealed(ss, [UInt8(code)]) || code != 2 { finish(transfer); Thread.sleep(forTimeInterval: 0.3); return }
        c.timeout = 30
        let progress = Progress(transfer, peer, from, music.title, size, false, onEvent)
        var saved: URL? = nil
        if let f = c.opened(ss), f.count >= 10, Int(f[0]) == Proto.frameHeader, Reader(f, at: 1).i64() == size { saved = takeFile(c, ss, size, [music.fileName.isEmpty ? "song" : music.fileName], progress, transfer, song: true) }
        let end = saved != nil ? c.opened(ss) : nil
        let whole = saved != nil && end?.count == 1 && Int(end![0]) == Proto.frameBatchEnd
        if whole { _ = c.sealed(ss, [1]) }
        finish(transfer)
        guard whole, let file = saved else { onEvent(.failed(transfer: transfer, peer: peer, name: from, title: music.title, detail: "The song didn't arrive whole from \(from)", outgoing: false)); return }
        onEvent(.musicFile(transfer: transfer, peer: peer, name: from, music: music, file: file))
    }
    /// Answers music offered to this device: 0 no, 1 yes, 2 yes and send the song's file.
    public func answerMusic(_ transfer: Int, _ code: Int) { locked { decisions[transfer] }?.complete(min(2, max(0, code))) }
    /// Answers files offered to this device.
    public func answer(_ transfer: Int, accept: Bool) { locked { decisions[transfer] }?.complete(accept ? 1 : 0) }
    /// Offers what plays here to a paired PC (no file: the PC finds the song itself). The PC's answer, or nil.
    public func handoff(_ peer: String, music: Handoff) -> Int? {
        let (c, ss, _) = reach(peer, Proto.modeMusic, nil); guard let c else { return nil }
        defer { c.close() }
        c.timeout = 90
        let text = [music.title, music.artist, music.album, music.app, ""].map { String($0.prefix(512)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\0", with: " ") }.joined(separator: "\n")
        let b = Wire().u8(Proto.frameMusic).f64(music.position).f64(music.duration).u8(music.playing ? 1 : 0).u64(0).text(text)
        if let cover = music.cover, !cover.isEmpty, cover.count <= Proto.coverLimit { b.u8(0).raw(cover) }
        guard c.sealed(ss, b.build()), let reply = c.opened(ss), reply.count == 1 else { return nil }
        return Int(reply[0])
    }

    // ---- a PC's Shelf ----
    public func shelf(_ peer: String) -> ShelfList {
        let (t, why0) = target(peer); guard let t else { return ShelfList(shared: false, items: [], error: why0) }
        if t.revision < 1 { return ShelfList(shared: false, items: [], error: "Update Arnav Island on \(t.name) to see its Shelf") }
        let (c, ss, why) = reach(peer, Proto.modeList, nil); guard let c else { return ShelfList(shared: false, items: [], error: why) }
        defer { c.close() }
        guard let list = c.opened(ss) else { return ShelfList(shared: false, items: [], error: "\(t.name) didn't answer") }
        let r = Reader(list); guard r.u8() == Proto.frameShelf else { return ShelfList(shared: false, items: [], error: "\(t.name) didn't answer") }
        let shared = (r.u8() ?? 0) != 0; let n = min(r.u32() ?? 0, Proto.shelfMax)
        var items: [ShelfItem] = []
        for _ in 0..<n {
            guard let size = r.i64(), let folder = r.u8(), let len = r.u8(), let nb = r.bytes(len), let pl = r.u32(), pl <= Proto.previewLimit, let preview = r.bytes(pl) else { break }
            items.append(ShelfItem(name: nb.utf8String, size: size, folder: folder != 0, preview: preview.isEmpty ? nil : preview))
        }
        return ShelfList(shared: shared, items: items, error: nil)
    }
    /// Takes a PC's Shelf item (by its place in the list and its name) onto this device.
    public func take(_ peer: String, index: Int, name: String) -> Int {
        let transfer = newTransfer()
        spawn("link-take") { [weak self] in
            guard let self else { return }
            let (t, why0) = self.target(peer); var why = why0; var taken = false; let pcName = t?.name ?? self.nameOf(peer, "")
            if let t, t.revision < 1 { why = "Update Arnav Island on \(t.name) to take from its Shelf" }
            else if t != nil {
                let (c, ss, w) = self.reach(peer, Proto.modeTake, transfer); why = w
                if let c {
                    c.timeout = 90
                    let offer = c.sealed(ss, Wire().u8(Proto.frameTake).u32(index).text(name).build()) ? c.opened(ss) : nil
                    if let offer, offer.count >= 5, offer[0] == UInt8(Proto.frameOffer) {
                        let r = Reader(offer, at: 1); let count = r.u32() ?? 0
                        if offer.count < 14 || count == 0 { why = "It's no longer on \(pcName)'s Shelf" }
                        else {
                            let total = r.i64()!; _ = r.u8(); let title = cleanName(r.rest().utf8String)
                            if count > Proto.maxFiles || total > Proto.maxTotal { why = "That is too much to take at once" }
                            else {
                                let room = self.inbox.room(total)
                                if !c.sealed(ss, [room ? 1 : 2]) { why = "\(pcName) stopped answering" }
                                else if !room { why = "There isn't room on this iPhone" }
                                else { self.takeBatch(c, ss, peer, pcName, title, count, total, transfer, taken: true); taken = true }
                            }
                        }
                    } else { why = self.stopped(transfer) ? "You stopped it" : "\(pcName) didn't answer" }
                    c.close()
                }
            }
            if !taken { self.finish(transfer); self.onEvent(.failed(transfer: transfer, peer: peer, name: pcName, title: name, detail: why.isEmpty ? "It didn't come" : why, outgoing: false)) }
        }
        return transfer
    }

    // ---- the remote, on connections kept open (revision 4) ----
    /// How a paired device would be reached now: 2 directly, 1 through the relay, 0 not.
    private func pathNow(_ peer: String) -> Int { relay?.path(peer).kind ?? 0 }
    /// Runs [ask] on a connection to [peer] in [mode] kept open for more: reached anew when there's none, it's idle long
    /// enough for the other side to have closed it (45 s), or a faster path has appeared; a kept one that fails is replaced
    /// by a fresh one once. Requests to one device and mode go one at a time.
    private func onKept<T>(_ peer: String, _ mode: Int, _ ask: (Conn, Session) -> T?) -> (T?, String) {
        let k = "\(peer)/\(mode)"
        let gate: NSLock = locked { if let l = keptLocks[k] { return l }; let l = NSLock(); keptLocks[k] = l; return l }
        gate.lock(); defer { gate.unlock() }
        for _ in 0...1 {
            let t = now(); let best = pathNow(peer)
            var e = locked { kept[k] }
            if let old = e, t - old.used > 45_000 || best > old.path || old.c.closed || old.c.ended { old.c.close(); locked { _ = kept.removeValue(forKey: k) }; e = nil }
            let fresh = e == nil
            if e == nil {
                let (c, ss, why) = reach(peer, mode, nil); guard let c else { return (nil, why) }
                let n = Kept(c, ss, best, t); locked { kept[k] = n }; e = n
            }
            let entry = e!; entry.c.timeout = 10
            if let result = ask(entry.c, entry.ss) { entry.used = now(); return (result, "") }
            entry.c.close(); locked { if kept[k] === entry { kept.removeValue(forKey: k) } }
            if fresh { return (nil, "") }
        }
        return (nil, "")
    }
    private func dropKept() { let all: [Kept] = locked { let a = Array(kept.values); kept.removeAll(); return a }; for e in all { e.c.close() } }

    /// One remote command to a paired PC: its answer, or nil when it couldn't be asked (with why in lastRemoteError).
    public func remote(_ peer: String, _ command: Int, _ payload: [UInt8] = []) -> RemoteReply? {
        let (t, why0) = target(peer); guard let t else { lastRemoteError = why0; return nil }
        if t.revision < 2 { lastRemoteError = "Update Arnav Island on \(t.name) to control it from your iPhone"; return nil }
        let request = Wire().u8(Proto.frameRequest).u8(command).raw(payload).build()
        if t.revision >= 4 {
            let (reply, why) = onKept(peer, Proto.modeRemote) { c, ss -> RemoteReply? in
                guard c.sealed(ss, request), let f = c.opened(ss) else { return nil }
                let r = Reader(f); guard r.u8() == Proto.frameReply, let status = r.u8() else { return nil }
                return RemoteReply(status: status, payload: r.rest())
            }
            if reply == nil { lastRemoteError = why.isEmpty ? "\(t.name) didn't answer" : why }
            return reply
        }
        let (c, ss, why) = reach(peer, Proto.modeRemote, nil); guard let c else { lastRemoteError = why; return nil }
        defer { c.close() }
        c.timeout = 10
        guard c.sealed(ss, request), let f = c.opened(ss) else { lastRemoteError = "\(t.name) didn't answer"; return nil }
        let r = Reader(f); guard r.u8() == Proto.frameReply, let status = r.u8() else { return nil }
        return RemoteReply(status: status, payload: r.rest())
    }
    private func ask(_ peer: String, _ command: Int, _ payload: [UInt8] = []) -> [UInt8]? { remote(peer, command, payload).flatMap { $0.ok ? $0.payload : nil } }
    /// The PC's status for the remote. [haveCover]: the hash of the cover this device shows (so it isn't sent again).
    public func status(_ peer: String, haveCover: [UInt8]?, previous: PcStatus?) -> PcStatus? {
        guard let reply = remote(peer, Proto.cmdStatus, haveCover?.count == 32 ? haveCover! : [UInt8](repeating: 0, count: 32)) else { return nil }
        if !reply.ok { lastRemoteError = reply.status == Proto.notAllowed ? "Remote control is off on that PC" : "That PC couldn't answer"; return nil }
        return IslandWire.status(reply.payload, previous: previous)
    }
    public func lyrics(_ peer: String) -> Lyrics? { ask(peer, Proto.cmdLyrics).flatMap(IslandWire.lyrics) }
    public func stats(_ peer: String) -> PcStats? { ask(peer, Proto.cmdStats).flatMap(IslandWire.stats) }
    public func battery(_ peer: String) -> PcBattery? { ask(peer, Proto.cmdBattery).flatMap(IslandWire.battery) }
    public func islandSettings(_ peer: String) -> IslandSettings? { ask(peer, Proto.cmdSettings, [0]).flatMap(IslandWire.settings) }
    /// Changes one of the island's settings; the value it has now (the island may keep it within its range), or nil.
    public func setIslandSetting(_ peer: String, _ key: String, _ value: Int) -> Int? { ask(peer, Proto.cmdSettings, Wire().u8(1).string(key).u32(value).build()).flatMap(IslandWire.value) }
    public func islandSettingAction(_ peer: String, _ action: Int) -> Bool { ask(peer, Proto.cmdSettings, Wire().u8(2).u8(action).build()) != nil }
    public func controls(_ peer: String) -> PcControls? { ask(peer, Proto.cmdControls, [0]).flatMap(IslandWire.controls) }
    public func setControl(_ peer: String, _ control: Int, _ value: Int) -> PcControls? { ask(peer, Proto.cmdControls, Wire().u8(1).u8(control).u32(value).build()).flatMap(IslandWire.controls) }
    public func queryCommands(_ peer: String, _ text: String) -> CommandResults? { ask(peer, Proto.cmdCommand, Wire().u8(0).string(text).build()).flatMap(IslandWire.commands) }
    public func runCommand(_ peer: String, _ text: String, _ index: Int, _ title: String, confirmed: Bool) -> CommandOutcome? {
        ask(peer, Proto.cmdCommand, Wire().u8(1).string(text).u8(index).string(title).u8(confirmed ? 1 : 0).build()).flatMap(IslandWire.outcome)
    }
    public func outputs(_ peer: String) -> [AudioOutput]? { ask(peer, Proto.cmdAudio, [0]).flatMap(IslandWire.outputs) }
    /// Makes an output the PC's default: the status (notAllowed when the island's direct output switching is off).
    public func selectOutput(_ peer: String, _ id: String) -> Int { remote(peer, Proto.cmdAudio, Wire().u8(1).string(id).build())?.status ?? Proto.failed }
    public func openIslandPage(_ peer: String, _ page: Int) -> Bool { ask(peer, Proto.cmdIsland, [0, UInt8(page)]) != nil }
    public func closeIsland(_ peer: String) -> Bool { ask(peer, Proto.cmdIsland, [1]) != nil }

    public func notice(_ peer: String, _ frame: [UInt8]) -> Bool {
        let (t, _) = target(peer); guard let t, t.revision >= 2 else { return false }
        if t.revision >= 4 {
            return onKept(peer, Proto.modeNotice) { c, ss -> Bool? in
                guard c.sealed(ss, frame), let a = c.opened(ss), a.first == UInt8(Proto.frameNoticeAck) else { return nil }
                return true
            }.0 == true
        }
        let (c, ss, _) = reach(peer, Proto.modeNotice, nil); guard let c else { return false }
        defer { c.close() }
        guard c.sealed(ss, frame), let a = c.opened(ss) else { return false }
        return a.first == UInt8(Proto.frameNoticeAck)
    }
    /// A PC rang this device (find my phone).
    private func ringed(_ c: Conn, _ ss: Session) {
        guard let f = c.opened(ss), f.first == UInt8(Proto.frameRing) else { return }
        _ = c.sealed(ss, [UInt8(Proto.frameRingAck)])
        onEvent(.ring(peer: ss.peerId.hex, name: nameOf(ss.peerId.hex, ss.peerName)))
        Thread.sleep(forTimeInterval: 0.3)
    }

    // ---- the trackpad and keyboard (revision 3), screens (revision 7) ----
    public func openInput(_ peer: String) -> InputSession? {
        let (t, _) = target(peer); guard let t, t.revision >= 3 else { return nil }
        let (c, ss, _) = reach(peer, Proto.modeInput, nil); guard let c else { return nil }
        c.timeout = 120; return InputSession(c, ss)
    }
    /// Opens a screen with a PC (island 0.24): its answer to [request], and the session; nil when it can't be reached.
    public func openScreen(_ peer: String, request: [UInt8]) -> (ScreenSession, [UInt8])? {
        let (t, _) = target(peer); guard let t, t.revision >= 7 else { return nil }
        let (c, ss, _) = reach(peer, Proto.modeMirror, nil); guard let c else { return nil }
        let s = ScreenSession(c, ss)
        guard s.send(request) else { return nil }
        // Its answer (the PC may take a moment to start its encoder).
        var reply: [UInt8]? = nil; let until = Date().addingTimeInterval(10)
        while reply == nil && s.open && Date() < until { reply = s.receive(timeout: 1) }
        guard let r = reply, r.first == UInt8(Proto.screenReply) else { s.close(); return nil }
        return (s, r)
    }
}

/// A session of input frames to a PC, kept open while the trackpad shows.
public final class InputSession {
    private let c: Conn; private let ss: Session
    public private(set) var open = true
    init(_ c: Conn, _ ss: Session) { self.c = c; self.ss = ss }
    public func send(_ frame: [UInt8]) -> Bool { guard open else { return false }; let ok = c.sealed(ss, frame); if !ok { close() }; return ok }
    public var alive: Bool { open && !c.ended }
    public func close() { open = false; c.close() }
}
/// A screen's connection: sends are sealed in order; one thread receives.
public final class ScreenSession {
    private let c: Conn; private let ss: Session
    public private(set) var open = true
    init(_ c: Conn, _ ss: Session) { self.c = c; self.ss = ss }
    public func send(_ frame: [UInt8]) -> Bool { guard open else { return false }; let ok = c.sealed(ss, frame); if !ok { close() }; return ok }
    /// Waits only for a frame to start; once one has, it's read whole (giving up halfway would lose the stream's place).
    public func receive(timeout: TimeInterval) -> [UInt8]? {
        guard open else { return nil }
        guard let ready = c.pipe.inbound.waitReadable(max(0.001, timeout)) else { return nil }
        if !ready { close(); return nil }
        c.timeout = 20
        guard let f = c.opened(ss) else { close(); return nil }
        return f
    }
    public func close() { open = false; c.close() }
}

/// SHA-256 a piece at a time, for files too large to hold (CryptoKit's own, streamed).
struct Sha256Stream {
    private var h = SHA256()
    mutating func update(_ b: ArraySlice<UInt8>) { h.update(data: b) }
    func finalize() -> [UInt8] { Array(h.finalize()) }
}

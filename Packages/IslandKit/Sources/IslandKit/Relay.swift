import Foundation

/// An island's pairing QR code, read: its code, and the start of that PC's key fingerprint, if given.
public struct PairLink: Equatable { public let code: String; public let key: [UInt8]? }

func spawn(_ name: String, _ body: @escaping () -> Void) { let t = Thread(block: body); t.name = name; t.stackSize = 1 << 20; t.start() }

/// Paired devices on different networks meet through free public MQTT brokers (HiveMQ, EMQX and Eclipse Mosquitto), over
/// TLS, exactly as the Windows island's ShareRelay and the Android app's Relay.kt do. Topics are named from each pair's own
/// secret (SHA-256 of the pair's static ECDH, which only the two devices can compute), and every message is sealed with
/// AES-256-GCM under a key from it. A connection is a tunnel: the protocol runs over it unchanged, its bytes carried in
/// numbered messages with a window of acknowledgements, sent again when a broker drops one.
///
/// Every broker at once, so two devices share one even when one can't reach the others; and a direct path: hellos carry
/// each device's addresses, both send sealed UDP probes to all of them at once (opening each side's NAT for the other), and
/// a probe answered is a path: new tunnels go straight there, paced by the acknowledgements, falling back to a broker if it
/// goes quiet. On the same Wi-Fi that's the LAN, device to device.
final class Relay {
    public struct Presence: Equatable { public var here = false; public var phone = false; public var revision = 0; public var name = "" }
    /// How a paired device is reached: kind 0 not at all, 1 through the brokers, 2 directly; its round trip (ms); brokers it's heard on; IPv6.
    public struct Path: Equatable { public var kind = 0; public var rtt = 0.0; public var brokers = 0; public var v6 = false; public var lan = false }
    public struct RelayPair { public let peer: [UInt8]; public let agreed: [UInt8] }
    public static let defaultBrokers: [(String, UInt16)] = [("broker.hivemq.com", 8883), ("broker.emqx.io", 8883), ("test.mosquitto.org", 8886)]

    static let version = 1
    static let kindHello = 1, kindOpen = 2, kindData = 3, kindAck = 4, kindClose = 5, kindProbe = 7, kindProbeAck = 8
    static let helloReply = 1, helloPhone = 2, helloLeaving = 4, helloDirect = 8
    static let chunkSize = 48 * 1024, window = 64, ackEvery = 24
    static let rtoBase: Int64 = 1_500, rtoMost: Int64 = 8_000, nackEvery: Int64 = 300, resendBatch = 8, dataFlags = 2 + 16 + 8 + 4
    static let direct = 100
    static let datagramMagic: UInt8 = 0xA1, datagramVersion: UInt8 = 1, directChunk = 1100
    static let windowLeast = 16.0, windowMost = 1024.0
    static let probeEvery: Int64 = 200, punchFor: Int64 = 8_000, keepEvery: Int64 = 15_000, directGone: Int64 = 35_000
    static let reprobeEvery: Int64 = 60_000, gatherEvery: Int64 = 45_000, relayProbeEvery: Int64 = 20_000
    static let stunServers = [("stun.l.google.com", UInt16(19302)), ("stun.cloudflare.com", UInt16(3478)), ("stun1.l.google.com", UInt16(19302))]
    static let prefix = "arnavisland/r1/"
    public static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

    // ---- the pieces ----
    final class Route {
        let peer: String; let seal: Seal; let outbox: String; let code: Bool; let host: Bool
        var heard: [Int64]; var helloed: Int64 = 0; var presence = Presence()
        var directOk = false, up = false, theirs: [SocketAddress] = [], at: SocketAddress?
        var rtt = 0.0, relayRtt = 0.0, lastIn: Int64 = 0, punchUntil: Int64 = 0, nextProbe: Int64 = 0, probedAt: Int64 = 0, keptAt: Int64 = 0, relayProbedAt: Int64 = 0
        init(peer: String, seal: Seal, outbox: String, brokers: Int, code: Bool = false, host: Bool = false) {
            self.peer = peer; self.seal = seal; self.outbox = outbox; self.code = code; self.host = host; heard = [Int64](repeating: 0, count: brokers)
        }
        func directFresh(_ now: Int64) -> Bool { up && now - lastIn < 20_000 }
    }
    final class Tunnel: DuplexPipe {
        let conn: UInt64; let outbox: String; let seal: Seal; var broker: Int; let open: [UInt8]?; let route: String
        let inbound = ByteQueue(); let outbound = ByteQueue()
        let cond = NSCondition()
        var cwnd = 64.0, ssthresh = 1e9, rtoFloor = Relay.rtoBase, nackGap = Relay.nackEvery
        var sent: Int64 = 0, acked: Int64 = 0, expected: Int64 = 0, acknowledged: Int64 = 0
        var inEnd = false, dead = false, closeSent = false, heard = false
        var unacked: [Int64: [UInt8]] = [:], early: [Int64: [UInt8]] = [:]
        var rto = Relay.rtoBase, progressAt: Int64 = 0, resendAt: Int64 = 0, resentAt: Int64 = 0, nackedFor: Int64 = -1, nackedAt: Int64 = 0, dupAckAt: Int64 = 0, gapSince: Int64 = 0
        init(conn: UInt64, outbox: String, seal: Seal, broker: Int, open: [UInt8]?, route: String) { self.conn = conn; self.outbox = outbox; self.seal = seal; self.broker = broker; self.open = open; self.route = route }
        func write(_ b: [UInt8]) -> Bool { outbound.write(b) }
        func close() { outbound.close() }
    }
    final class Broker {
        let index: Int; let host: String; let port: UInt16
        var line: TLSLine?; var up = false; var lastIn: Int64 = 0; var lastPing: Int64 = 0
        let writeLock = NSLock()
        init(index: Int, host: String, port: UInt16) { self.index = index; self.host = host; self.port = port }
        func write(_ packet: [UInt8]) -> Bool { writeLock.lock(); defer { writeLock.unlock() }; return line?.write(packet) ?? false }
    }

    private let id: [UInt8]
    private let name: () -> String
    private let phone: Bool
    private let revision: Int
    private let incoming: (Tunnel, String) -> Void
    private let changed: () -> Void
    private let loseEvery: Int
    private let directOn: Bool
    private let directLoopback: Bool
    private let brokers: [Broker]
    private let lock = NSCondition()
    private var routes: [String: Route] = [:]
    private var tunnels: [UInt64: Tunnel] = [:]
    private var ended: [UInt64: Int64] = [:]
    private var lost = 0
    private var udp4: UDPSocket?, udp6: UDPSocket?
    private var mine: [(SocketAddress, Int)] = []
    private var stunSeen: [SocketAddress] = []
    private var stunAsked: [String: Int64] = [:]
    private var gatheredAt: Int64 = 0
    private var asked: [UInt64: (String, Int64)] = [:]
    private var code: String?, codeUntil: Int64 = 0
    private var stopping = false
    private var nextPacket = 1
    private var subacks: [String: Bool] = [:]
    private let sleeper = NSCondition()

    init(id: [UInt8], name: @escaping () -> String, phone: Bool, revision: Int, brokers: [(String, UInt16)] = Relay.defaultBrokers,
                loseEvery: Int = 0, direct: Bool = true, directLoopback: Bool = false,
                incoming: @escaping (Tunnel, String) -> Void, changed: @escaping () -> Void) {
        self.id = id; self.name = name; self.phone = phone; self.revision = revision; self.incoming = incoming; self.changed = changed
        self.loseEvery = loseEvery; self.directOn = direct; self.directLoopback = directLoopback
        self.brokers = brokers.prefix(6).enumerated().map { Broker(index: $0.offset, host: $0.element.0, port: $0.element.1) }
    }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    public var connected: Bool { brokers.contains { $0.up } }
    public var broker: String? { let up = brokers.filter { $0.up }.map { $0.host }; return up.isEmpty ? nil : up.joined(separator: ", ") }
    public var brokersUp: Int { brokers.filter { $0.up }.count }

    public func start() {
        openDirect()
        for b in brokers { spawn("relay-\(b.index)") { [weak self] in self?.run(b) } }
        spawn("relay-tick") { [weak self] in self?.tick() }
        spawn("relay-resend") { [weak self] in self?.resendLoop() }
    }
    public func stop() {
        if connected {
            let pairs = locked { routes.filter { !$0.value.code }.map { $0.key } }
            for p in pairs { hello(p, reply: false, leaving: true, broker: -1) }
            _ = writeTo(-1, [0xE0, 0])
        }
        stopping = true; sleeper.lock(); sleeper.broadcast(); sleeper.unlock()
        for b in brokers { b.line?.close() }
        udp4?.close(); udp6?.close(); dropAll()
    }
    /// The phone changed networks (or came back from the background): every broker is dialled again at once.
    public func kick() {
        if stopping { return }
        for b in brokers { b.line?.close() }
        sleeper.lock(); sleeper.broadcast(); sleeper.unlock()
        locked { stunSeen.removeAll(); for r in routes.values { r.probedAt = 0 } }
        spawn("relay-gather") { [weak self] in self?.gather(askStun: true) }
    }

    // ---- the brokers ----
    private func writeTo(_ broker: Int, _ packet: [UInt8]) -> Bool {
        if broker >= 0 { guard broker < brokers.count else { return false }; let b = brokers[broker]; return b.up && b.write(packet) }
        var any = false; for b in brokers where b.up { if b.write(packet) { any = true } }; return any
    }
    private func run(_ b: Broker) {
        var fails = 0
        while !stopping {
            var worked = false
            let line = TLSLine(host: b.host, port: b.port)
            if line.open(timeout: 12) {
                b.line = line; b.lastIn = now()
                if b.write(Relay.connectPacket("ai" + Crypto.random(10).hex)) { receive(b, line) }
                worked = b.up
            }
            let was = b.up; b.up = false
            line.close(); b.line = nil; brokerDown(b.index)
            if was { changed() }
            if stopping { break }
            fails = worked ? 0 : fails + 1
            // A broker that can't be reached is tried less and less often, at most every minute.
            let wait = worked ? 1.0 : min(60.0, pow(2.0, Double(min(fails, 6))))
            sleeper.lock(); if !stopping { _ = sleeper.wait(until: Date().addingTimeInterval(wait)) }; sleeper.unlock()
        }
    }
    private func receive(_ b: Broker, _ line: TLSLine) {
        while !stopping {
            do {
                // Up: pinged every 30 s, so 100 s of silence means gone; before CONNACK, 15 s.
                let t: TimeInterval = b.up ? 100 : 15
                let head = Int(try line.readByte(timeout: t))
                var n = 0, mult = 1, count = 0
                while true { let d = Int(try line.readByte(timeout: t)); n += (d & 127) * mult; if d & 128 == 0 { break }; mult *= 128; count += 1; if count > 3 { return } }
                let body = try line.read(n, timeout: 30); b.lastIn = now()
                switch head >> 4 {
                case 2: if body.count >= 2 && body[1] == 0 && !b.up { b.up = true; onConnected(b) }
                case 9:
                    if body.count >= 2 { let key = "\(b.index)/\(Int(body[0]) << 8 | Int(body[1]))"; locked { if subacks[key] != nil { subacks[key] = true; lock.broadcast() } } }
                case 3:
                    if body.count < 2 { continue }
                    let tn = Int(body[0]) << 8 | Int(body[1]); if body.count < 2 + tn { continue }
                    var at = 2 + tn; if (head >> 1) & 3 != 0 { at += 2 }; if at > body.count { continue }
                    onPublish(b.index, String(decoding: body[2..<(2 + tn)], as: UTF8.self), Array(body[at...]), nil)
                default: break
                }
            } catch { return }
        }
    }
    /// A broker went: its tunnels end, and what was heard there no longer counts.
    private func brokerDown(_ index: Int) {
        let ending: [Tunnel] = locked {
            let t = now()
            for r in routes.values { r.heard[index] = 0; r.presence.here = hereAnywhere(r, t) }
            for k in subacks.keys where k.hasPrefix("\(index)/") { subacks.removeValue(forKey: k) }
            lock.broadcast()
            return tunnels.values.filter { $0.broker == index }
        }
        for t in ending { t.cond.lock(); t.dead = true; t.closeSent = true; t.cond.broadcast(); t.cond.unlock(); t.outbound.close(); t.inbound.close(); finish(t) }
    }
    /// Present: heard on a broker (that is up) within the last 150 s; each device says hello on each once a minute.
    private func hereAnywhere(_ r: Route, _ t: Int64) -> Bool { brokers.contains { $0.up && r.heard[$0.index] != 0 && t - r.heard[$0.index] <= 150_000 } }
    private func bestBroker(_ r: Route) -> Int { var best = -1, at: Int64 = 0; for b in brokers where b.up && r.heard[b.index] > at { at = r.heard[b.index]; best = b.index }; return best }

    private func tick() {
        let direct = udp4 != nil || udp6 != nil
        if direct { gather(askStun: true) }
        while !stopping {
            sleeper.lock(); if !stopping { _ = sleeper.wait(until: Date().addingTimeInterval(5)) }; sleeper.unlock()
            if stopping { continue }
            if direct && now() - gatheredAt >= Relay.gatherEvery { gather(askStun: true) }
            let t = now()
            for b in brokers where b.up && t - b.lastPing >= 30_000 { b.lastPing = t; _ = b.write([0xC0, 0]) }
            if !connected { continue }
            var gone = false; var hellos: [String] = []; var expired: [String] = []
            locked {
                for (inbox, r) in routes where !r.code {
                    if t - r.helloed >= 60_000 { hellos.append(inbox) }
                    let here = hereAnywhere(r, t); if r.presence.here != here { r.presence.here = here; gone = true }
                }
                if code != nil && t > codeUntil { expired = stopHostingLocked() }
            }
            if !expired.isEmpty { unsubscribe(expired) }
            for h in hellos { hello(h, reply: false, leaving: false, broker: -1) }
            if gone { changed() }
        }
    }
    private func onConnected(_ b: Broker) {
        let (inboxes, pairs) = locked { (Array(routes.keys), routes.filter { !$0.value.code }.map { $0.key }) }
        if !inboxes.isEmpty { _ = subscribe(inboxes, wait: false, only: b.index) }
        for p in pairs { hello(p, reply: true, leaving: false, broker: b.index) }
        changed()
    }
    /// Subscribes on one broker, or on all that are up; waiting (up to 8 s) for them to confirm, true when one did.
    private func subscribe(_ topics: [String], wait: Bool, only: Int = -1) -> Bool {
        var askedKeys: [String] = []
        for b in brokers where b.up && (only < 0 || b.index == only) {
            let pid: Int = locked { let p = nextPacket; nextPacket += 1; if nextPacket > 65535 { nextPacket = 1 }; if wait { subacks["\(b.index)/\(p)"] = false }; return p }
            let body = Wire().u8(pid >> 8).u8(pid & 255); for t in topics { body.raw(Relay.mqttString(t)).u8(0) }
            if b.write(Relay.packet(0x82, body.build())) { askedKeys.append("\(b.index)/\(pid)") } else { _ = locked { subacks.removeValue(forKey: "\(b.index)/\(pid)") } }
        }
        if !wait { return !askedKeys.isEmpty }
        lock.lock(); defer { lock.unlock() }
        let until = Date().addingTimeInterval(8)
        while askedKeys.contains(where: { subacks[$0] == false }) { if !lock.wait(until: until) { break } }
        return askedKeys.map { subacks.removeValue(forKey: $0) }.contains { $0 == true }
    }
    private func unsubscribe(_ topics: [String]) {
        for b in brokers where b.up {
            let pid: Int = locked { let p = nextPacket; nextPacket += 1; if nextPacket > 65535 { nextPacket = 1 }; return p }
            let body = Wire().u8(pid >> 8).u8(pid & 255); for t in topics { body.raw(Relay.mqttString(t)) }
            _ = b.write(Relay.packet(0xA2, body.build()))
        }
    }

    // ---- messages ----
    private func envelope(_ kind: Int) -> Wire { Wire().u8(Relay.version).u8(kind).raw(id) }
    @discardableResult private func publish(_ topic: String, _ seal: Seal, _ plain: [UInt8], _ broker: Int) -> Bool {
        if broker == Relay.direct {
            guard let at = locked({ routes.values.first { $0.outbox == topic && $0.up }?.at }) else { return false }
            return sendDatagram(at, topic, seal, plain)
        }
        return writeTo(broker, Relay.packet(0x30, Relay.mqttString(topic) + seal.seal(plain, topic: topic)))
    }
    private func hello(_ inbox: String, reply: Bool, leaving: Bool, broker: Int) {
        guard let r = locked({ () -> Route? in let r = routes[inbox]; if broker < 0 { r?.helloed = now() }; return r }) else { return }
        var n = Array(name().utf8); if n.count > 120 { n = Array(n.prefix(120)) }
        let direct = udp4 != nil || udp6 != nil
        let flags = (reply ? Relay.helloReply : 0) | (phone ? Relay.helloPhone : 0) | (leaving ? Relay.helloLeaving : 0) | (direct ? Relay.helloDirect : 0)
        let b = envelope(Relay.kindHello).u8(flags).u8(revision).u8(n.count).raw(n)
        // This device's addresses, for a direct path (older devices read no further than the name).
        if direct { let list = locked { Array(mine.prefix(12)) }; b.u8(list.count); for (a, kind) in list { Relay.putCandidate(b, a, kind) } }
        publish(r.outbox, r.seal, b.build(), broker)
    }
    /// A tunnel's messages count only on its own broker (the first to carry one from the other side, when it had none),
    /// except that one on the direct path follows the other side back to a broker.
    private func tunnelFor(_ conn: UInt64, _ from: Int) -> Tunnel? {
        locked {
            guard let t = tunnels[conn] else { return nil }
            if t.broker < 0 { t.broker = from } else if t.broker == Relay.direct && from != Relay.direct { t.broker = from }
            return t.broker == from ? t : nil
        }
    }
    private func onPublish(_ from: Int, _ topic: String, _ payload: [UInt8], _ source: SocketAddress?) {
        guard let r = locked({ routes[topic] }), let plain = r.seal.open(payload, topic: topic) else { return }
        guard plain.count >= 18, Int(plain[0]) == Relay.version else { return }
        let sender = Array(plain[2..<18]); if sameBytes(sender, id) { return }; if !r.code && sender.hex != r.peer { return }
        let p = Array(plain[18...]); let rd = Reader(p)
        if from == Relay.direct, let s = source { locked { if r.up && r.at == s { r.lastIn = now() } } }
        switch Int(plain[1]) {
        case Relay.kindHello:
            if r.code || p.count < 3 || from == Relay.direct { return }
            let flags = Int(p[0]); let size = min(Int(p[2]), p.count - 3)
            let offered = flags & Relay.helloDirect != 0 ? Relay.readCandidates(p, 3 + size) : []
            let changedNow: Bool = locked {
                let t = now()
                // A goodbye is said on every broker: the device has gone from all of them.
                if flags & Relay.helloLeaving != 0 { for i in r.heard.indices { r.heard[i] = 0 } } else { r.heard[from] = t }
                let presence = Presence(here: hereAnywhere(r, t), phone: flags & Relay.helloPhone != 0, revision: Int(p[1]), name: String(decoding: p[3..<(3 + size)], as: UTF8.self))
                // Its addresses: new ones (or none tried lately) are punched at once, unless a path is up.
                if !offered.isEmpty && flags & Relay.helloLeaving == 0 {
                    r.directOk = true; var fresh = false
                    for e in offered where !r.theirs.contains(e) { fresh = true; if r.theirs.count < 16 { r.theirs.append(e) } }
                    if !r.up && (fresh || t - r.probedAt > 10_000) && t >= r.punchUntil { r.punchUntil = t + Relay.punchFor; r.nextProbe = t }
                }
                let was = r.presence; r.presence = presence; return was != presence
            }
            // Answered on the broker it came by, so the other device learns this one is there too.
            if flags & Relay.helloReply != 0 { hello(topic, reply: false, leaving: false, broker: from) }
            if changedNow { changed() }
        case Relay.kindOpen:
            guard let conn = rd.u64() else { return }
            if locked({ tunnels[conn] != nil || ended[conn] != nil }) { return }
            guard let t = startTunnel(conn, r.outbox, r.seal, from, nil, topic) else { return }
            let peer = r.code ? "" : r.peer
            spawn("relay-in") { [weak self] in self?.incoming(t, peer) }
        case Relay.kindData:
            if p.count < 13 { return }
            let conn = rd.u64()!; let seq = Int64(rd.u32()!); let flags = rd.u8()!
            guard let t = tunnelFor(conn, from) else { return }
            var reply: Int64 = -1
            t.cond.lock()
            let tm = now(); t.heard = true
            if seq < t.expected {
                // Had already (its acknowledgement was lost): said again, so the sender stops sending it.
                if tm - t.dupAckAt >= t.nackGap { t.dupAckAt = tm; reply = t.expected }
            } else if seq > t.expected {
                // Something before it was lost: this one is kept, and the sender told what's missing.
                if seq - t.expected < (t.broker == Relay.direct ? Int64(2 * Relay.windowMost) : Int64(2 * Relay.window)) { t.early[seq] = Array(p[13...]) }
                if t.gapSince == 0 { t.gapSince = tm }
                if t.nackedFor != t.expected || tm - t.nackedAt >= t.nackGap { t.nackedFor = t.expected; t.nackedAt = tm; reply = t.expected }
            } else {
                t.inbound.write(Array(p[13...])); t.expected += 1
                var filled = false
                while let next = t.early.removeValue(forKey: t.expected) { t.inbound.write(next); t.expected += 1; filled = true }
                t.gapSince = t.early.isEmpty ? 0 : tm
                if flags & 1 != 0 || filled || t.expected - t.acknowledged >= Int64(Relay.ackEvery) { reply = t.expected }
            }
            if reply >= 0 { t.acknowledged = max(t.acknowledged, reply) }
            t.cond.broadcast(); t.cond.unlock()
            if reply >= 0 { publish(t.outbox, t.seal, envelope(Relay.kindAck).u64(conn).u32(Int(reply)).build(), t.broker) }
        case Relay.kindAck:
            guard let conn = rd.u64(), let nextI = rd.u32(), let t = tunnelFor(conn, from) else { return }
            let next = Int64(nextI); var again: [[UInt8]] = []
            t.cond.lock()
            let tm = now(); t.heard = true
            if next > t.acked && next <= t.sent {
                let k = Double(next - t.acked); for s in t.acked..<next { t.unacked.removeValue(forKey: s) }
                t.acked = next; t.progressAt = tm; t.rto = t.rtoFloor; t.resendAt = tm + t.rtoFloor
                // The direct path's window grows with what arrives: doubling each round trip, then a message a round trip.
                if t.broker == Relay.direct { t.cwnd = min(Relay.windowMost, t.cwnd < t.ssthresh ? t.cwnd + k : t.cwnd + k / t.cwnd) }
            } else if next == t.acked && next < t.sent && tm - t.resentAt >= t.nackGap {
                // The other side is missing this one: sent again at once, with a few after it (a loss: the window halves).
                t.resentAt = tm; again = resendable(t)
                if t.broker == Relay.direct { t.ssthresh = max(Relay.windowLeast, t.cwnd / 2); t.cwnd = t.ssthresh }
            }
            t.cond.broadcast(); t.cond.unlock()
            for m in again { publish(t.outbox, t.seal, m, t.broker) }
        case Relay.kindClose:
            guard let conn = rd.u64(), let t = tunnelFor(conn, from) else { return }
            t.cond.lock(); t.inEnd = true; t.closeSent = true; t.cond.broadcast(); t.cond.unlock(); t.inbound.close()
        case Relay.kindProbe:
            // A probe is answered the way it came: by the direct path, to the address it came from, or on its broker.
            if r.code || p.count < 16 { return }
            let answer = envelope(Relay.kindProbeAck).raw(Array(p[0..<16])).build()
            if from == Relay.direct, let s = source {
                sendDatagram(s, r.outbox, r.seal, answer)
                locked {
                    r.directOk = true
                    if !r.theirs.contains(s) {
                        if r.theirs.count >= 16 { r.theirs.removeFirst() }; r.theirs.append(s)
                        if !r.up { let t = now(); r.punchUntil = max(r.punchUntil, t + 3_000); r.nextProbe = t }
                    }
                }
            } else { publish(r.outbox, r.seal, answer, from) }
        case Relay.kindProbeAck:
            if r.code || p.count < 16 { return }
            guard let nonce = rd.u64(), let sentAt = rd.u64() else { return }
            let rtt = Double(now() - Int64(bitPattern: sentAt)); if rtt < 0 || rtt > 30_000 { return }
            var changedNow = false
            lock.lock()
            let tm = now()
            if from == Relay.direct {
                if let s = source, let a = asked[nonce], a.0 == topic {
                    asked.removeValue(forKey: nonce)
                    let same = r.up && r.at == s; let before = r.rtt
                    // The first path answered, the same one again, or one clearly faster: kept.
                    if !r.up || same || rtt < r.rtt * 0.7 {
                        r.at = s; r.rtt = same ? r.rtt * 0.8 + rtt * 0.2 : rtt; r.up = true; r.lastIn = tm; r.punchUntil = tm; r.keptAt = tm
                        changedNow = !same || abs(r.rtt - before) > before * 0.15
                    }
                }
            } else { let before = r.relayRtt; r.relayRtt = before > 0 ? before * 0.7 + rtt * 0.3 : rtt; changedNow = before <= 0 || abs(r.relayRtt - before) > before * 0.15 }
            lock.unlock()
            if changedNow { changed() }
        default: break
        }
    }

    // ---- the direct path ----
    /// A message by the direct path: sealed exactly as on a broker, behind the recipient's inbox id.
    @discardableResult private func sendDatagram(_ to: SocketAddress, _ topic: String, _ seal: Seal, _ plain: [UInt8]) -> Bool {
        guard let s = to.v6 ? udp6 : udp4, topic.hasPrefix(Relay.prefix), let inbox = String(topic.dropFirst(Relay.prefix.count)).unhex, inbox.count == 20 else { return false }
        return s.send([Relay.datagramMagic, Relay.datagramVersion] + inbox + seal.seal(plain, topic: topic), to: to)
    }
    private func openDirect() {
        guard directOn else { return }
        udp4 = UDPSocket(v6: false, loopback: directLoopback); udp6 = UDPSocket(v6: true, loopback: directLoopback)
        for s in [udp4, udp6].compactMap({ $0 }) { spawn("relay-udp") { [weak self] in self?.receiveDirect(s) } }
    }
    private func receiveDirect(_ s: UDPSocket) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while !stopping && s.isOpen {
            guard let (n, source) = s.receive(&buffer) else { continue }
            // A STUN answer (a binding success, with the magic cookie).
            if n >= 20 && buffer[0] == 0x01 && buffer[1] == 0x01 && buffer[4] == 0x21 && buffer[5] == 0x12 && buffer[6] == 0xA4 && buffer[7] == 0x42 { onStun(Array(buffer[0..<n])); continue }
            if n > 22 + 28 && buffer[0] == Relay.datagramMagic && buffer[1] == Relay.datagramVersion {
                onPublish(Relay.direct, Relay.prefix + Array(buffer[2..<22]).hex, Array(buffer[22..<n]), source)
            }
        }
    }
    /// This device's candidates: its global IPv6 and IPv4 addresses (a LAN address is how two devices behind one router
    /// meet) and what STUN saw. New ones go out at once in a hello to every paired device.
    private func gather(askStun: Bool) {
        var found: [(SocketAddress, Int)] = []
        let p4 = udp4?.port ?? 0, p6 = udp6?.port ?? 0
        func add(_ ip: [UInt8], _ kind: Int) {
            let port = ip.count == 16 ? p6 : p4; if port == 0 || found.count >= 12 { return }
            let e = SocketAddress(ip: ip, port: port); if !found.contains(where: { $0.0 == e }) { found.append((e, kind)) }
        }
        if directLoopback { if udp4 != nil { add([127, 0, 0, 1], 0) }; if udp6 != nil { add([UInt8](repeating: 0, count: 15) + [1], 0) } }
        else { for ip in NetInfo.interfaceAddresses() { add(ip, 0) } }
        for e in locked({ stunSeen }) where found.count < 12 && !found.contains(where: { $0.0 == e }) { found.append((e, 1)) }
        let changedNow: Bool = locked { let c = found.map { $0.0 } != mine.map { $0.0 }; if c { mine = found }; gatheredAt = now(); return c }
        if askStun && !directLoopback { stun() }
        if changedNow { helloAll() }
    }
    private func helloAll() { if !connected { return }; for p in locked({ routes.filter { !$0.value.code }.map { $0.key } }) { hello(p, reply: false, leaving: false, broker: -1) } }
    /// STUN binding requests (RFC 5389) from both sockets: the answers say where this device's datagrams appear to come from.
    private func stun() {
        for (host, port) in Relay.stunServers {
            let all = NetInfo.resolve(host)
            for six in [false, true] {
                guard let ip = all.first(where: { ($0.count == 16) == six }), let s = six ? udp6 : udp4 else { continue }
                let tid = Crypto.random(12); locked { stunAsked[tid.hex] = now() }
                s.send([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42] + tid, to: SocketAddress(ip: ip, port: port))
            }
        }
    }
    private func onStun(_ d: [UInt8]) {
        guard locked({ stunAsked.removeValue(forKey: Array(d[8..<20]).hex) }) != nil else { return }
        var at = 20
        while at + 4 <= d.count {
            let type = Int(d[at]) << 8 | Int(d[at + 1]), len = Int(d[at + 2]) << 8 | Int(d[at + 3])
            if at + 4 + len > d.count { break }
            if type == 0x0020 && len >= 8 {
                let port = UInt16((Int(d[at + 6]) << 8 | Int(d[at + 7])) ^ 0x2112)
                let key: [UInt8] = [0x21, 0x12, 0xA4, 0x42] + Array(d[8..<20])
                let size = d[at + 5] == 1 ? 4 : d[at + 5] == 2 ? 16 : 0; if size == 0 || len < 4 + size { break }
                let ip = (0..<size).map { d[at + 8 + $0] ^ key[$0] }
                let e = SocketAddress(ip: ip, port: port)
                let fresh: Bool = locked { if stunSeen.contains(e) { return false }; if stunSeen.count >= 4 { stunSeen.removeFirst() }; stunSeen.append(e); return true }
                if fresh { gather(askStun: false) }
                break
            }
            at += 4 + len + ((4 - len % 4) % 4)
        }
    }
    /// Five times a second (with the resends): probes while punching, a path kept alive, a quiet one dropped (its tunnels go
    /// back to a broker), no path tried again now and then, and the relay's round trip measured.
    private func directTick() {
        if udp4 == nil && udp6 == nil { return }
        struct Send { let to: SocketAddress?; let topic: String; let seal: Seal; let plain: [UInt8]; let broker: Int }
        var out: [Send] = []; var fell: [String] = []; var changedNow = false
        locked {
            let t = now()
            asked = asked.filter { t - $0.value.1 <= 15_000 }; stunAsked = stunAsked.filter { t - $0.value <= 15_000 }
            func probe(_ inbox: String) -> [UInt8] { let nonce = Reader(Crypto.random(8)).u64()!; asked[nonce] = (inbox, t); return envelope(Relay.kindProbe).u64(nonce).i64(t).build() }
            for (inbox, r) in routes where !r.code {
                if r.up && t - r.lastIn > Relay.directGone { r.up = false; changedNow = true; fell.append(inbox); r.punchUntil = t + Relay.punchFor; r.nextProbe = t }
                let present = r.presence.here || r.up
                if r.directOk && !r.up && present && !r.theirs.isEmpty && t >= r.punchUntil && t - r.probedAt > Relay.reprobeEvery { r.punchUntil = t + Relay.punchFor; r.nextProbe = t }
                if !r.up && t < r.punchUntil && t >= r.nextProbe { r.nextProbe = t + Relay.probeEvery; r.probedAt = t; for a in r.theirs { out.append(Send(to: a, topic: r.outbox, seal: r.seal, plain: probe(inbox), broker: Relay.direct)) } }
                else if r.up && t - r.keptAt >= Relay.keepEvery, let at = r.at { r.keptAt = t; out.append(Send(to: at, topic: r.outbox, seal: r.seal, plain: probe(inbox), broker: Relay.direct)) }
                if !r.up && r.presence.here && t - r.relayProbedAt >= Relay.relayProbeEvery {
                    let b = bestBroker(r); if b >= 0 { r.relayProbedAt = t; out.append(Send(to: nil, topic: r.outbox, seal: r.seal, plain: envelope(Relay.kindProbe).raw(Crypto.random(8)).i64(t).build(), broker: b)) }
                }
            }
        }
        for s in out { if s.broker == Relay.direct { if let to = s.to { sendDatagram(to, s.topic, s.seal, s.plain) } } else { publish(s.topic, s.seal, s.plain, s.broker) } }
        for f in fell { fallBack(f) }
        if changedNow { changed() }
    }
    /// A direct path gone quiet: its tunnels carry on through the broker the other device was heard on most lately.
    private func fallBack(_ inbox: String) {
        let ending: [Tunnel] = locked {
            let b = routes[inbox].map { bestBroker($0) } ?? -1; var e: [Tunnel] = []
            for t in tunnels.values where t.route == inbox && t.broker == Relay.direct { if b >= 0 { t.broker = b } else { e.append(t) } }
            return e
        }
        for t in ending { kill(t) }
    }

    // ---- tunnels ----
    private func startTunnel(_ conn: UInt64, _ outbox: String, _ seal: Seal, _ broker: Int, _ open: [UInt8]?, _ route: String) -> Tunnel? {
        if broker != Relay.direct && !connected { return nil }
        let t = Tunnel(conn: conn, outbox: outbox, seal: seal, broker: broker, open: open, route: route)
        // On the direct path, its waits follow the path's round trip.
        if broker == Relay.direct {
            let rtt = locked { routes[route]?.rtt } ?? 100
            t.rtoFloor = Int64(min(2_000, max(150, rtt * 3))); t.nackGap = Int64(min(300, max(40, rtt))); t.rto = t.rtoFloor
        }
        locked { tunnels[conn] = t }
        spawn("relay-out") { [weak self] in self?.pumpOut(t) }
        return t
    }
    private func room(_ t: Tunnel) -> Int64 { t.broker == Relay.direct ? Int64(min(Relay.windowMost, max(Relay.windowLeast, t.cwnd))) : Int64(Relay.window) }
    private func pumpOut(_ t: Tunnel) {
        var eof = false
        while true {
            guard let data = t.outbound.read(max: t.broker == Relay.direct ? Relay.directChunk : Relay.chunkSize, timeout: nil), !data.isEmpty else { eof = true; break }
            // The end of what the protocol wrote for now: the other side is asked to say it has it all.
            let last = t.outbound.available == 0
            var seq: Int64 = -1, ackNow = false
            t.cond.lock()
            let until = Date().addingTimeInterval(60)
            while !t.dead && t.sent - t.acked >= room(t) { if !t.cond.wait(until: until) { break } }
            if !t.dead && t.sent - t.acked < room(t) {
                seq = t.sent; t.sent += 1
                ackNow = last || (t.broker == Relay.direct ? seq % 16 == 15 : t.sent - t.acked >= Int64(Relay.ackEvery))
            }
            t.cond.unlock()
            if seq < 0 { break }
            let b = envelope(Relay.kindData).u64(t.conn).u32(Int(seq)).u8(ackNow ? 1 : 0).raw(data).build()
            t.cond.lock(); let tm = now(); if t.unacked.isEmpty { t.progressAt = tm; t.resendAt = tm + t.rto }; t.unacked[seq] = b; t.cond.unlock()
            if loseEvery > 0 { let skip: Bool = locked { lost += 1; return lost % loseEvery == 0 }; if skip { continue } }
            if !publish(t.outbox, t.seal, b, t.broker) { break }
        }
        // Everything written arrives before the end is said (what seems lost is sent again meanwhile), unless the other side ended first.
        if eof {
            t.cond.lock()
            let until = Date().addingTimeInterval(20)
            while !t.dead && !t.inEnd && t.acked < t.sent { if !t.cond.wait(until: until) { break } }
            t.cond.unlock()
        }
        kill(t)
    }
    /// With t.cond held: the first few unacknowledged messages, the last asking to be acknowledged.
    private func resendable(_ t: Tunnel) -> [[UInt8]] {
        var out = t.unacked.keys.sorted().prefix(Relay.resendBatch).compactMap { t.unacked[$0] }
        if var last = out.popLast() { if last.count > Relay.dataFlags { last[Relay.dataFlags] |= 1 }; out.append(last) }
        return out
    }
    /// Five times a second: what wasn't acknowledged in time is sent again (with its OPEN while nothing was heard back), the
    /// wait doubling up to 8 s; a tunnel that got nowhere for 45 s (or kept a gap 30 s) ends.
    private func resendLoop() {
        while !stopping {
            Thread.sleep(forTimeInterval: 0.2)
            directTick()
            let tm = now()
            let all: [Tunnel] = locked { ended = ended.filter { tm - $0.value <= 120_000 }; return Array(tunnels.values) }
            for t in all {
                var again: [[UInt8]] = []; var open: [UInt8]? = nil; var end = false
                t.cond.lock()
                if !t.dead {
                    if !t.unacked.isEmpty && tm >= t.resendAt {
                        if tm - t.progressAt > 45_000 { end = true }
                        else {
                            again = resendable(t); if !t.heard { open = t.open }; t.resentAt = tm; let directNow = t.broker == Relay.direct
                            t.rto = min(t.rto * 2, directNow ? 4_000 : Relay.rtoMost); t.resendAt = tm + t.rto
                            // Nothing acknowledged in a while: the direct path's window starts small again.
                            if directNow { t.ssthresh = max(Relay.windowLeast, t.cwnd / 2); t.cwnd = Relay.windowLeast }
                        }
                    }
                    if t.gapSince > 0 && tm - t.gapSince > 30_000 { end = true }
                }
                t.cond.unlock()
                if end { kill(t); continue }
                if let o = open { publish(t.outbox, t.seal, o, t.broker) }
                for m in again { publish(t.outbox, t.seal, m, t.broker) }
            }
        }
    }
    private func kill(_ t: Tunnel) {
        t.cond.lock()
        if t.dead { t.cond.unlock(); return }
        t.dead = true; t.cond.broadcast(); let alreadyClosed = t.closeSent; t.closeSent = true
        t.cond.unlock()
        t.outbound.close(); t.inbound.close()
        if !alreadyClosed { publish(t.outbox, t.seal, envelope(Relay.kindClose).u64(t.conn).build(), t.broker) }
        finish(t)
    }
    private func finish(_ t: Tunnel) { locked { if tunnels[t.conn] === t { tunnels.removeValue(forKey: t.conn); ended[t.conn] = now() } } }
    private func dropAll() {
        let all: [Tunnel] = locked { for r in routes.values { for i in r.heard.indices { r.heard[i] = 0 }; r.presence.here = false }; return Array(tunnels.values) }
        for t in all { t.cond.lock(); t.dead = true; t.closeSent = true; t.cond.broadcast(); t.cond.unlock(); t.outbound.close(); t.inbound.close(); finish(t) }
    }
    private func openTunnel(_ outbox: String, _ seal: Seal, _ broker: Int, _ route: String) -> Tunnel? {
        let conn = Reader(Crypto.random(8)).u64()!; let open = envelope(Relay.kindOpen).u64(conn).build()
        guard let t = startTunnel(conn, outbox, seal, broker, open, route) else { return nil }
        if !publish(outbox, seal, open, broker) { kill(t); return nil }
        return t
    }

    // ---- what the link asks ----
    public func pairs(_ list: [RelayPair]) {
        var added: [String] = []
        let left: [String] = locked {
            var next: [String: Route] = [:]
            for p in list where p.peer.count == 16 && p.agreed.count == 32 {
                let secret = Crypto.sha256("arnav-relay-v1", p.agreed)
                let inbox = Relay.topic(Crypto.sha256("inbox", secret, id)), outbox = Relay.topic(Crypto.sha256("inbox", secret, p.peer))
                if let old = routes[inbox], !old.code { next[inbox] = old; continue }
                next[inbox] = Route(peer: p.peer.hex, seal: Seal(Crypto.sha256("arnav-relay-key", secret)), outbox: outbox, brokers: brokers.count); added.append(inbox)
            }
            for (k, v) in routes where v.code { next[k] = v }
            let gone = routes.keys.filter { next[$0] == nil }
            routes = next
            return gone
        }
        if connected && !left.isEmpty { unsubscribe(left) }
        if connected && !added.isEmpty { _ = subscribe(added, wait: false); for a in added { hello(a, reply: true, leaving: false, broker: -1) } }
    }
    public func presence(_ peer: String) -> Presence {
        locked {
            guard let r = routes.values.first(where: { !$0.code && $0.peer == peer }) else { return Presence() }
            if r.directFresh(now()) { var p = r.presence; p.here = true; return p }
            return r.presence
        }
    }
    /// How a paired device is reached now (for the connection's quality ring).
    public func path(_ peer: String) -> Path {
        locked {
            let t = now(); guard let r = routes.values.first(where: { !$0.code && $0.peer == peer }) else { return Path() }
            let heard = brokers.filter { $0.up && r.heard[$0.index] != 0 && t - r.heard[$0.index] <= 150_000 }.count
            if r.directFresh(t) { return Path(kind: 2, rtt: r.rtt, brokers: heard, v6: r.at?.v6 == true, lan: r.at?.local == true) }
            if r.presence.here && heard > 0 { return Path(kind: 1, rtt: r.relayRtt, brokers: heard) }
            return Path(kind: 0, rtt: 0, brokers: heard)
        }
    }
    /// Straight there when a direct path is up; through the broker it was heard on most lately otherwise.
    func open(_ peer: String) -> (Tunnel?, String) {
        let found: (String, Route, Int)? = locked {
            guard let e = routes.first(where: { !$0.value.code && $0.value.peer == peer }) else { return nil }
            return (e.key, e.value, e.value.directFresh(now()) ? Relay.direct : bestBroker(e.value))
        }
        guard let (inbox, r, broker) = found else { return (nil, "Pair with it first") }
        if broker != Relay.direct && !connected { return (nil, "This iPhone isn't connected to the internet") }
        if (!r.presence.here && broker != Relay.direct) || broker < 0 { return (nil, "\(r.presence.name.isEmpty ? "It" : r.presence.name) isn't online") }
        guard let t = openTunnel(r.outbox, r.seal, broker, inbox) else { return (nil, "The connection through the internet failed") }
        return (t, "")
    }
    /// Offers a pairing code for ten minutes, listened for on every broker; nil when no broker can be reached.
    public func host() -> String? {
        if !connected { return nil }
        let r = Crypto.random(8); let c = String(r.map { Relay.alphabet[Int($0) % 31] })
        let secret = Crypto.sha256("arnav-pair-code-v1", Array(c.utf8))
        let inbox = Relay.topic(Crypto.sha256("host", secret)), outbox = Relay.topic(Crypto.sha256("guest", secret))
        let left: [String] = locked {
            let l = stopHostingLocked()
            routes[inbox] = Route(peer: "", seal: Seal(Crypto.sha256("arnav-pair-code-key", secret)), outbox: outbox, brokers: brokers.count, code: true, host: true)
            code = c; codeUntil = now() + 600_000; return l
        }
        if !left.isEmpty { unsubscribe(left) }
        if !subscribe([inbox], wait: true) { stopHosting(); return nil }
        return String(c.prefix(4)) + "-" + String(c.suffix(4))
    }
    public func stopHosting() { let left = locked { stopHostingLocked() }; if !left.isEmpty { unsubscribe(left) } }
    public var hosting: String? { locked { code.map { String($0.prefix(4)) + "-" + String($0.suffix(4)) } } }
    private func stopHostingLocked() -> [String] { code = nil; let left = routes.filter { $0.value.host }.map { $0.key }; for k in left { routes.removeValue(forKey: k) }; return left }
    /// A tunnel to the device showing this code: opened on every broker, it keeps to whichever the other device answers on.
    func openCode(_ typed: String) -> (Tunnel?, String) {
        guard let c = Relay.code(typed) else { return (nil, "That isn't a pairing code") }
        if !connected { return (nil, "This iPhone isn't connected to the internet") }
        let secret = Crypto.sha256("arnav-pair-code-v1", Array(c.utf8))
        let inbox = Relay.topic(Crypto.sha256("guest", secret)), outbox = Relay.topic(Crypto.sha256("host", secret))
        let seal = Seal(Crypto.sha256("arnav-pair-code-key", secret))
        locked { routes[inbox] = Route(peer: "", seal: seal, outbox: outbox, brokers: brokers.count, code: true) }
        if !subscribe([inbox], wait: true) { return (nil, "The connection through the internet failed") }
        guard let t = openTunnel(outbox, seal, -1, inbox) else { return (nil, "The connection through the internet failed") }
        return (t, "")
    }
    /// Waits (up to [seconds]) for a broker.
    public func waitConnected(_ seconds: TimeInterval) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while !connected && Date() < until && !stopping { Thread.sleep(forTimeInterval: 0.15) }
        return connected
    }

    // ---- helpers ----
    static func topic(_ hash: [UInt8]) -> String { prefix + String(hash.hex.prefix(40)) }
    /// A typed code made canonical ("7k2p mx4q" becomes "7K2PMX4Q"), or nil when it can't be one.
    public static func code(_ typed: String) -> String? {
        var s = ""
        for ch in typed {
            if ch == " " || ch == "-" { continue }
            let up = ch.uppercased(); guard up.count == 1, let c = up.first, alphabet.contains(c) else { return nil }
            s.append(c)
        }
        return s.count == 8 ? s : nil
    }
    /// The pairing link in an island's QR code, "arnavisland://pair/7K2PMX4Q?k=<20 hex digits>": its code and the first ten
    /// bytes of the SHA-256 of that PC's public key (nil when the link gives none, or a malformed one). Nil when it isn't one.
    public static func pairLink(_ text: String) -> PairLink? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^https://[^/]+/(#/)?pair/"#, options: [.regularExpression, .caseInsensitive]) { t = "arnavisland://pair/" + t[r.upperBound...] }
        let prefix = "arnavisland://pair/"
        guard t.lowercased().hasPrefix(prefix) else { return nil }
        let rest = String(t.dropFirst(prefix.count)).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var codePart = String(parts.first ?? ""); while codePart.hasSuffix("/") { codePart.removeLast() }
        guard let code = code(codePart) else { return nil }
        let query = parts.count > 1 ? String(parts[1]) : ""
        let k = query.split(separator: "&").first { $0.lowercased().hasPrefix("k=") }.map { String($0.dropFirst(2)) }
        let key = k.flatMap { $0.count == 20 ? $0.lowercased().unhex : nil }
        return PairLink(code: code, key: key)
    }
    static func mqttString(_ s: String) -> [UInt8] { let b = Array(s.utf8); return [UInt8(b.count >> 8), UInt8(b.count & 255)] + b }
    static func packet(_ head: Int, _ body: [UInt8]) -> [UInt8] {
        var len: [UInt8] = []; var n = body.count
        repeat { var d = n % 128; n /= 128; if n > 0 { d |= 128 }; len.append(UInt8(d)) } while n > 0
        return [UInt8(head)] + len + body
    }
    static func connectPacket(_ client: String) -> [UInt8] { packet(0x10, mqttString("MQTT") + [4, 2, 0, 60] + mqttString(client)) }
    /// Candidates as a hello carries them: family (4 or 6), address, port (big-endian) and kind (0 own, 1 STUN, 2 by hand).
    static func putCandidate(_ b: Wire, _ a: SocketAddress, _ kind: Int) { b.u8(a.v6 ? 6 : 4).raw(a.ip).u8(Int(a.port >> 8)).u8(Int(a.port & 255)).u8(kind) }
    static func readCandidates(_ p: [UInt8], _ from: Int) -> [SocketAddress] {
        if from >= p.count { return [] }
        let count = min(Int(p[from]), 16); var at = from + 1; var out: [SocketAddress] = []
        for _ in 0..<count {
            if at >= p.count { return out }
            let size: Int; switch p[at] { case 6: size = 16; case 4: size = 4; default: return out }
            at += 1; if at + size + 3 > p.count { return out }
            let port = UInt16(p[at + size]) << 8 | UInt16(p[at + size + 1])
            let e = SocketAddress(ip: Array(p[at..<(at + size)]), port: port); at += size + 3
            if port != 0 && !out.contains(e) { out.append(e) }
        }
        return out
    }
}

import Foundation

struct StreamClosed: Error {}
struct StreamTimedOut: Error {}

/// One direction of an in-memory byte stream: written in order, read in order, closed once.
final class ByteQueue {
    private let cond = NSCondition()
    private var chunks: [[UInt8]] = []
    private var head = 0
    private var count = 0
    private var closed = false

    @discardableResult func write(_ b: [UInt8]) -> Bool {
        cond.lock(); defer { cond.unlock() }
        if closed { return false }
        if !b.isEmpty { chunks.append(b); count += b.count; cond.broadcast() }
        return true
    }
    func close() { cond.lock(); closed = true; cond.broadcast(); cond.unlock() }
    var isClosed: Bool { cond.lock(); defer { cond.unlock() }; return closed }
    /// Closed, with nothing left to read.
    var ended: Bool { cond.lock(); defer { cond.unlock() }; return closed && count == 0 }
    var available: Int { cond.lock(); defer { cond.unlock() }; return count }

    /// Waits (up to [timeout], nil: for ever) until there is something to read: true then, false once closed and empty, nil on timeout.
    func waitReadable(_ timeout: TimeInterval?) -> Bool? {
        cond.lock(); defer { cond.unlock() }
        let until = timeout.map { Date().addingTimeInterval($0) }
        while count == 0 && !closed {
            if let u = until { if !cond.wait(until: u) && count == 0 && !closed { return nil } } else { cond.wait() }
        }
        return count > 0
    }
    /// Up to [max] bytes as soon as any are here; [] once closed and empty; nil on timeout.
    func read(max: Int, timeout: TimeInterval?) -> [UInt8]? {
        guard let ok = waitReadable(timeout) else { return nil }
        if !ok { return [] }
        cond.lock(); defer { cond.unlock() }
        return take(Swift.min(max, count))
    }
    /// Exactly [n] bytes, waiting up to [timeout] for them all.
    func readExactly(_ n: Int, timeout: TimeInterval) throws -> [UInt8] {
        cond.lock(); defer { cond.unlock() }
        let until = Date().addingTimeInterval(timeout)
        while count < n {
            if closed { throw StreamClosed() }
            if !cond.wait(until: until) && count < n { if closed { throw StreamClosed() }; throw StreamTimedOut() }
        }
        return take(n)
    }
    private func take(_ n: Int) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(n)
        while out.count < n {
            let c = chunks[0]; let k = Swift.min(c.count - head, n - out.count)
            out.append(contentsOf: c[head..<(head + k)]); head += k
            if head == c.count { chunks.removeFirst(); head = 0 }
        }
        count -= n
        return out
    }
}

/// The two ends a connection needs: bytes in (to read) and a way to send bytes out.
protocol DuplexPipe: AnyObject {
    var inbound: ByteQueue { get }
    func write(_ b: [UInt8]) -> Bool
    func close()
}

/// A connection's frames: a 32-bit little-endian length, then the bytes; sealed in the order they go out.
final class Conn {
    let pipe: DuplexPipe
    /// Seconds to wait for a frame to begin (a socket's read timeout).
    var timeout: TimeInterval = 15
    private let sendLock = NSLock()
    private(set) var closed = false
    init(_ pipe: DuplexPipe) { self.pipe = pipe }

    @discardableResult func send(_ frame: [UInt8]) -> Bool {
        guard frame.count <= Proto.maxFrame, !closed else { return false }
        let n = frame.count
        return pipe.write([UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8((n >> 24) & 255)] + frame)
    }
    func recv() throws -> [UInt8] {
        let h = try pipe.inbound.readExactly(4, timeout: timeout)
        let n = Int(h[0]) | Int(h[1]) << 8 | Int(h[2]) << 16 | Int(h[3]) << 24
        if n > Proto.maxFrame { throw StreamClosed() }
        return try pipe.inbound.readExactly(n, timeout: Swift.max(timeout, 20))
    }
    /// Seals and sends in one step, so a frame's nonce matches its place in the stream.
    func sealed(_ ss: Session, _ plain: [UInt8]) -> Bool {
        sendLock.lock(); defer { sendLock.unlock() }
        guard let ch = ss.channel, !closed else { return false }
        let c = ch.seal(plain); if c.isEmpty { return false }
        return send(c)
    }
    func opened(_ ss: Session) -> [UInt8]? {
        guard let f = try? recv() else { return nil }
        return ss.channel?.open(f)
    }
    /// The other side ended the stream (and everything it sent has been read).
    var ended: Bool { pipe.inbound.ended }
    func close() { if closed { return }; closed = true; pipe.close() }
}

/// What a session knows about the other side once greeted, and its channel.
final class Session {
    var peerId: [UInt8] = [], peerPub: [UInt8] = [], peerName = ""
    var channel: Channel?
    var code = 0
    var rejected = false, outdated = false
}

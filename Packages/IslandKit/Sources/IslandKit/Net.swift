import Darwin
import Foundation
import Network

/// A TLS connection read and written from ordinary threads (as the Android app's SSLSocket is): Network.framework
/// underneath, with the host's certificate checked against its name.
final class TLSLine {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let incoming = ByteQueue()
    private let stateCond = NSCondition()
    private var ready = false, failed = false

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.connectionTimeout = 8; tcp.enableKeepalive = true; tcp.keepaliveIdle = 30
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        params.preferNoProxies = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 443, using: params)
        queue = DispatchQueue(label: "relay-tls-\(host)")
    }
    /// Connects and completes the handshake (up to [timeout] seconds): true when it's up.
    func open(timeout: TimeInterval) -> Bool {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.stateCond.lock()
            switch state {
            case .ready: self.ready = true
            case .failed, .cancelled: self.failed = true; self.incoming.close()
            case .waiting: self.failed = true; self.incoming.close()
            default: break
            }
            self.stateCond.broadcast(); self.stateCond.unlock()
        }
        connection.start(queue: queue)
        stateCond.lock()
        let until = Date().addingTimeInterval(timeout)
        while !ready && !failed { if !stateCond.wait(until: until) { break } }
        let up = ready && !failed
        stateCond.unlock()
        if up { receive() } else { close() }
        return up
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let d = data, !d.isEmpty { self.incoming.write([UInt8](d)) }
            if complete || error != nil { self.incoming.close(); return }
            self.receive()
        }
    }
    func readByte(timeout: TimeInterval) throws -> UInt8 { try incoming.readExactly(1, timeout: timeout)[0] }
    func read(_ n: Int, timeout: TimeInterval) throws -> [UInt8] { n == 0 ? [] : try incoming.readExactly(n, timeout: timeout) }
    /// Queued in order; false once the connection has failed.
    func write(_ b: [UInt8]) -> Bool {
        stateCond.lock(); let bad = failed; stateCond.unlock()
        if bad { return false }
        connection.send(content: Data(b), completion: .contentProcessed { [weak self] error in
            if error != nil, let self { self.stateCond.lock(); self.failed = true; self.stateCond.unlock(); self.incoming.close() }
        })
        return true
    }
    func close() { connection.cancel(); incoming.close() }
}

/// An IPv4 or IPv6 address and port.
public struct SocketAddress: Hashable, CustomStringConvertible {
    public let ip: [UInt8]
    public let port: UInt16
    public var v6: Bool { ip.count == 16 }
    public var description: String {
        if ip.count == 4 { return ip.map(String.init).joined(separator: ".") + ":\(port)" }
        return "[" + stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(ip[$0]) << 8 | Int(ip[$0 + 1])) }.joined(separator: ":") + "]:\(port)"
    }
    /// A private, loopback or link-local address (reached only on this network).
    public var local: Bool {
        if ip.count == 4 { return ip[0] == 10 || ip[0] == 127 || (ip[0] == 172 && ip[1] & 0xF0 == 16) || (ip[0] == 192 && ip[1] == 168) || (ip[0] == 169 && ip[1] == 254) }
        return ip[0] & 0xFE == 0xFC || (ip[0] == 0xFE && ip[1] & 0xC0 == 0x80) || ip == [UInt8](repeating: 0, count: 15) + [1]
    }
    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        if ip.count == 4 {
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &a.sin_addr) { p in for i in 0..<4 { p[i] = ip[i] } }
            return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = port.bigEndian
        withUnsafeMutableBytes(of: &a.sin6_addr) { p in for i in 0..<16 { p[i] = ip[i] } }
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
    }
    static func from(_ sa: UnsafePointer<sockaddr>) -> SocketAddress? {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                var a = p.pointee.sin_addr; let ip = withUnsafeBytes(of: &a) { Array($0) }
                return SocketAddress(ip: ip, port: UInt16(bigEndian: p.pointee.sin_port))
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var a = p.pointee.sin6_addr; let ip = withUnsafeBytes(of: &a) { Array($0) }
                return SocketAddress(ip: ip, port: UInt16(bigEndian: p.pointee.sin6_port))
            }
        default: return nil
        }
    }
}

/// A UDP socket for the relay's direct path, read by its own thread (as the Android app's DatagramSocket is).
final class UDPSocket {
    let fd: Int32
    let v6: Bool
    private(set) var port: UInt16 = 0
    private var open = true

    init?(v6: Bool, loopback: Bool) {
        let s = socket(v6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if s < 0 { return nil }
        fd = s; self.v6 = v6
        var one: Int32 = 1
        if v6 { setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) }
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var size: Int32 = 4 << 20
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size)); setsockopt(s, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let bindTo = SocketAddress(ip: v6 ? (loopback ? [UInt8](repeating: 0, count: 15) + [1] : [UInt8](repeating: 0, count: 16)) : (loopback ? [127, 0, 0, 1] : [0, 0, 0, 0]), port: 0)
        let ok = bindTo.withSockaddr { Darwin.bind(s, $0, $1) } == 0
        if !ok { Darwin.close(s); return nil }
        var ss = sockaddr_storage(); var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        port = withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SocketAddress.from($0)?.port ?? 0 } }
    }
    @discardableResult func send(_ b: [UInt8], to: SocketAddress) -> Bool {
        guard open, to.v6 == v6 else { return false }
        return b.withUnsafeBytes { p in to.withSockaddr { sendto(fd, p.baseAddress, b.count, 0, $0, $1) } } == b.count
    }
    /// A datagram and where it came from; nil on the one-second timeout (or once closed).
    func receive(_ buffer: inout [UInt8]) -> (Int, SocketAddress)? {
        var ss = sockaddr_storage(); var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = buffer.withUnsafeMutableBytes { p in withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, p.baseAddress, p.count, 0, $0, &len) } } }
        guard n > 0, let from = withUnsafePointer(to: &ss, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SocketAddress.from($0) } }) else { return nil }
        return (n, from)
    }
    var isOpen: Bool { open }
    func close() { if open { open = false; Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) } }
}

enum NetInfo {
    /// This device's addresses on its interfaces: global IPv6 (2000::/3) and IPv4 that isn't loopback or link-local.
    static func interfaceAddresses() -> [[UInt8]] {
        var out: [[UInt8]] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let flags = Int32(i.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = i.pointee.ifa_addr, let a = SocketAddress.from(sa) else { continue }
            if a.v6 { if a.ip[0] & 0xE0 == 0x20 { out.append(a.ip) } }
            else if a.ip[0] != 127 && !(a.ip[0] == 169 && a.ip[1] == 254) && a.ip != [0, 0, 0, 0] { out.append(a.ip) }
        }
        var seen = Set<[UInt8]>(); return out.filter { seen.insert($0).inserted }
    }
    /// A host's addresses (IPv4 first).
    static func resolve(_ host: String) -> [[UInt8]] {
        var hints = addrinfo(); hints.ai_socktype = SOCK_DGRAM; hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [[UInt8]] = []; var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p { if let sa = a.pointee.ai_addr, let s = SocketAddress.from(sa) { out.append(s.ip) }; p = a.pointee.ai_next }
        return out.sorted { $0.count < $1.count }
    }
}

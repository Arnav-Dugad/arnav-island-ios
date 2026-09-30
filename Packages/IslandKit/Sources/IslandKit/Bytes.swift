import Foundation

/// A little-endian byte builder, as the island's protocol has it (ShareService.cpp, the Android app's Wire.kt).
public final class Wire {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    @discardableResult public func u8(_ v: Int) -> Wire { bytes.append(UInt8(truncatingIfNeeded: v)); return self }
    @discardableResult public func u16(_ v: Int) -> Wire { u8(v); u8(v >> 8); return self }
    @discardableResult public func u32(_ v: Int) -> Wire { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }; return self }
    @discardableResult public func u64(_ v: UInt64) -> Wire { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(8 * i))) }; return self }
    @discardableResult public func i64(_ v: Int64) -> Wire { u64(UInt64(bitPattern: v)) }
    @discardableResult public func f64(_ v: Double) -> Wire { u64(v.bitPattern) }
    @discardableResult public func f32(_ v: Float) -> Wire { u32(Int(v.bitPattern)) }
    @discardableResult public func raw(_ b: [UInt8]) -> Wire { bytes.append(contentsOf: b); return self }
    @discardableResult public func raw(_ d: Data) -> Wire { bytes.append(contentsOf: d); return self }
    @discardableResult public func text(_ s: String) -> Wire { raw(Array(s.utf8)) }
    /// A UTF-8 string with a 32-bit length first.
    @discardableResult public func string(_ s: String) -> Wire { let b = Array(s.utf8); u32(b.count); return raw(b) }
    @discardableResult public func blob(_ b: [UInt8]) -> Wire { u32(b.count); return raw(b) }
    public func build() -> [UInt8] { bytes }
}

/// Reads a little-endian frame; every read fails (nil) rather than overrunning.
public final class Reader {
    public let b: [UInt8]
    public var at: Int
    public init(_ b: [UInt8], at: Int = 0) { self.b = b; self.at = at }
    public var left: Int { b.count - at }
    public func u8() -> Int? { guard left >= 1 else { return nil }; defer { at += 1 }; return Int(b[at]) }
    public func i8() -> Int? { u8().map { Int(Int8(bitPattern: UInt8($0))) } }
    public func u16() -> Int? { guard left >= 2 else { return nil }; defer { at += 2 }; return Int(b[at]) | Int(b[at + 1]) << 8 }
    public func i16() -> Int? { u16().map { Int(Int16(bitPattern: UInt16($0))) } }
    public func u32() -> Int? {
        guard left >= 4 else { return nil }
        var v = 0; for i in 0..<4 { v |= Int(b[at + i]) << (8 * i) }; at += 4; return v
    }
    public func i32() -> Int? { u32().map { Int(Int32(bitPattern: UInt32($0))) } }
    public func u64() -> UInt64? {
        guard left >= 8 else { return nil }
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[at + i]) << UInt64(8 * i) }; at += 8; return v
    }
    /// A u64 read as a signed count (sizes, times).
    public func i64() -> Int64? { u64().map { Int64(bitPattern: $0) } }
    /// A double; a value that isn't finite reads as 0 (as Windows does), a missing one as nil.
    public func f64() -> Double? { u64().map { let d = Double(bitPattern: $0); return d.isFinite ? d : 0 } }
    public func f32() -> Float? { u32().map { let f = Float(bitPattern: UInt32($0)); return f.isFinite ? f : 0 } }
    public func bytes(_ n: Int) -> [UInt8]? { guard n >= 0, left >= n else { return nil }; defer { at += n }; return Array(b[at..<(at + n)]) }
    public func rest() -> [UInt8] { defer { at = b.count }; return Array(b[at...]) }
    public func string(_ limit: Int = 1 << 20) -> String? {
        guard let n = u32(), n <= limit, let s = bytes(n) else { return nil }
        return String(decoding: s, as: UTF8.self)
    }
    public func blob(_ limit: Int) -> [UInt8]? { guard let n = u32(), n <= limit else { return nil }; return bytes(n) }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
public extension Data { var hex: String { [UInt8](self).hex } }
public extension String {
    /// Hex digits back into bytes, or nil when they aren't.
    var unhex: [UInt8]? {
        let c = Array(utf8); guard c.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(c.count / 2)
        func v(_ x: UInt8) -> UInt8? { switch x { case 48...57: return x - 48; case 97...102: return x - 87; case 65...70: return x - 55; default: return nil } }
        var i = 0
        while i < c.count { guard let a = v(c[i]), let b = v(c[i + 1]) else { return nil }; out.append(a << 4 | b); i += 2 }
        return out
    }
}

/// Equal in constant time (for keys and hashes).
public func sameBytes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var d: UInt8 = 0; for i in 0..<a.count { d |= a[i] ^ b[i] }; return d == 0
}

/// A peer's name as shown: printable, at most 64 characters.
public func cleanName(_ n: String) -> String {
    let out = String(n.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.prefix(64).map(Character.init))
    return out.isEmpty ? "A PC" : out
}

/// A file name made safe for any file system.
public func safeName(_ name: String) -> String {
    var n = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    n = String(n.map { c -> Character in
        if let a = c.asciiValue, a < 32 || a == 127 || "<>:\"/\\|?*".contains(c) { return "_" }
        return c
    }).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    if n.count > 120 {
        let dot = n.lastIndex(of: ".")
        let ext = dot.map { String(n[$0...]) }.flatMap { $0.count <= 12 ? $0 : nil } ?? ""
        n = String(n.prefix(120 - ext.count)) + ext
    }
    if n.isEmpty { return "file" }
    let stem = (n.split(separator: ".").first.map(String.init) ?? n).uppercased()
    var reserved: Set<String> = ["CON", "PRN", "AUX", "NUL"]
    for i in 1...9 { reserved.insert("COM\(i)"); reserved.insert("LPT\(i)") }
    return reserved.contains(stem) ? "_" + n : n
}

/// A received relative path, each part made safe; "." and ".." dropped, at most 24 parts.
public func safePath(_ path: String) -> [String] {
    path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .map { var s = $0; while s.hasSuffix(".") { s.removeLast() }; return s }
        .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        .map(safeName).prefix(24).map { $0 }
}

/// Milliseconds since 1970, as the protocol's clocks count.
@inline(__always) func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

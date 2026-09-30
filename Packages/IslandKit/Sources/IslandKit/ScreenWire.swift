import Foundation

/// The pieces of a screen's frames (revision 7, island 0.24), either way, as the Android app's ScreenWire.kt has them.
public enum ScreenWire {
    public static let chunk = 128 * 1024
    /// Asking for the PC's screen here: the largest picture this device shows (long side first), fps, and bits a second (0: as the path allows).
    public static func askPc(longest: Int, shortest: Int, fps: Int, bitrate: Int = 0) -> [UInt8] { Wire().u8(Proto.screenRequest).u8(1).u16(longest).u16(shortest).u8(fps).u32(bitrate).build() }
    /// Offering this device's picture (its screen or camera) to the PC: its size, fps and name.
    public static func offerPhone(width: Int, height: Int, fps: Int, name: String) -> [UInt8] { Wire().u8(Proto.screenRequest).u8(2).u16(width).u16(height).u8(fps).string(name).build() }

    public struct Reply { public let status: Int; public let width: Int; public let height: Int; public let fps: Int; public let bitrate: Int; public let encoder: String }
    public static func reply(_ f: [UInt8]) -> Reply? {
        let r = Reader(f); guard r.u8() == Proto.screenReply, let status = r.u8() else { return nil }
        return Reply(status: status, width: r.u16() ?? 0, height: r.u16() ?? 0, fps: r.u8() ?? 0, bitrate: r.u32() ?? 0, encoder: r.string(512) ?? "")
    }
    /// One encoded frame as the frames that carry it (128 KB at most each).
    public static func frames(number: Int, key: Bool, pts100ns: UInt64, data: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []; var at = 0
        repeat {
            let n = min(chunk, data.count - at); let last = at + n >= data.count
            out.append(Wire().u8(Proto.screenVideo).u8((key ? 1 : 0) | (at == 0 ? 2 : 0) | (last ? 4 : 0)).u32(number).u64(pts100ns).raw(Array(data[at..<(at + n)])).build())
            at += n
        } while at < data.count
        return out
    }
    public static func feedback(last: Int, decodeMs: Int, kbps: Int, fps: Int) -> [UInt8] { Wire().u8(Proto.screenFeedback).u32(last).u16(min(65535, max(0, decodeMs))).u32(max(0, kbps)).u8(min(255, max(0, fps))).build() }
    public static func input(_ frame: [UInt8]) -> [UInt8] { [UInt8(Proto.screenInput)] + frame }
    public static func limits(width: Int, height: Int, fps: Int) -> [UInt8] { Wire().u8(Proto.screenLimits).u16(width).u16(height).u8(fps).build() }

    public struct Frame { public let number: Int; public let key: Bool; public let pts: UInt64; public let data: [UInt8] }
    /// Frames put back together: whole ones come out with whether they're key frames, their number and time.
    public final class Assembler {
        private var buffer: [UInt8] = []; private var current = -1; private var key = false; private var pts: UInt64 = 0
        public init() {}
        public func add(_ f: [UInt8]) -> Frame? {
            guard f.count >= 14, f[0] == UInt8(Proto.screenVideo) else { return nil }
            let r = Reader(f); _ = r.u8(); guard let flags = r.u8(), let n = r.u32(), let t = r.u64() else { return nil }
            if flags & 2 != 0 { buffer.removeAll(keepingCapacity: true); current = n; key = flags & 1 != 0; pts = t }
            else if n != current { buffer.removeAll(keepingCapacity: true); current = -1; return nil }
            buffer.append(contentsOf: f[14...])
            if flags & 4 == 0 { return nil }
            let whole = Frame(number: n, key: key, pts: pts, data: buffer); buffer.removeAll(keepingCapacity: true); current = -1; return whole
        }
    }
    /// NAL units of an Annex B frame: (type, start after the start code, end).
    public static func nals(_ d: [UInt8]) -> [(Int, Int, Int)] {
        var out: [(Int, Int, Int)] = []
        func code(_ i: Int) -> Int {
            if i + 3 <= d.count && d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 { return 3 }
            if i + 4 <= d.count && d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 0 && d[i + 3] == 1 { return 4 }
            return 0
        }
        var i = 0; while i < d.count && code(i) == 0 { i += 1 }
        while i < d.count { let s = i + code(i); var j = s; while j < d.count && code(j) == 0 { j += 1 }; if s < j { out.append((Int(d[s] & 0x1F), s, j)) }; i = j }
        return out
    }
}

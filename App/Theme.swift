import SwiftUI
import UIKit

/// The app's look, as the Android app's: the accent comes from what plays on your PC (its cover's most vivid colour) and
/// eases from one song's colour to the next; with nothing playing it is the island's own mint.
struct Palette: Equatable {
    var accent: Color, accent2: Color, deep: Color
    static let mint = Color(hex: 0xA5D8C5), periwinkle = Color(hex: 0x8FA8FF), night = Color(hex: 0x0B1220)
    static let standard = Palette(accent: mint, accent2: periwinkle, deep: night)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) { self.init(.sRGB, red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255, opacity: opacity) }
    init?(hexString: String) { guard let v = UInt32(hexString, radix: 16) else { return nil }; self.init(hex: v) }
    var hexString: String {
        let c = UIColor(self); var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
    func mixed(with other: Color, by t: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0, r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1); b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let k = CGFloat(t); return Color(.sRGB, red: r1 + (r2 - r1) * k, green: g1 + (g2 - g1) * k, blue: b1 + (b2 - b1) * k, opacity: a1 + (a2 - a1) * k)
    }
}

/// The app's colours for the light or dark theme.
struct Tokens {
    let dark: Bool, palette: Palette
    var accent: Color { dark ? palette.accent : palette.accent.mixed(with: .black, by: 0.38) }
    var accent2: Color { dark ? palette.accent2 : palette.accent2.mixed(with: .black, by: 0.3) }
    /// The accent for text and symbols on accent-tinted glass (a prominent button, the chosen tab): lifted in the dark so
    /// a deep colour (a violet cover) still reads.
    var onAccent: Color { dark ? palette.accent.mixed(with: .white, by: 0.45) : accent }
    var deep: Color { dark ? palette.deep : palette.deep.mixed(with: .white, by: 0.9) }
    var text: Color { dark ? Color(hex: 0xF5F7FA) : Color(hex: 0x10131A) }
    var muted: Color { dark ? Color(hex: 0xB3BAC6) : Color(hex: 0x545C6A) }
    var faint: Color { dark ? Color(hex: 0x7F8796) : Color(hex: 0x878F9C) }
    var track: Color { dark ? .white.opacity(0.16) : Color(hex: 0x0B0D12, opacity: 0.12) }
    var hairline: Color { dark ? .white.opacity(0.12) : Color(hex: 0x0B0D12, opacity: 0.10) }
    var danger: Color { dark ? Color(hex: 0xFF6B61) : Color(hex: 0xD93A30) }
    var good: Color { dark ? Color(hex: 0x5FD98A) : Color(hex: 0x1F9D55) }
    var warn: Color { dark ? Color(hex: 0xFFC04D) : Color(hex: 0xB7791F) }
}

private struct TokensKey: EnvironmentKey { static let defaultValue = Tokens(dark: true, palette: .standard) }
extension EnvironmentValues { var tokens: Tokens { get { self[TokensKey.self] } set { self[TokensKey.self] = newValue } } }

/// The type scale (the Android app's, in points), in SF Pro.
enum TypeScale {
    static let hero = Font.system(size: 34, weight: .bold).width(.standard)
    static let title = Font.system(size: 26, weight: .bold)
    static let headline = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 15)
    static let bodyStrong = Font.system(size: 15, weight: .semibold)
    static let caption = Font.system(size: 12.5, weight: .medium)
    static let micro = Font.system(size: 11, weight: .semibold)
    static let digits = Font.system(size: 44, weight: .light, design: .rounded)
}

/// The colours a cover lends the app: a vivid one, a second one, and a deep one for the background, weighed as the Android
/// app's Art.colors weighs them (how vivid and how common each hue is).
enum Art {
    static func palette(_ image: UIImage) -> Palette? {
        guard let cg = image.cgImage else { return nil }
        let w = 24, h = 24; var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bins = [[Double]](repeating: [0, 0, 0, 0], count: 12); var ar = 0.0, ag = 0.0, ab = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2]); ar += r; ag += g; ab += b
            let (hue, s, v) = hsv(r, g, b); let weight = s * s * (1 - abs(v - 0.62))
            if v < 0.12 || weight <= 0.01 { continue }
            let k = min(11, max(0, Int(hue / 30))); bins[k][0] += weight; bins[k][1] += r * weight; bins[k][2] += g * weight; bins[k][3] += b * weight
        }
        let n = Double(w * h)
        let order = bins.indices.sorted { bins[$0][0] > bins[$1][0] }
        func color(_ i: Int) -> (Double, Double, Double)? { let b = bins[i]; return b[0] < 0.6 ? nil : (b[1] / b[0], b[2] / b[0], b[3] / b[0]) }
        let first = color(order[0]) ?? (165, 216, 197)
        let far = order.dropFirst().first { let d = abs($0 - order[0]); return min(d, 12 - d) >= 2 }
        let second = far.flatMap(color) ?? shift(first, 40)
        return Palette(accent: vivid(first), accent2: vivid(second), deep: deep((ar / n, ag / n, ab / n)))
    }
    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let R = r / 255, G = g / 255, B = b / 255; let mx = max(R, G, B), mn = min(R, G, B), d = mx - mn
        var h = 0.0
        if d > 0 { if mx == R { h = (G - B) / d } else if mx == G { h = (B - R) / d + 2 } else { h = (R - G) / d + 4 }; h *= 60; if h < 0 { h += 360 } }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
    private static func make(_ h: Double, _ s: Double, _ v: Double) -> Color { Color(hue: h / 360, saturation: s, brightness: v) }
    private static func vivid(_ c: (Double, Double, Double)) -> Color { let (h, s, v) = hsv(c.0, c.1, c.2); return make(h, max(0.35, min(0.85, s * 1.15)), max(0.78, min(0.98, v))) }
    private static func deep(_ c: (Double, Double, Double)) -> Color { let (h, s, v) = hsv(c.0, c.1, c.2); return make(h, min(0.7, s * 0.9), max(0.08, min(0.2, v))) }
    private static func shift(_ c: (Double, Double, Double), _ deg: Double) -> (Double, Double, Double) {
        let (h, s, v) = hsv(c.0, c.1, c.2); let ui = UIColor(hue: CGFloat(((h + deg).truncatingRemainder(dividingBy: 360)) / 360), saturation: CGFloat(s), brightness: CGFloat(v), alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; ui.getRed(&r, green: &g, blue: &b, alpha: &a); return (Double(r) * 255, Double(g) * 255, Double(b) * 255)
    }
}

// ---- words ----
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
func ago(_ at: Date, now: Date = Date()) -> String {
    let m = Int(now.timeIntervalSince(at) / 60)
    if m < 1 { return "Just now" }; if m < 60 { return "\(m) min ago" }; if m < 24 * 60 { return "\(m / 60) h ago" }; if m < 48 * 60 { return "Yesterday" }
    return at.formatted(date: .abbreviated, time: .omitted)
}
func rateText(_ b: Double) -> String { b < 1024 ? "\(Int(b)) B/s" : b < 1_048_576 ? "\(Int(b / 1024)) KB/s" : String(format: "%.1f MB/s", b / 1_048_576) }
func leftText(_ s: Double) -> String {
    guard s.isFinite, s >= 0, s <= 360_000 else { return "" }
    if s < 60 { return "\(max(1, Int(s))) s left" }; if s < 3600 { return "\(Int(s / 60)) min left" }
    return "\(Int(s / 3600)) h \(Int(s / 60) % 60) min left"
}
func span(_ seconds: Double) -> String { let d = Int(seconds) / 86400, h = Int(seconds) % 86400 / 3600, m = Int(seconds) % 3600 / 60; return d > 0 ? "\(d) d \(h) h" : h > 0 ? "\(h) h \(m) min" : "\(m) min" }
func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
func symbolFor(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp": return "photo"
    case "mp4", "mov", "mkv", "avi", "webm", "m4v": return "film"
    case "mp3", "flac", "wav", "m4a", "ogg", "aac": return "music.note"
    case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
    case "pdf": return "doc.richtext"
    default: return "doc"
    }
}

import SwiftUI

/// The light behind everything: a mesh of the song's colours that drifts slowly (a little faster while music plays) and
/// leans as the iPhone tilts, over the night-deep background, with a fine grain so the gradient never bands.
struct Ambient: View {
    let playing: Bool
    var still = false
    @Environment(\.tokens) private var t
    private var tilt: Tilt { Tilt.shared }
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var phase
    var body: some View {
        let paused = reduce || still || phase != .active
        ZStack {
            (t.dark ? t.deep.mixed(with: .black, by: 0.55) : t.deep).ignoresSafeArea()
            TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { ctx in
                let s = ctx.date.timeIntervalSinceReferenceDate * (playing ? 0.16 : 0.07)
                let tx = Float(tilt.x) * 0.06, ty = Float(tilt.y) * 0.05
                let p = { (x: Float, y: Float, k: Double) -> SIMD2<Float> in
                    SIMD2(x + Float(sin(s * (1 + k * 0.3) + k)) * 0.07 + tx * (1 - abs(x - 0.5) * 2), y + Float(cos(s * (0.8 + k * 0.2) + k * 1.7)) * 0.06 + ty * (1 - abs(y - 0.5) * 2))
                }
                let a = t.accent.opacity(t.dark ? 0.55 : 0.42), b = t.accent2.opacity(t.dark ? 0.45 : 0.34), d = Color.clear
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], p(0.5, 0.45, 1), [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ], colors: [
                    a, d, b,
                    d, a.opacity(0.35), d,
                    b.opacity(0.7), d, a.opacity(0.6),
                ], smoothsColors: true)
                .ignoresSafeArea()
                .blur(radius: 30)
                .overlay {
                    // Two slow blobs of light, the song's colours.
                    let m = p(0.3, 0.25, 2), n = p(0.75, 0.7, 3)
                    GeometryReader { g in
                        Circle().fill(RadialGradient(colors: [t.accent.opacity(t.dark ? 0.35 : 0.25), .clear], center: .center, startRadius: 0, endRadius: g.size.width * 0.45))
                            .frame(width: g.size.width * 0.9).position(x: g.size.width * CGFloat(m.x), y: g.size.height * CGFloat(m.y))
                        Circle().fill(RadialGradient(colors: [t.accent2.opacity(t.dark ? 0.28 : 0.2), .clear], center: .center, startRadius: 0, endRadius: g.size.width * 0.5))
                            .frame(width: g.size.width).position(x: g.size.width * CGFloat(n.x), y: g.size.height * CGFloat(n.y))
                    }
                    .ignoresSafeArea()
                    .blendMode(t.dark ? .screen : .normal)
                }
            }
            Grain().opacity(t.dark ? 0.05 : 0.035).ignoresSafeArea().allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A fine, still grain (drawn once, then tiled).
private struct Grain: View {
    static let tile: UIImage = {
        let side = 128, f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { c in
            var rng = SplitMix(seed: 42)
            for _ in 0..<(side * side / 6) {
                let x = Int(rng.next() % UInt64(side)), y = Int(rng.next() % UInt64(side)), v = rng.next() % 2 == 0
                c.cgContext.setFillColor((v ? UIColor.white : UIColor.black).cgColor); c.cgContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }()
    var body: some View { Image(uiImage: Grain.tile).resizable(resizingMode: .tile) }
}
struct SplitMix { var seed: UInt64; mutating func next() -> UInt64 { seed &+= 0x9E3779B97F4A7C15; var z = seed; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }

/// The weather where your PC is, on the glass: rain running down it, snow drifting, a flash of lightning, or sun motes.
enum Sky { case clear, clouds, rain, drizzle, storm, snow, fog, none
    static func of(_ weather: String) -> Sky {
        let w = weather.lowercased()
        if w.isEmpty { return .none }
        if w.contains("thunder") || w.contains("storm") { return .storm }
        if w.contains("snow") || w.contains("sleet") { return .snow }
        if w.contains("drizzle") { return .drizzle }
        if w.contains("rain") || w.contains("shower") { return .rain }
        if w.contains("fog") || w.contains("mist") || w.contains("haze") { return .fog }
        if w.contains("cloud") || w.contains("overcast") { return .clouds }
        if w.contains("clear") || w.contains("sun") { return .clear }
        return .none
    }
    var symbol: String {
        switch self { case .storm: return "cloud.bolt.rain.fill"; case .rain: return "cloud.rain.fill"; case .drizzle: return "cloud.drizzle.fill"; case .snow: return "snowflake"; case .fog: return "cloud.fog.fill"; case .clear: return "sun.max.fill"; default: return "cloud.fill" }
    }
}

struct WeatherGlass: View {
    let sky: Sky; var active = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.tokens) private var t
    var body: some View {
        if sky == .rain || sky == .drizzle || sky == .storm || sky == .snow || sky == .clear {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduce)) { ctx in
                let time = ctx.date.timeIntervalSinceReferenceDate
                Canvas { g, size in
                    var rng = SplitMix(seed: 7)
                    switch sky {
                    case .snow:
                        for i in 0..<60 {
                            let speed = 18 + Double(rng.next() % 30), x0 = Double(rng.next() % 1000) / 1000 * size.width, r = 1 + Double(rng.next() % 25) / 10
                            let y = (Double(rng.next() % 1000) / 1000 * size.height + time * speed).truncatingRemainder(dividingBy: size.height + 20) - 10
                            let x = x0 + sin(time * 0.6 + Double(i)) * 14
                            g.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.55)))
                        }
                    case .clear:
                        for i in 0..<18 {
                            let x0 = Double(rng.next() % 1000) / 1000 * size.width, y0 = Double(rng.next() % 1000) / 1000 * size.height * 0.6
                            let r = 1.5 + Double(rng.next() % 30) / 10, a = 0.12 + 0.12 * sin(time * 0.8 + Double(i))
                            g.fill(Path(ellipseIn: CGRect(x: x0 + sin(time * 0.2 + Double(i)) * 20, y: y0 + cos(time * 0.15 + Double(i)) * 12, width: r * 2, height: r * 2)), with: .color(t.accent.opacity(a)))
                        }
                    default:
                        let n = sky == .drizzle ? 40 : 90
                        for _ in 0..<n {
                            let speed = (sky == .drizzle ? 260 : 520) + Double(rng.next() % 300), x = Double(rng.next() % 1000) / 1000 * size.width
                            let len = sky == .drizzle ? 8 + Double(rng.next() % 8) : 14 + Double(rng.next() % 18)
                            let y = (Double(rng.next() % 1000) / 1000 * size.height + time * speed).truncatingRemainder(dividingBy: size.height + len) - len
                            var p = Path(); p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x - len * 0.12, y: y + len))
                            g.stroke(p, with: .color(.white.opacity(0.16)), lineWidth: 1)
                        }
                        if sky == .storm {
                            let flash = max(0, sin(time * 0.9) * sin(time * 2.3)); if flash > 0.93 { g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity((flash - 0.93) * 2.2))) }
                        }
                    }
                }
            }
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// Sparks that fly up from the bottom of the screen towards the island while something is being sent, and fall from it
/// while something arrives.
struct HandoffParticles: View {
    let transfers: [Transfer]
    @Environment(\.tokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        if !transfers.isEmpty && !reduce {
            let outgoing = transfers.contains { $0.outgoing }
            TimelineView(.animation(minimumInterval: 1 / 40)) { ctx in
                let time = ctx.date.timeIntervalSinceReferenceDate
                Canvas { g, size in
                    var rng = SplitMix(seed: 11)
                    for _ in 0..<26 {
                        let life = 1.6 + Double(rng.next() % 100) / 100, offset = Double(rng.next() % 1000) / 1000 * life
                        let k = (time + offset).truncatingRemainder(dividingBy: life) / life
                        let f = outgoing ? k : 1 - k
                        let x0 = Double(rng.next() % 1000) / 1000 * size.width
                        let x = x0 + (size.width / 2 - x0) * f * f, y = size.height * (1 - f) + 30 * (1 - f) * sin(k * 9)
                        let r = 1.2 + 2.2 * (1 - abs(k - 0.5) * 2)
                        g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(t.accent.opacity(0.55 * (1 - abs(k - 0.5) * 2))))
                    }
                }
            }
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true).transition(.opacity)
        }
    }
}

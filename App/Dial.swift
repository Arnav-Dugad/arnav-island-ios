import IslandKit
import SwiftUI

/// The PC's volume as a dial: twist it (from anywhere on it) and the level follows the finger's turn, with a tick at every
/// 5% and a firmer one at each quarter; the arc glows brighter as it rises and the knob swells under the finger. Tap the
/// middle to mute. The Digital Crown's cousin, for your thumb.
struct VolumeDial: View {
    let value: Double; let muted: Bool
    var onChange: (Double) -> Void; var onDone: (Double) -> Void; var onMute: () -> Void
    var size: CGFloat = 168; var label = "Volume"
    @Environment(\.tokens) private var t
    @State private var local: Double?
    @State private var lastAngle: Double = 0
    @State private var lastStep = 0
    private let start = 135.0, sweep = 270.0

    var body: some View {
        let v = local ?? value, level = muted ? 0 : max(0, min(1, v)), turning = local != nil
        let stroke: CGFloat = 11, r = size / 2 - stroke * 1.6
        ZStack {
            Circle().fill(RadialGradient(colors: [.clear, t.accent.opacity(0.1 + 0.32 * level + (turning ? 0.15 : 0)), .clear], center: .center, startRadius: r * 0.7, endRadius: r + stroke * 2.4))
            Arc(start: start, sweep: sweep).stroke(t.track, style: StrokeStyle(lineWidth: stroke, lineCap: .round)).frame(width: r * 2, height: r * 2)
            Arc(start: start, sweep: sweep * level).stroke(AngularGradient(colors: [t.accent.opacity(0.7), t.accent], center: .center, startAngle: .degrees(start), endAngle: .degrees(start + sweep)), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .frame(width: r * 2, height: r * 2).shadow(color: t.accent.opacity(0.45 * level), radius: 8)
            ForEach(0..<11) { k in
                let a = (start + sweep * Double(k) / 10) * .pi / 180, rr = r + stroke * 1.25
                Circle().fill(Double(k) / 10 <= level + 0.001 ? t.accent : t.faint.opacity(0.5)).frame(width: k % 5 == 0 ? 4.4 : 3, height: k % 5 == 0 ? 4.4 : 3)
                    .offset(x: rr * cos(a), y: rr * sin(a))
            }
            let ka = (start + sweep * level) * .pi / 180
            Circle().fill(.white).frame(width: stroke * (turning ? 1.5 : 1.24), height: stroke * (turning ? 1.5 : 1.24))
                .shadow(color: t.accent.opacity(0.8), radius: turning ? 10 : 5).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                .offset(x: r * cos(ka), y: r * sin(ka))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: turning)
            Button { Haptics.tap(); onMute() } label: {
                VStack(spacing: 0) {
                    Text(muted ? "–" : "\(Int(v * 100 + 0.5))").font(.system(size: 30, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(t.text)
                        .contentTransition(.numericText(value: v))
                    Text(muted ? "Muted" : "Volume").font(TypeScale.micro).foregroundStyle(t.muted)
                }
                .frame(width: size * 0.52, height: size * 0.52)
                .glass(Circle(), .control, interactive: true)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(muted ? "Sound on" : "Mute")
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .local).onChanged { g in
            let a = atan2(g.location.y - size / 2, g.location.x - size / 2) * 180 / .pi
            if local == nil { local = value; lastAngle = a; lastStep = step(value); Haptics.soft(0.5); return }
            var d = (a - lastAngle).truncatingRemainder(dividingBy: 360); if d > 180 { d -= 360 }; if d <= -180 { d += 360 }
            lastAngle = a
            let nv = max(0, min(1, (local ?? value) + d / sweep)); local = nv; onChange(nv)
            let s = step(nv); if s != lastStep { lastStep = s; Haptics.detent(edge: s % 5 == 0) }
        }.onEnded { _ in if let l = local { onDone(l) }; withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { local = nil } })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label).accessibilityValue(muted ? "Muted" : "\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { d in onDone(max(0, min(1, value + (d == .increment ? 0.05 : -0.05)))) }
    }
    private func step(_ v: Double) -> Int { max(0, min(20, Int(v * 20 + 0.5))) }
}

struct Arc: Shape {
    let start: Double; let sweep: Double
    func path(in rect: CGRect) -> Path {
        var p = Path(); guard sweep > 0.01 else { return p }
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
        return p
    }
}

/// The PC's lyrics for what plays there, word by word: the line being sung is bright and large, its words light up as they
/// are sung, the lines before fade. It follows the song unless you scroll; a line tapped plays from there.
struct LyricsView: View {
    let lyrics: Lyrics?; let position: () -> Double; let playing: Bool; let pcName: String
    var onSeek: (Double) -> Void
    @Environment(\.tokens) private var t
    @State private var touchedAt = Date.distantPast

    static func synced(_ l: [LyricsLine]) -> Bool { l.count > 1 && l.contains { $0.time > 0 } }
    static func lineAt(_ lines: [LyricsLine], _ time: Double) -> Int {
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi { let mid = (lo + hi) / 2; if lines[mid].time <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 } }
        return found
    }

    var body: some View {
        let lines = lyrics?.lines ?? []
        if lyrics == nil || lyrics?.state == 1 { hint("Looking for the lyrics…") }
        else if lyrics?.state == 0 { hint("Lyrics are off on \(pcName)", "Turn them on in the island’s Settings › Music") }
        else if lines.isEmpty { hint("No lyrics for this song") }
        else if !Self.synced(lines) {
            ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(l.text).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.86)) } }.padding(22) }
        } else {
            TimelineView(.animation(minimumInterval: playing ? 1 / 12 : 0.5)) { _ in
                let now = position(), current = Self.lineAt(lines, now)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                let on = i == current
                                Group { if on { sung(l, now) } else { Text(l.text.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : l.text) } }
                                    .font(.system(size: on ? 24 : 20, weight: .bold))
                                    .foregroundStyle(i < current ? .white.opacity(0.38) : on ? .white : .white.opacity(0.5))
                                    .blur(radius: on || abs(i - current) > 3 ? 0 : CGFloat(abs(i - current)) * 0.4)
                                    .scaleEffect(on ? 1 : 0.97, anchor: .leading)
                                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: current)
                                    .id(i)
                                    .onTapGesture { Haptics.tick(); onSeek(l.time) }
                            }
                        }
                        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 180)
                    }
                    .scrollIndicators(.hidden)
                    .simultaneousGesture(DragGesture().onChanged { _ in touchedAt = Date() })
                    .onChange(of: current) { _, c in
                        guard c >= 0, Date().timeIntervalSince(touchedAt) > 3.5 else { return }
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { proxy.scrollTo(max(0, c - 1), anchor: .top) }
                    }
                }
            }
        }
    }
    /// The line being sung: words already sung are white, the one being sung fills in, the rest wait.
    private func sung(_ line: LyricsLine, _ now: Double) -> Text {
        let text = line.text.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : line.text
        guard !line.words.isEmpty else { return Text(text) }
        let chars = Array(text); let starts = line.words.map { max(0, min(chars.count, $0.at)) }
        var out = Text(starts[0] > 0 ? String(chars[0..<starts[0]]) : "")
        for (k, w) in line.words.enumerated() {
            let from = starts[k], to = k + 1 < starts.count ? max(from, starts[k + 1]) : chars.count
            let next = k + 1 < line.words.count ? line.words[k + 1].time : w.time + 0.6
            let f = max(0, min(1, (now - w.time) / max(0.08, next - w.time)))
            let color: Color = now < w.time ? .white.opacity(0.42) : Color.white.mixed(with: t.accent, by: 0.35 * (1 - f))
            out = out + Text(String(chars[from..<to])).foregroundColor(color)
        }
        return out
    }
    private func hint(_ title: String, _ detail: String? = nil) -> some View {
        VStack(spacing: 6) {
            Text(title).font(TypeScale.headline).foregroundStyle(.white)
            if let detail { Text(detail).font(TypeScale.caption).foregroundStyle(.white.opacity(0.7)) }
        }
        .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

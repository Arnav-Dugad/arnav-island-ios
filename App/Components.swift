import IslandKit
import SwiftUI

// ---- building blocks shared by every screen ----

/// A screen's title: a small line over it, the title, and something at the end.
struct ScreenTitle<Trailing: View>: View {
    let title: String; var over: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.tokens) private var t
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let over { Text(over.uppercased()).font(TypeScale.micro).tracking(0.8).foregroundStyle(t.muted).contentTransition(.opacity) }
                Text(title).font(TypeScale.hero).foregroundStyle(t.text).lineLimit(1).minimumScaleFactor(0.6).contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.top, 8).padding(.bottom, 16)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}
extension ScreenTitle where Trailing == EmptyView { init(title: String, over: String? = nil) { self.init(title: title, over: over) { EmptyView() } } }

struct SectionLabel: View {
    let text: String; var action: (String, () -> Void)? = nil
    @Environment(\.tokens) private var t
    var body: some View {
        HStack {
            Text(text).font(TypeScale.bodyStrong).foregroundStyle(t.muted)
            Spacer()
            if let action { Button(action.0) { Haptics.tick(); action.1() }.font(TypeScale.caption).foregroundStyle(t.accent) }
        }
        .padding(.top, 24).padding(.bottom, 10).padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A glass card holding a screen's part.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 18; var radius: CGFloat = 30; var tint: Color? = nil
    @ViewBuilder var content: () -> Content
    var body: some View { content().padding(padding).frame(maxWidth: .infinity, alignment: .leading).glassCard(radius, tint: tint) }
}

/// Whether a device is here: a dot that breathes while it is.
struct LiveDot: View {
    let on: Bool; var size: CGFloat = 9
    @Environment(\.tokens) private var t
    @State private var breathe = false
    var body: some View {
        ZStack {
            if on { Circle().fill(t.good.opacity(0.35)).frame(width: size * 2.2, height: size * 2.2).scaleEffect(breathe ? 1 : 0.5).opacity(breathe ? 0 : 0.9) }
            Circle().fill(on ? t.good : t.faint).frame(width: size, height: size)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear { if on { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { breathe = true } } }
        .onChange(of: on) { _, v in breathe = false; if v { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { breathe = true } } }
        .accessibilityLabel(on ? "Here" : "Away")
    }
}

/// Level bars that dance while music plays and settle when it pauses.
struct Equalizer: View {
    let playing: Bool; var width: CGFloat = 18; var height: CGFloat = 14; var bars = 4; var color: Color? = nil
    @Environment(\.tokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !playing || reduce)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: width / CGFloat(bars * 3)) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = Double(i) * 1.7
                    let v = playing && !reduce ? 0.25 + 0.75 * abs(sin(time * (2.2 + Double(i) * 0.9) + phase) * cos(time * 1.3 + phase * 0.5)) : 0.22
                    Capsule().fill(color ?? t.accent).frame(width: width / CGFloat(bars) * 0.62, height: max(2, height * v))
                }
            }
            .frame(width: width, height: height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// Play and pause, morphing into each other.
struct PlayPause: View {
    let playing: Bool; var size: CGFloat = 30; var color: Color
    var body: some View {
        Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size, weight: .bold))
            .foregroundStyle(color).contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .speed(1.6)))
            .offset(x: playing ? 0 : size * 0.06)
    }
}

/// How far something has come, as a ring.
struct ProgressRing: View {
    let fraction: Double; var track: Color? = nil; var color: Color? = nil; var size: CGFloat = 22; var stroke: CGFloat = 3
    @Environment(\.tokens) private var t
    var body: some View {
        ZStack {
            Circle().stroke(track ?? t.track, lineWidth: stroke)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction))).stroke(color ?? t.accent, style: StrokeStyle(lineWidth: stroke, lineCap: .round)).rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: fraction)
        }
        .frame(width: size, height: size)
    }
}

/// How well a paired PC is reached: straight over the LAN or UDP, or through the relay, and how quickly.
struct Quality: Equatable {
    let fraction: Double; let color: Color; let text: String
    @MainActor static func of(_ p: PeerView, _ t: Tokens) -> Quality {
        guard p.online else { return Quality(fraction: 0, color: t.faint, text: "Away") }
        let ms = Int(p.rtt)
        let lan = p.lan ? "On this Wi-Fi" : p.path == 2 ? "Direct" : "Through the relay"
        let rtt = ms > 0 ? "  ·  \(ms) ms" : ""
        let f: Double = p.path == 2 ? (ms > 0 && ms < 40 ? 1 : 0.8) : ms > 0 && ms < 150 ? 0.62 : 0.42
        return Quality(fraction: f, color: f >= 0.8 ? t.good : f >= 0.6 ? t.accent : t.warn, text: lan + rtt)
    }
}
struct QualityRing: View {
    let q: Quality; var size: CGFloat = 14; var stroke: CGFloat = 2
    var body: some View { ProgressRing(fraction: q.fraction, track: .white.opacity(0.15), color: q.color, size: size, stroke: stroke).accessibilityLabel(q.text) }
}

/// A slider of glass: answers the finger at once, grows under it, ticks at marks (a song's lyric lines), and says when let go.
struct GlassSlider: View {
    let value: Double
    var onChange: (Double) -> Void = { _ in }
    var onDone: (Double) -> Void
    var color: Color? = nil; var height: CGFloat = 6; var ticks: [Double]? = nil; var label = "Slider"
    @Environment(\.tokens) private var t
    @State private var dragging: Double?
    @GestureState private var pressed = false
    var body: some View {
        GeometryReader { g in
            let v = dragging ?? value, h = pressed || dragging != nil ? height * 2 : height
            ZStack(alignment: .leading) {
                Capsule().fill(t.track)
                Capsule().fill(color ?? t.accent).frame(width: max(h, g.size.width * max(0, min(1, v))))
                    .shadow(color: (color ?? t.accent).opacity(0.5), radius: dragging != nil ? 8 : 0)
                if let ticks { ForEach(Array(ticks.enumerated()), id: \.offset) { _, x in Circle().fill(t.text.opacity(0.35)).frame(width: 3, height: 3).offset(x: g.size.width * x - 1.5) } }
            }
            .frame(height: h).frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressed) { _, s, _ in s = true }
                .onChanged { d in
                    let nv = max(0, min(1, d.location.x / max(1, g.size.width)))
                    if let old = dragging, let ticks, ticks.contains(where: { ($0 - old) * ($0 - nv) < 0 }) { Haptics.detent() }
                    if dragging == nil { Haptics.soft(0.4) }
                    dragging = nv; onChange(nv)
                }
                .onEnded { d in let nv = max(0, min(1, d.location.x / max(1, g.size.width))); dragging = nil; onDone(nv); Haptics.tick() })
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: h)
        }
        .frame(height: 28)
        .accessibilityElement().accessibilityLabel(label).accessibilityValue("\(Int(value * 100))%")
        .accessibilityAdjustableAction { d in onDone(max(0, min(1, value + (d == .increment ? 0.05 : -0.05)))) }
    }
}

/// A glass step button that repeats while held.
struct StepButton: View {
    let symbol: String; let label: String; let onStep: () -> Void
    @State private var repeating: Task<Void, Never>?
    var body: some View {
        GlassIconButton(symbol: symbol, label: label, size: 44, iconSize: 18) { onStep() }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                repeating?.cancel(); repeating = Task { while !Task.isCancelled { onStep(); Haptics.tick(); try? await Task.sleep(for: .milliseconds(110)) } }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in repeating?.cancel(); repeating = nil })
    }
}

/// A line that slides along when it's longer than its space.
struct Marquee: View {
    let text: String; var font: Font = TypeScale.headline
    @Environment(\.tokens) private var t
    @State private var textWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        GeometryReader { g in
            let over = textWidth > g.size.width + 1 && !reduce
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !over)) { ctx in
                let gap: CGFloat = 48, cycle = (textWidth + gap) / 34 + 2.5
                let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                let x = over ? -max(0, (phase - 2.5)) * 34 : 0
                HStack(spacing: gap) {
                    Text(text).font(font).foregroundStyle(t.text).fixedSize().background(GeometryReader { tg in Color.clear.onAppear { textWidth = tg.size.width }.onChange(of: text) { _, _ in textWidth = tg.size.width } })
                    if over { Text(text).font(font).foregroundStyle(t.text).fixedSize() }
                }
                .offset(x: x)
                .frame(width: g.size.width, alignment: over ? .leading : .center)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: over ? 0.06 : 0), .init(color: .black, location: over ? 0.94 : 1), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        }
        .frame(height: 28)
        .accessibilityElement().accessibilityLabel(text)
    }
}

/// A row of glass settings: a symbol, a title and a line, and a switch (or anything) at the end.
struct SettingRow<Trailing: View>: View {
    let symbol: String; let title: String; var detail: String? = nil; var tint: Color? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.tokens) private var t
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint ?? t.accent)
                .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill((tint ?? t.accent).opacity(t.dark ? 0.16 : 0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.bodyStrong).foregroundStyle(t.text)
                if let detail { Text(detail).font(TypeScale.caption).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
struct ToggleRow: View {
    let symbol: String; let title: String; var detail: String? = nil; var tint: Color? = nil
    @Binding var on: Bool
    @Environment(\.tokens) private var t
    var body: some View {
        SettingRow(symbol: symbol, title: title, detail: detail, tint: tint) { Toggle("", isOn: $on).labelsHidden().tint(t.accent) }
            .onChange(of: on) { _, _ in Haptics.tick() }
    }
}

/// Nothing to show yet: a symbol in a lit well, a line and what to do.
struct EmptyCard<Action: View>: View {
    let symbol: String; let title: String; let detail: String
    @ViewBuilder var action: () -> Action
    @Environment(\.tokens) private var t
    var body: some View {
        GlassPanel(padding: 26) {
            VStack(spacing: 0) {
                Image(systemName: symbol).font(.system(size: 34, weight: .medium)).foregroundStyle(t.accent)
                    .frame(width: 84, height: 84).background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(t.accent.opacity(0.14)))
                    .symbolEffect(.pulse, options: .repeating.speed(0.4))
                Text(title).font(TypeScale.headline).foregroundStyle(t.text).multilineTextAlignment(.center).padding(.top, 16)
                Text(detail).font(TypeScale.caption).foregroundStyle(t.muted).multilineTextAlignment(.center).padding(.top, 6)
                action().padding(.top, 16)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
extension EmptyCard where Action == EmptyView { init(symbol: String, title: String, detail: String) { self.init(symbol: symbol, title: title, detail: detail) { EmptyView() } } }

/// A cover, or a note where there's none.
struct CoverImage: View {
    let image: UIImage?; var radius: CGFloat = 18
    @Environment(\.tokens) private var t
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity.combined(with: .scale(scale: 1.04))) }
            else { LinearGradient(colors: [t.accent.opacity(0.4), t.accent2.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "music.note").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white.opacity(0.85)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Seconds, updating on their own.
struct Ticking<Content: View>: View {
    var every: Double = 1; var paused = false
    @ViewBuilder var content: (Date) -> Content
    var body: some View { TimelineView(.periodic(from: .now, by: every)) { ctx in content(paused ? Date() : ctx.date) } }
}

extension View {
    /// Shows in from below with a spring, a little after [delay] (a screen's parts arriving one after another).
    func arrive(_ index: Int = 0) -> some View { modifier(Arrive(index: index)) }
}
private struct Arrive: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown || reduce ? 0 : 18).scaleEffect(shown || reduce ? 1 : 0.98, anchor: .top)
            .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(Double(min(index, 8)) * 0.045)) { shown = true } }
    }
}

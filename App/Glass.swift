import SwiftUI

/// Liquid glass. On iOS 26, Apple's own: it bends and frosts what's behind it and catches the light as the iPhone moves.
/// Before that, a frosted material with a rim of light and a sheen, as the Android app draws its glass.
enum GlassLevel { case card, control, bar, island, sheet }

private struct GlassOnKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues { var glassOn: Bool { get { self[GlassOnKey.self] } set { self[GlassOnKey.self] = newValue } } }

struct GlassModifier<S: Shape>: ViewModifier {
    let shape: S; let level: GlassLevel; let tint: Color?; let interactive: Bool
    @Environment(\.tokens) private var t
    @Environment(\.glassOn) private var glassOn
    func body(content: Content) -> some View {
        if !glassOn { solid(content) }
        else if #available(iOS 26.0, *) { native(content) }
        else { fallback(content) }
    }
    @available(iOS 26.0, *)
    @ViewBuilder private func native(_ content: Content) -> some View {
        switch level {
        case .card: content.glassEffect(tinted(.clear, strength: 0.22), in: shape)
        case .control: content.glassEffect(tinted(.regular, strength: t.dark ? 0.34 : 0.42).interactive(interactive), in: shape)
        case .bar, .sheet: content.glassEffect(tinted(.regular, strength: 0.24).interactive(interactive), in: shape)
        case .island: content.glassEffect(Glass.regular.tint(Color.black.opacity(0.62)).interactive(interactive), in: shape)
        }
    }
    @available(iOS 26.0, *)
    private func tinted(_ g: Glass, strength: Double) -> Glass { tint.map { g.tint($0.opacity(strength)) } ?? g }

    private var surface: Color {
        switch level {
        case .card: return t.dark ? Color(hex: 0x0C0F15, opacity: 0.30) : .white.opacity(0.55)
        case .control: return t.dark ? .white.opacity(0.10) : .white.opacity(0.45)
        case .bar: return t.dark ? Color(hex: 0x0A0D13, opacity: 0.34) : .white.opacity(0.6)
        case .sheet: return t.dark ? Color(hex: 0x0A0D13, opacity: 0.56) : .white.opacity(0.72)
        case .island: return Color(hex: 0x050608, opacity: 0.78)
        }
    }
    private func fallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    if level != .card { shape.fill(level == .island ? .ultraThinMaterial : .thinMaterial) }
                    shape.fill(surface)
                    if let tint { shape.fill(tint.opacity(level == .control ? (t.dark ? 0.34 : 0.42) : 0.24)) }
                    shape.fill(LinearGradient(colors: [.white.opacity(t.dark ? 0.07 : 0.22), .clear], startPoint: .top, endPoint: .center))
                }
            }
            .overlay { RimLight(shape: shape, width: level == .card ? 0.9 : 1.2, alpha: t.dark ? 0.6 : 0.95) }
            .shadow(color: .black.opacity(t.dark ? 0.34 : 0.12), radius: level == .control ? 6 : 14, y: level == .control ? 2 : 5)
    }
    private func solid(_ content: Content) -> some View {
        content.background {
            ZStack {
                shape.fill(level == .island ? Color(hex: 0x050608, opacity: 0.95) : t.dark ? Color(hex: level == .control ? 0x232935 : 0x151A23, opacity: 0.92) : Color(hex: level == .control ? 0xF0F2F6 : 0xFFFFFF, opacity: 0.94))
                if let tint { shape.fill(tint.opacity(level == .control ? 0.22 : 0.16)) }
            }
        }.overlay { shape.stroke(t.dark ? .white.opacity(0.09) : .black.opacity(0.07), lineWidth: 0.8) }
    }
}

/// The rim of light: brightest where a light above the iPhone would catch the edge, so it slides round the glass as the
/// iPhone tilts, with a fainter return on the far side.
struct RimLight<S: Shape>: View {
    let shape: S; let width: CGFloat; let alpha: Double
    private var tilt: Tilt { Tilt.shared }
    var body: some View {
        let angle = Angle.degrees(225 + tilt.x * 38 - tilt.y * 24)
        let from = UnitPoint(x: 0.5 + 0.5 * cos(angle.radians), y: 0.5 + 0.5 * sin(angle.radians))
        let to = UnitPoint(x: 1 - from.x, y: 1 - from.y)
        shape.stroke(LinearGradient(stops: [.init(color: .white.opacity(alpha), location: 0), .init(color: .white.opacity(alpha * 0.16), location: 0.3), .init(color: .white.opacity(alpha * 0.05), location: 0.7), .init(color: .white.opacity(alpha * 0.45), location: 1)], startPoint: from, endPoint: to), lineWidth: width)
            .padding(width / 2)
            .allowsHitTesting(false)
    }
}
extension View {
    func glass<S: Shape>(_ shape: S, _ level: GlassLevel = .card, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassModifier(shape: shape, level: level, tint: tint, interactive: interactive))
    }
    func glassCard(_ radius: CGFloat = 30, tint: Color? = nil) -> some View { glass(RoundedRectangle(cornerRadius: radius, style: .continuous), .card, tint: tint) }
    func glassCapsule(_ level: GlassLevel = .control, tint: Color? = nil, interactive: Bool = true) -> some View { glass(Capsule(), level, tint: tint, interactive: interactive) }
}

/// A button that springs down under the finger (0.93, damping 0.5), with a tick; on iOS 26 its glass lights where it's touched.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.93
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.09) : .spring(response: 0.32, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

/// A pressable glass capsule that glows in the accent when prominent.
struct GlassButton<Label: View>: View {
    var prominent = false
    /// Filling the width it's given (the halves of a row of two).
    var wide = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.tokens) private var t
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: 8) { label() }
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: wide ? .infinity : nil)
                .foregroundStyle(prominent ? t.onAccent : t.text)
                .padding(.horizontal, 20).padding(.vertical, 13)
                .frame(minHeight: 44)
                .contentShape(Capsule())
                .glassCapsule(.control, tint: prominent ? t.accent : nil)
        }
        .buttonStyle(PressStyle())
        .opacity(enabled ? 1 : 0.42)
    }
}

struct GlassIconButton: View {
    let symbol: String; let label: String
    var size: CGFloat = 46; var iconSize: CGFloat = 20; var prominent = false; var tint: Color? = nil
    let action: () -> Void
    @Environment(\.tokens) private var t
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            Image(systemName: symbol).font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(tint ?? (prominent ? t.onAccent : t.text))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glass(Circle(), .control, tint: prominent ? t.accent : nil, interactive: true)
        }
        .buttonStyle(PressStyle())
        .opacity(enabled ? 1 : 0.42)
        .accessibilityLabel(label)
    }
}

/// A glass chip: a small fact (with its symbol), or a choice when tapped.
struct GlassChip: View {
    let label: String; var symbol: String? = nil; var selected: Bool? = nil; var symbolTint: Color? = nil; var action: (() -> Void)? = nil
    @Environment(\.tokens) private var t
    var body: some View {
        let on = selected == true
        let content = HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(symbolTint ?? (on ? t.text : t.muted)) }
            Text(label).font(TypeScale.caption).fontWeight(on ? .semibold : .medium).foregroundStyle(on ? t.text : t.muted).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassCapsule(.control, tint: on ? t.accent : nil, interactive: action != nil)
        if let action {
            Button(action: { Haptics.tick(); action() }) { content }.buttonStyle(PressStyle()).accessibilityAddTraits(on ? .isSelected : [])
        } else { content }
    }
}

/// A pressable glass tile: a symbol in a lit well, a title and a line under it.
struct GlassTile: View {
    let symbol: String; let title: String; let detail: String; var tint: Color? = nil
    let action: () -> Void
    @Environment(\.tokens) private var t
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let c = tint ?? t.accent
        Button(action: { Haptics.tap(); action() }) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(c)
                    .frame(width: 42, height: 42).background(Circle().fill(c.opacity(t.dark ? 0.18 : 0.14)))
                    .symbolEffect(.bounce, value: enabled)
                Spacer(minLength: 14)
                Text(title).font(TypeScale.bodyStrong).foregroundStyle(t.text).lineLimit(1)
                Text(detail).font(TypeScale.caption).foregroundStyle(t.muted).lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(16)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassCard(24)
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .opacity(enabled ? 1 : 0.45)
    }
}

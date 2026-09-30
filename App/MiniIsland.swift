import IslandKit
import SwiftUI

/// Where the iPhone's own Dynamic Island is (its size and place), or nil on an iPhone with a notch.
struct HardwareIsland: Equatable {
    let top: CGFloat, width: CGFloat, height: CGFloat
    static func of(safeTop: CGFloat, idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> HardwareIsland? {
        guard idiom == .phone, safeTop >= 58 else { return nil }
        return HardwareIsland(top: safeTop >= 61 ? 14 : 11, width: 126, height: 37.33)
    }
}

/**
 * The island at the top of the app, as on the PC. On an iPhone with a Dynamic Island it *is* the Dynamic Island: pure
 * black, exactly over it, it grows out of it the way the system's own activities do. At rest it shows what plays on your
 * PC (its cover beside the camera, level bars on the other side) or who is here; it widens for a transfer (with its ring),
 * drops open for a moment to say what just happened, and melts open into the song's card when tapped.
 */
struct MiniIsland: View {
    let hardware: HardwareIsland?
    let safeTop: CGFloat
    @Binding var expanded: Bool
    var onTap: () -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce

    private enum Mode: Equatable { case hidden, rest, transfer, banner, player }
    private var latest: Transfer? { hub.transfers.values.max { $0.id < $1.id } }
    private var mode: Mode {
        if hub.banner != nil { return .banner }
        if expanded, hub.status?.available == true { return .player }
        if latest != nil { return .transfer }
        if hub.pc() == nil && hardware != nil { return .hidden }
        return .rest
    }

    var body: some View {
        GeometryReader { g in
            let m = mode
            let full = min(g.size.width - 22, 400)
            let base = hardware?.width ?? 150
            let playing = hub.status?.available == true
            // Beside the camera: room on the left (the clock is far left) but little on the right, where the signal
            // bars begin; so the island grows mostly leftwards, as the system's own activities seem to.
            let sides = extras(m)
            let width: CGFloat = {
                switch m {
                case .hidden: return base
                case .rest: return hardware != nil ? base + sides.0 + sides.1 : (playing ? 190 : 150)
                case .transfer: return hardware != nil ? base + sides.0 + sides.1 : 250
                case .banner, .player: return full
                }
            }()
            let shift: CGFloat = hardware != nil && (m == .rest || m == .transfer) ? (sides.1 - sides.0) / 2 : 0
            let height: CGFloat = {
                switch m {
                case .banner: return (hardware?.height ?? 0) + 72
                case .player: return (hardware?.height ?? 0) + 176
                default: return hardware?.height ?? 36
                }
            }()
            let radius: CGFloat = m == .banner || m == .player ? 46 : height / 2
            let top = hardware?.top ?? safeTop + 4
            ZStack {
                shape(radius)
                face(m, hardwareHeight: hardware?.height ?? 0)
                    .id(faceKey(m))
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92)).animation(.spring(response: 0.36, dampingFraction: 0.8).delay(0.06)), removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(m == .banner || m == .player ? 0.35 : 0), radius: 18, y: 8)
            .opacity(m == .hidden ? 0 : 1)
            .position(x: g.size.width / 2 + shift, y: top + height / 2)
            .animation(reduce ? .easeInOut(duration: 0.2) : .spring(response: 0.46, dampingFraction: m == .banner || m == .player ? 0.74 : 0.82), value: m)
            .animation(.spring(response: 0.46, dampingFraction: 0.82), value: width)
            .contentShape(Rectangle().size(width: width, height: height).offset(x: (g.size.width - width) / 2 + shift, y: top))
            .onTapGesture { Haptics.tick(); onTap() }
            .gesture(DragGesture(minimumDistance: 12).onEnded { d in
                if d.translation.height < -12 { if hub.banner != nil { hub.dismissBanner() } else { expanded = false } }
                else if d.translation.height > 16, playing, hub.banner == nil { Haptics.soft(); expanded = true }
            })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
        }
        .ignoresSafeArea()
    }

    /// What the island adds on its left and right beside the hardware island.
    private func extras(_ m: Mode) -> (CGFloat, CGFloat) {
        switch m { case .rest: return hub.status?.available == true ? (42, 18) : (38, 18); case .transfer: return (40, 18); default: return (0, 0) }
    }
    /// The island is always black: its colours are the song's own, bright, in light mode too.
    private var bright: Color { t.palette.accent }

    @ViewBuilder private func shape(_ radius: CGFloat) -> some View {
        if hardware != nil { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black) }
        else { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black.opacity(0.001)).glass(RoundedRectangle(cornerRadius: radius, style: .continuous), .island) }
    }
    private func faceKey(_ m: Mode) -> String {
        switch m { case .banner: return "b" + (hub.banner?.id.uuidString ?? ""); case .player: return "p"; case .transfer: return "t"; case .rest: return hub.status?.available == true ? "rm" : "rp"; case .hidden: return "h" }
    }
    private var label: String {
        if let b = hub.banner { return "\(b.title). \(b.detail)" }
        if let s = hub.status, s.available { return "\(s.title) on \(s.pcName)" }
        return hub.pc()?.name ?? "No PC yet"
    }

    @ViewBuilder private func face(_ m: Mode, hardwareHeight: CGFloat) -> some View {
        switch m {
        case .hidden: Color.clear
        case .rest: restFace
        case .transfer: if let tr = latest { transferFace(tr) }
        case .banner: if let b = hub.banner { bannerFace(b, band: hardwareHeight) }
        case .player: if let s = hub.status { IslandPlayer(status: s, band: hardwareHeight) }
        }
    }

    /// Beside the camera: the cover and level bars, or the PC and how well it's reached.
    private var restFace: some View {
        HStack(spacing: 0) {
            if let s = hub.status, s.available {
                CoverImage(image: hub.cover, radius: 7).frame(width: 24, height: 24)
                if hardware == nil { Text(s.title).font(TypeScale.caption).foregroundStyle(.white.opacity(0.86)).lineLimit(1).padding(.leading, 8) }
                Spacer(minLength: 0)
                Equalizer(playing: s.playing, width: hardware != nil ? 10 : 18, height: 12, bars: 3, color: bright)
            } else if let p = hub.pc() {
                Image(systemName: "laptopcomputer").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.online ? bright : .white.opacity(0.45))
                if hardware == nil { Text(p.name).font(TypeScale.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1).padding(.leading, 8) }
                Spacer(minLength: 0)
                if p.online && hub.internet { QualityRing(q: Quality.of(p, t), size: 11, stroke: 2) } else { Circle().fill(p.online ? t.good : .white.opacity(0.4)).frame(width: 7, height: 7) }
            } else {
                Text("No PC yet").font(TypeScale.caption).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, hardware != nil ? 10 : 12).padding(.trailing, hardware != nil ? 5 : 12)
    }
    private func transferFace(_ tr: Transfer) -> some View {
        HStack(spacing: 8) {
            ZStack {
                ProgressRing(fraction: tr.fraction, track: .white.opacity(0.16), color: bright, size: 22, stroke: 2.5)
                Image(systemName: tr.outgoing ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .heavy)).foregroundStyle(bright)
            }
            if hardware == nil { Text(tr.title).font(TypeScale.caption).foregroundStyle(.white).lineLimit(1) }
            Spacer(minLength: 0)
            if hardware == nil { Text("\(Int(tr.fraction * 100))%").font(TypeScale.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75)).contentTransition(.numericText(value: tr.fraction)) }
            else { Text("\(Int(tr.fraction * 100))").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white.opacity(0.8)).frame(width: 13).minimumScaleFactor(0.6) }
        }
        .padding(.leading, hardware != nil ? 9 : 12).padding(.trailing, hardware != nil ? 3 : 12)
    }
    private func bannerFace(_ b: Banner, band: CGFloat) -> some View {
        let tint: Color = { switch b.kind { case .failed: return t.danger; case .received, .sent: return t.good; case .ring: return t.warn; default: return bright } }()
        return HStack(spacing: 12) {
            Image(systemName: b.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 46, height: 46).background(Circle().fill(tint.opacity(0.2)))
                .symbolEffect(.bounce, value: b.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title).font(TypeScale.bodyStrong).foregroundStyle(.white).lineLimit(1)
                if !b.detail.isEmpty { Text(b.detail).font(TypeScale.caption).foregroundStyle(.white.opacity(0.66)).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, band > 0 ? band * 0.72 : 0)
        .frame(maxHeight: .infinity)
    }
}

/// The island opened into the song's card: the cover, the song, where it is, and the controls.
struct IslandPlayer: View {
    let status: PcStatus; let band: CGFloat
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var asked: (Bool, Date)?
    var body: some View {
        let playing = asked.map { Date().timeIntervalSince($0.1) < 1.8 ? $0.0 : status.playing } ?? status.playing
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                CoverImage(image: hub.cover, radius: 16).frame(width: 60, height: 60)
                    .shadow(color: t.palette.accent.opacity(0.4), radius: 10)
                Spacer()
                Equalizer(playing: playing, width: 24, height: 18, color: t.palette.accent).padding(.top, 8)
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("ON \(status.pcName.uppercased())").font(TypeScale.micro).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    Text(status.title).font(TypeScale.bodyStrong).foregroundStyle(.white).lineLimit(1)
                    Text(status.artist.isEmpty ? status.app : status.artist).font(TypeScale.caption).foregroundStyle(.white.opacity(0.66)).lineLimit(1)
                }
                Spacer()
            }
            .padding(.top, 10)
            Ticking(every: 0.5) { now in
                let d = max(0, status.duration), pos = playing ? status.positionNow(now) : status.position
                VStack(spacing: 3) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) { Capsule().fill(.white.opacity(0.16)); Capsule().fill(.white.opacity(0.92)).frame(width: d > 0 ? g.size.width * min(1, pos / d) : 0) }
                    }.frame(height: 4)
                    HStack { Text(clock(pos)); Spacer(); Text(d > 0 ? "-" + clock(d - pos) : "") }.font(TypeScale.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.top, 10)
            HStack {
                Spacer()
                Button { Task { await hub.media(2) } } label: { Image(systemName: "backward.fill").font(.system(size: 24)).frame(width: 50, height: 46) }.disabled(!status.canPrevious)
                Spacer()
                Button { asked = (!playing, Date()); Task { await hub.media(1) } } label: {
                    PlayPause(playing: playing, size: 22, color: .black).frame(width: 52, height: 52).background(Circle().fill(.white))
                }.disabled(!status.canToggle)
                Spacer()
                Button { Task { await hub.media(3) } } label: { Image(systemName: "forward.fill").font(.system(size: 24)).frame(width: 50, height: 46) }.disabled(!status.canNext)
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.92)).buttonStyle(PressStyle()).padding(.top, 4)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)
    }
}

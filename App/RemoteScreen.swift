import IslandKit
import SwiftUI

/// Your PC from your iPhone: what plays there (its cover, where it is, its lyrics, the controls), its sound on a dial, and
/// quick actions (the clipboard, a link, lock, find it, the trackpad, its screen, this iPhone's camera there).
struct RemoteScreen: View {
    var onPair: () -> Void; var onScreen: () -> Void; var onTrackpad: () -> Void; var onLink: () -> Void; var onCamera: () -> Void; var onIsland: () -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    var body: some View {
        if let pc = hub.pc() {
            VStack(spacing: 0) {
                ScreenTitle(title: pc.name, over: pc.online ? "Your PC  ·  \(Quality.of(pc, t).text.lowercased())" : "Your PC  ·  away") { LiveDot(on: pc.online) }
                if let s = hub.status { chips(s).arrive(0) }
                NowPlayingCard(pc: pc).arrive(1)
                if let s = hub.status {
                    SectionLabel(text: "Sound on \(pc.name)")
                    SoundPanel(pc: pc, status: s).arrive(2)
                }
                SectionLabel(text: "Quick actions")
                QuickActions(pc: pc, onScreen: onScreen, onTrackpad: onTrackpad, onLink: onLink, onCamera: onCamera).arrive(3)
            }
        } else { Welcome(onPair: onPair) }
    }
    private func chips(_ s: PcStatus) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if s.batteryPresent && s.battery >= 0 {
                    GlassChip(label: "\(s.battery)%", symbol: s.charging ? "battery.100percent.bolt" : s.battery <= 20 ? "battery.25percent" : "battery.75percent", symbolTint: s.charging ? t.good : s.battery <= 20 ? t.danger : nil)
                }
                if s.cpu >= 0 && s.cpu <= 100 { GlassChip(label: "CPU \(s.cpu)%", symbol: "cpu") { onIsland() } }
                if !s.weather.trimmingCharacters(in: .whitespaces).isEmpty { GlassChip(label: s.weather, symbol: Sky.of(s.weather).symbol) }
                if s.clipboard { GlassChip(label: "Universal clipboard", symbol: "doc.on.clipboard") }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden).scrollClipDisabled()
        .padding(.bottom, 14)
    }
}

/// Before any PC: what the app does, and how to pair.
struct Welcome: View {
    var onPair: () -> Void
    @Environment(\.tokens) private var t
    @State private var float = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LinearGradient(colors: [t.accent, t.accent2], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 36, height: 36)
                Equalizer(playing: true, width: 44, height: 24, bars: 5)
            }
            .frame(width: 210, height: 62)
            .background(Capsule().fill(.black))
            .shadow(color: t.accent.opacity(0.4), radius: 24, y: 10)
            .offset(y: float ? -6 : 4)
            .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: float)
            .onAppear { float = true }
            .padding(.top, 52)
            Text("Your island, in your hand").font(TypeScale.title).foregroundStyle(t.text).multilineTextAlignment(.center).padding(.top, 38)
            Text("Control what plays on your PC, send photos and files both ways, see its screen and use it from here, and find this iPhone from your PC.")
                .font(TypeScale.body).foregroundStyle(t.muted).multilineTextAlignment(.center).padding(.horizontal, 8).padding(.top, 10)
            GlassButton(prominent: true, action: onPair) { Image(systemName: "qrcode.viewfinder"); Text("Pair with your PC").font(TypeScale.bodyStrong) }.padding(.top, 30)
            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ON YOUR PC").font(TypeScale.micro).tracking(0.8).foregroundStyle(t.muted)
                    ForEach(Array(["Open Arnav Island’s Settings › Privacy & productivity", "Turn on “Share with my PCs” and “Reach my PCs anywhere”", "Open the island’s Shelf › Nearby › Pair with a code, then scan its QR code with this iPhone’s camera"].enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(i + 1)").font(TypeScale.caption).foregroundStyle(t.accent).frame(width: 24, height: 24).background(Circle().fill(t.accent.opacity(0.2)))
                            Text(s).font(TypeScale.body).foregroundStyle(t.text)
                        }
                    }
                }
            }
            .padding(.top, 26)
        }
        .arrive()
    }
}

/**
 * Now playing on the PC. The cover shrinks back a little while paused, leans with the iPhone and lifts off the card over a
 * shadow that slides the other way, with a glint that crosses it when the song changes; tapped, it turns over to the
 * song's lyrics. The play button morphs; the scrubber answers the finger at once, ticking at each lyric line.
 */
struct NowPlayingCard: View {
    let pc: PeerView
    private var hub: Hub { Hub.shared }
    private var tilt: Tilt { Tilt.shared }
    @Environment(\.tokens) private var t
    @State private var playingAsked: (Bool, Date)?
    @State private var seekAsked: (Double, Date)?
    @State private var flipped = false
    @State private var scrubbing: Double?
    @State private var glint = false

    var body: some View {
        if let s = hub.status, s.available { card(s) }
        else {
            EmptyCard(symbol: "music.note", title: hub.status == nil ? (hub.statusError ?? "Connecting to \(pc.name)…") : "Nothing playing",
                      detail: hub.status == nil ? "The remote shows what plays on your PC" : "Play something on \(pc.name) and it shows here")
        }
    }

    private func card(_ s: PcStatus) -> some View {
        let playing = playingAsked.flatMap { Date().timeIntervalSince($0.1) < 1.8 ? $0.0 : nil } ?? s.playing
        return GlassPanel(padding: 20) {
            VStack(spacing: 0) {
                cover(s, playing: playing)
                Marquee(text: s.title).padding(.top, 22)
                Text([s.artist, s.app].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "  ·  ")).font(TypeScale.body).foregroundStyle(t.muted).lineLimit(1).padding(.top, 2)
                TimelineView(.periodic(from: .now, by: playing ? 0.25 : 1)) { ctx in
                    let d = max(0, s.duration)
                    let pos = seekAsked.flatMap { ctx.date.timeIntervalSince($0.1) < 2.5 ? $0.0 : nil } ?? (playingAsked != nil && !playing ? s.position : s.positionNow(ctx.date))
                    let shown = scrubbing.map { $0 * d } ?? pos
                    VStack(spacing: 2) {
                        GlassSlider(value: d > 0 ? pos / d : 0, onChange: { scrubbing = $0 }, onDone: { f in scrubbing = nil; if d > 0 && s.canSeek { seekAsked = (f * d, Date()); Task { await hub.seek(to: f * d) } } },
                                    color: t.text.opacity(0.9), height: 6, ticks: ticks(s), label: "Position in \(s.title)")
                        HStack { Text(clock(shown)); Spacer(); Text(d > 0 ? "-" + clock(d - shown) : "") }.font(TypeScale.caption.monospacedDigit()).foregroundStyle(t.muted)
                    }
                }
                .padding(.top, 16)
                HStack {
                    GlassIconButton(symbol: "backward.fill", label: "Previous", size: 60, iconSize: 26) { Task { await hub.media(2) } }.disabled(!s.canPrevious)
                    Spacer()
                    Button { Haptics.tap(); playingAsked = (!playing, Date()); Task { await hub.command(Proto.cmdMedia, [1]); try? await Task.sleep(for: .milliseconds(300)); await hub.refreshStatus() } } label: {
                        PlayPause(playing: playing, size: 34, color: t.accent).frame(width: 84, height: 84).glass(Circle(), .control, tint: t.accent, interactive: true)
                    }
                    .buttonStyle(PressStyle()).disabled(!s.canToggle).accessibilityLabel(playing ? "Pause" : "Play")
                    Spacer()
                    GlassIconButton(symbol: "forward.fill", label: "Next", size: 60, iconSize: 26) { Task { await hub.media(3) } }.disabled(!s.canNext)
                }
                .padding(.horizontal, 12).padding(.top, 10)
                if pc.revision >= 3 {
                    GlassChip(label: flipped ? "Cover" : "Lyrics", symbol: flipped ? "opticaldisc" : "quote.bubble", selected: flipped) { withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) { flipped.toggle() } }
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: s.title) { _, _ in glint = false; withAnimation(.easeInOut(duration: 1.1).delay(0.2)) { glint = true } }
    }

    private func cover(_ s: PcStatus, playing: Bool) -> some View {
        GeometryReader { g in
            let side = min(g.size.width, 300)
            ZStack {
                // The shadow slides the other way from the lean, coloured by the cover.
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(t.accent.opacity(0.45)).frame(width: side * 0.86, height: side * 0.86).blur(radius: 26)
                    .offset(x: -tilt.x * 14, y: 18 - tilt.y * 10)
                ZStack {
                    // Front: the cover, with a glint.
                    CoverImage(image: hub.cover, radius: 26)
                        .overlay {
                            LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .frame(width: side * 0.5).offset(x: glint ? side : -side).blendMode(.plusLighter)
                                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        }
                        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 0.8) }
                        .opacity(flipped ? 0 : 1)
                    // Back: the lyrics, over the cover blurred.
                    ZStack {
                        CoverImage(image: hub.cover, radius: 26).blur(radius: 28).overlay(Color.black.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        if flipped { LyricsView(lyrics: hub.lyrics, position: { hub.position() }, playing: playing, pcName: pc.name) { time in Task { await hub.seek(to: time) } } }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
                    .opacity(flipped ? 1 : 0)
                }
                .frame(width: side, height: side)
                .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (0, 1, 0), perspective: 0.5)
                .rotation3DEffect(.degrees(tilt.x * 9), axis: (0, 1, 0), perspective: 0.6)
                .rotation3DEffect(.degrees(-tilt.y * 7), axis: (1, 0, 0), perspective: 0.6)
                .scaleEffect(playing ? 1 : 0.9)
                .animation(.spring(response: 0.55, dampingFraction: 0.72), value: playing)
                .onTapGesture { if pc.revision >= 3 { Haptics.tick(); withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) { flipped.toggle() } } }
                .accessibilityLabel(flipped ? "Lyrics. Tap to show the cover" : "Cover of \(s.title). Tap for the lyrics")
                .accessibilityAddTraits(.isButton)
            }
            .frame(width: g.size.width, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 300)
    }
    private func ticks(_ s: PcStatus) -> [Double]? {
        guard let l = hub.lyrics, l.state == 2, s.duration > 0, LyricsView.synced(l.lines) else { return nil }
        return l.lines.map { $0.time / s.duration }
    }
}

/// The PC's sound: a dial to twist (a tick at every 5%), its middle to mute, steps, and a few levels a tap away.
struct SoundPanel: View {
    let pc: PeerView; let status: PcStatus
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var asked: (Double, Date)?
    @State private var sentAt = Date.distantPast
    var body: some View {
        let volume = asked.flatMap { Date().timeIntervalSince($0.1) < 1.6 ? $0.0 : nil } ?? Double(status.volume) / 100
        let pct = Int(volume * 100 + 0.5)
        GlassPanel(padding: 14) {
            HStack(spacing: 14) {
                VolumeDial(value: volume, muted: status.muted, onChange: { send($0, final: false) }, onDone: { send($0, final: true) }, onMute: { Task { await hub.toggleMute() } }, size: 168, label: "Volume on \(pc.name)")
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.muted ? "Muted" : "\(pct)%").font(TypeScale.headline.monospacedDigit()).foregroundStyle(t.text).contentTransition(.numericText(value: Double(pct)))
                    Text("Twist the dial, or step it; tap its middle to mute").font(TypeScale.caption).foregroundStyle(t.muted)
                    HStack(spacing: 10) {
                        StepButton(symbol: "minus", label: "Volume down on \(pc.name)") { send(Double(max(0, pct - 5)) / 100, final: true) }
                        StepButton(symbol: "plus", label: "Volume up on \(pc.name)") { send(Double(min(100, pct + 5)) / 100, final: true) }
                    }
                    .padding(.top, 10)
                    HStack(spacing: 6) { ForEach([25, 50, 75], id: \.self) { level in GlassChip(label: "\(level)", selected: !status.muted && pct == level) { send(Double(level) / 100, final: true) } } }
                        .padding(.top, 10)
                }
            }
        }
    }
    private func send(_ v: Double, final: Bool) {
        asked = (v, Date())
        if final || Date().timeIntervalSince(sentAt) > 0.11 { sentAt = Date(); Task { await hub.setVolume(Int(v * 100 + 0.5)) } }
    }
}

struct QuickActions: View {
    let pc: PeerView
    var onScreen: () -> Void; var onTrackpad: () -> Void; var onLink: () -> Void; var onCamera: () -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            GlassTile(symbol: "doc.on.clipboard", title: "Paste on PC", detail: "Your iPhone’s clipboard, there") {
                guard let text = UIPasteboard.general.string, !text.isEmpty else { hub.show(Banner(kind: .info, title: "Nothing to paste", detail: "Copy some text first")); return }
                Task { await hub.clipboardToPC(text) }
            }
            GlassTile(symbol: "doc.on.doc", title: "Copy from PC", detail: "\(pc.name)’s clipboard, here") { Task { await hub.clipboardFromPC() } }
            GlassTile(symbol: "globe", title: "Open a link", detail: "In \(pc.name)’s browser", tint: t.accent2, action: onLink)
            GlassTile(symbol: "lock.fill", title: "Lock \(pc.name)", detail: "Right away", tint: t.warn) { Task { if await hub.lockPC() { Haptics.success(); hub.show(Banner(kind: .info, title: "Locked \(pc.name)")) } } }
            GlassTile(symbol: "bell.and.waves.left.and.right", title: "Find \(pc.name)", detail: "It chimes and lights up", tint: t.warn) { Task { await hub.ringPC() } }
            GlassTile(symbol: "rectangle.and.hand.point.up.left", title: "Trackpad", detail: "And the keyboard", tint: t.accent2) { if pc.revision < 3 && pc.online { update("The trackpad", "0.20") } else { onTrackpad() } }
            GlassTile(symbol: "display", title: "\(pc.name)’s screen", detail: "Here, and touch it") { if pc.revision < 7 && pc.online { update("Its screen", "0.24") } else { onScreen() } }
            GlassTile(symbol: "camera.fill", title: "Camera on \(pc.name)", detail: "This iPhone’s camera, in a window there", tint: t.accent2) { if pc.revision < 7 && pc.online { update("The camera there", "0.24") } else { onCamera() } }
        }
    }
    private func update(_ what: String, _ v: String) { hub.show(Banner(kind: .failed, title: "Update Arnav Island on \(pc.name)", detail: "\(what) needs version \(v) or later")) }
}

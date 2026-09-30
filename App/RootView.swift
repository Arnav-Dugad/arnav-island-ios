import IslandKit
import SwiftUI

/// The tabs, as on Android: swiped between, under a floating glass bar.
enum Tab: Int, CaseIterable, Identifiable {
    case remote, island, send, shelf, devices
    var id: Int { rawValue }
    var title: String { ["Remote", "Island", "Send", "Shelf", "Devices"][rawValue] }
    var symbol: String { ["laptopcomputer", "square.grid.2x2.fill", "paperplane.fill", "tray.full.fill", "iphone.gen3.radiowaves.left.and.right"][rawValue] }
}

/// What the app shows over its tabs.
enum Sheet: Identifiable, Equatable {
    case pair(PairStart), offer(Int), music(Int), page, photoAsk, trackpad, link, received([String]), clip(String), share([URL]), islandSettings(Int), about, whatsNew, keys, shortcuts
    var id: String {
        switch self {
        case .pair(let s): return "pair\(s)"; case .offer(let t): return "offer\(t)"; case .music(let t): return "music\(t)"; case .page: return "page"; case .photoAsk: return "photo"
        case .trackpad: return "trackpad"; case .link: return "link"; case .received(let f): return "received\(f.count)"; case .clip: return "clip"; case .share(let u): return "share\(u.count)"
        case .islandSettings(let s): return "settings\(s)"; case .about: return "about"; case .whatsNew: return "whatsnew"; case .keys: return "keys"; case .shortcuts: return "shortcuts"
        }
    }
    /// What comes to this iPhone (it may push aside what you opened).
    var incoming: Bool { switch self { case .offer, .music, .page, .photoAsk: return true; default: return false } }
}
enum PairStart: String { case scan, type, finding }

struct RootView: View {
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.scenePhase) private var phase
    @State private var page: Tab? = Demo.argument("tab").flatMap(Int.init).flatMap(Tab.init(rawValue:)) ?? .remote
    @State private var pagePos: CGFloat = 0
    @State private var sheet: Sheet?
    @State private var screenOpen = false
    @State private var cameraOpen = false
    @State private var islandOpen = false
    @State private var safeTop: CGFloat = 0
    @State private var polling: Task<Void, Never>?

    var body: some View {
        GeometryReader { g in
            let hardware = HardwareIsland.of(safeTop: g.safeAreaInsets.top)
            ZStack {
                Ambient(playing: hub.status?.playing == true, still: sheet != nil || screenOpen)
                pager(g)
                LinearGradient(colors: [t.deep.opacity(t.dark ? 0.7 : 0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: g.safeAreaInsets.top + 24).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea().allowsHitTesting(false)
                if hub.prefs.weather { WeatherGlass(sky: Sky.of(hub.status?.weather ?? ""), active: phase == .active && !screenOpen && sheet == nil) }
                HandoffParticles(transfers: Array(hub.transfers.values))
                if islandOpen { Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { withAnimation { islandOpen = false } } }
                VStack(spacing: 10) {
                    Spacer()
                    if Player.shared.active { PlayingHereBar().transition(.move(edge: .bottom).combined(with: .opacity)) }
                    TabBar(selected: page ?? .remote, position: pagePos) { tab in withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { page = tab } }
                }
                .padding(.horizontal, 16).padding(.bottom, g.safeAreaInsets.bottom > 0 ? max(14, g.safeAreaInsets.bottom - 14) : 12)
                .ignoresSafeArea(edges: .bottom)
                MiniIsland(hardware: hardware, safeTop: g.safeAreaInsets.top, expanded: $islandOpen) { tapIsland() }
                if let name = hub.ringing { RingOverlay(name: name).transition(.opacity).zIndex(5) }
            }
            .onAppear { safeTop = g.safeAreaInsets.top }
        }
        .background { KeyShortcuts(page: $page, onTrackpad: { handle("trackpad") }, onScreen: { openScreen() }) }
        .sheet(item: $sheet, onDismiss: nextIncoming) { s in sheetView(s).environment(hub).environment(\.tokens, t) }
        .fullScreenCover(isPresented: $screenOpen) { PcScreenView().environment(hub).environment(\.tokens, t) }
        .fullScreenCover(isPresented: $cameraOpen) { CameraToPCView().environment(hub).environment(\.tokens, t) }
        .onChange(of: hub.request) { _, r in if let r { hub.request = nil; handle(r) } }
        .onChange(of: hub.offers.first?.transfer) { _, _ in nextIncoming() }
        .onChange(of: hub.music?.transfer) { _, _ in nextIncoming() }
        .onChange(of: hub.page?.id) { _, _ in nextIncoming() }
        .onChange(of: hub.pairCode) { _, c in if c != nil, sheet == nil || sheet?.incoming == true { sheet = .pair(.finding) } }
        .onChange(of: hub.ringing) { _, r in if r != nil { sheet = nil; screenOpen = false } }
        .onChange(of: hub.status?.available) { _, a in if a != true { islandOpen = false } }
        .onChange(of: pollKey) { _, _ in startPolling() }
        .onChange(of: phase) { _, _ in startPolling() }
        .onAppear { startPolling(); nextIncoming() }
    }

    // ---- the pages ----
    private func pager(_ g: GeometryProxy) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Tab.allCases) { tab in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) { content(tab) }
                            .padding(.horizontal, 16).padding(.top, (HardwareIsland.of(safeTop: g.safeAreaInsets.top) != nil ? 8 : 44)).padding(.bottom, 130)
                            .frame(maxWidth: 640)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .containerRelativeFrame(.horizontal)
                    .id(tab)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $page)
        .onScrollGeometryChange(for: CGFloat.self) { geo in geo.contentOffset.x / max(1, geo.containerSize.width) } action: { _, v in pagePos = v }
        .onChange(of: page) { _, _ in Haptics.tick() }
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func content(_ tab: Tab) -> some View {
        switch tab {
        case .remote: RemoteScreen(onPair: { sheet = .pair(.scan) }, onScreen: { openScreen() }, onTrackpad: { sheet = .trackpad }, onLink: { sheet = .link }, onCamera: { openCamera() }, onIsland: { withAnimation { page = .island } })
        case .island: IslandScreen(shown: page == .island, onPair: { sheet = .pair(.scan) }, onSettings: { sheet = .islandSettings($0) })
        case .send: SendScreen(onPair: { sheet = .pair(.scan) }, onOpen: { sheet = .received($0) }, onShare: { sheet = .share($0) })
        case .shelf: ShelfScreen(shown: page == .shelf, onPair: { sheet = .pair(.scan) })
        case .devices: DevicesScreen(onPair: { sheet = .pair(.type) }, onScan: { sheet = .pair(.scan) }, onSheet: { sheet = $0 })
        }
    }

    @ViewBuilder private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .pair(let start): PairSheet(start: start)
        case .offer(let t): OfferSheet(transfer: t)
        case .music(let t): MusicSheet(transfer: t)
        case .page: PageSheet()
        case .photoAsk: PhotoAskSheet(onCamera: { sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { CameraCapture.present() } })
        case .trackpad: TrackpadSheet()
        case .link: LinkSheet()
        case .received(let files): ReceivedSheet(files: files)
        case .clip(let text): ClipSheet(text: text)
        case .share(let urls): ShareToPCSheet(files: urls)
        case .islandSettings(let section): IslandSettingsSheet(section: section)
        case .about: AboutSheet()
        case .whatsNew: WhatsNewSheet()
        case .keys: KeysSheet()
        case .shortcuts: ShortcutsSheet()
        }
    }

    /// What arrived and waits to be answered, shown next (one at a time).
    private func nextIncoming() {
        guard sheet == nil || sheet?.incoming == false && isQuiet(sheet) else { return }
        if let o = hub.offers.first { sheet = .offer(o.transfer) }
        else if let m = hub.music, !m.fetching { sheet = .music(m.transfer) }
        else if hub.page != nil { sheet = .page }
    }
    /// Sheets you opened that something arriving may replace (not the pairing or the trackpad in use).
    private func isQuiet(_ s: Sheet?) -> Bool { switch s { case .pair, .trackpad, .share: return false; default: return true } }

    private func tapIsland() {
        if islandOpen { withAnimation { islandOpen = false } }
        else if hub.banner != nil { hub.dismissBanner() }
        else if hub.status?.available == true { Haptics.soft(); withAnimation { islandOpen = true } }
        else { withAnimation { page = hub.transfers.isEmpty ? .remote : .send } }
    }
    private func openScreen() { guard hub.pc() != nil else { sheet = .pair(.scan); return }; sheet = nil; screenOpen = true }
    private func openCamera() { guard hub.pc() != nil else { sheet = .pair(.scan); return }; sheet = nil; cameraOpen = true }
    private func handle(_ r: String) {
        switch r {
        case "remote": withAnimation { page = .remote }
        case "island": withAnimation { page = .island }
        case "send": withAnimation { page = .send }
        case "shelf": withAnimation { page = .shelf }
        case "devices": withAnimation { page = .devices }
        case "screen": openScreen()
        case "trackpad": if hub.pc() != nil { sheet = .trackpad } else { sheet = .pair(.scan) }
        case "camera": if sheet != nil { sheet = .photoAsk } else { CameraCapture.present() }
        case "cameraLive": openCamera()
        case "pair": sheet = .pair(.scan)
        case "pairing": sheet = .pair(.finding)
        case "page": if hub.page != nil { sheet = .page }
        case "link": sheet = .link
        case "ring": Ringer.shared.stop()
        case "player": if hub.status?.available == true { withAnimation { islandOpen = true } }
        default: break
        }
    }

    // ---- the remote's status while the app is on screen: every second while music plays, a little less often otherwise ----
    private var pollKey: String { "\(hub.pc()?.id ?? "")|\(hub.pc()?.online == true)" }
    private func startPolling() {
        polling?.cancel()
        guard phase == .active, let p = hub.pc(), p.online else { return }
        polling = Task {
            while !Task.isCancelled {
                await hub.refreshStatus()
                try? await Task.sleep(for: .milliseconds(hub.status?.playing == true ? 1000 : 2000))
            }
        }
    }
}

/// The floating glass tab bar. Its lit pill follows your finger as you swipe between pages and settles with a spring.
struct TabBar: View {
    let selected: Tab; let position: CGFloat
    let onSelect: (Tab) -> Void
    @Environment(\.tokens) private var t
    @Namespace private var ns
    var body: some View {
        GeometryReader { g in
            let w = g.size.width / CGFloat(Tab.allCases.count)
            ZStack(alignment: .leading) {
                Capsule().fill(t.accent.opacity(t.dark ? 0.22 : 0.18))
                    .overlay(Capsule().stroke(t.accent.opacity(0.35), lineWidth: 0.8))
                    .frame(width: w - 8, height: g.size.height - 10)
                    .offset(x: max(0, min(CGFloat(Tab.allCases.count - 1), position)) * w + 4)
                    .shadow(color: t.accent.opacity(0.35), radius: 10)
                HStack(spacing: 0) {
                    ForEach(Tab.allCases) { tab in
                        let near = max(0, 1 - abs(position - CGFloat(tab.rawValue)))
                        Button { Haptics.tick(); onSelect(tab) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: tab.symbol).font(.system(size: 19, weight: .semibold)).symbolEffect(.bounce, value: selected == tab)
                                    .scaleEffect(1 + near * 0.08)
                                Text(tab.title).font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(near > 0.5 ? t.accent : t.muted)
                            .frame(width: w, height: g.size.height)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle(scale: 0.9))
                        .accessibilityLabel(tab.title).accessibilityAddTraits(selected == tab ? [.isSelected, .isButton] : .isButton)
                    }
                }
            }
        }
        .frame(height: 64)
        .glass(Capsule(), .bar, interactive: true)
        .frame(maxWidth: 520)
    }
}

/// A PC's song playing on this iPhone: its cover, play and pause, and hand it back.
struct PlayingHereBar: View {
    @Environment(\.tokens) private var t
    var body: some View {
        let p = Player.shared
        if let m = p.music {
            HStack(spacing: 12) {
                CoverImage(image: p.artwork, radius: 10).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.title).font(TypeScale.bodyStrong).foregroundStyle(t.text).lineLimit(1)
                    Text("From \(p.pcName ?? "your PC")  ·  \(clock(p.position))").font(TypeScale.caption.monospacedDigit()).foregroundStyle(t.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                GlassIconButton(symbol: p.playing ? "pause.fill" : "play.fill", label: p.playing ? "Pause" : "Play", size: 40, iconSize: 16) { p.toggle() }
                GlassIconButton(symbol: "laptopcomputer.and.arrow.down", label: "Hand back to your PC", size: 40, iconSize: 16, prominent: true) { p.handBack() }
                GlassIconButton(symbol: "xmark", label: "Stop", size: 40, iconSize: 14) { p.stop() }
            }
            .padding(10)
            .glass(RoundedRectangle(cornerRadius: 26, style: .continuous), .bar)
            .frame(maxWidth: 520)
        }
    }
}

/// Your PC is looking for this iPhone: the screen glows and pulses in time with the chime until it's found.
struct RingOverlay: View {
    let name: String
    @Environment(\.tokens) private var t
    @State private var pulse = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            RadialGradient(colors: [t.warn.opacity(pulse ? 0.55 : 0.2), .clear], center: .center, startRadius: 10, endRadius: pulse ? 420 : 260).ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    ForEach(0..<3) { i in Circle().stroke(t.warn.opacity(0.5), lineWidth: 2).frame(width: 130, height: 130).scaleEffect(pulse ? 2.2 + Double(i) * 0.5 : 1).opacity(pulse ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(i) * 0.4), value: pulse) }
                    Image(systemName: "bell.and.waves.left.and.right.fill").font(.system(size: 54, weight: .semibold)).foregroundStyle(t.warn)
                        .symbolEffect(.wiggle.byLayer, options: .repeating)
                        .frame(width: 130, height: 130).glass(Circle(), .control, tint: t.warn)
                }
                Text("\(name) is looking for this iPhone").font(TypeScale.title).foregroundStyle(.white).multilineTextAlignment(.center)
                Text("Here it is!").font(TypeScale.body).foregroundStyle(.white.opacity(0.7))
                GlassButton(prominent: true, action: { Ringer.shared.stop() }) { Image(systemName: "hand.raised.fill"); Text("Found it").font(TypeScale.bodyStrong) }
            }
            .padding(32)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
    }
}

/// With a keyboard (an iPad's, or one paired to the iPhone): space plays, arrows skip and change the volume, ⌘1–⌘5 switch
/// tabs, T opens the trackpad and S the PC's screen.
struct KeyShortcuts: View {
    @Binding var page: Tab?
    var onTrackpad: () -> Void; var onScreen: () -> Void
    private var hub: Hub { Hub.shared }
    var body: some View {
        ZStack {
            Button("Play or pause") { Task { await hub.media(1) } }.keyboardShortcut(.space, modifiers: [])
            Button("Previous") { Task { await hub.media(2) } }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next") { Task { await hub.media(3) } }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Volume up") { Task { await hub.setVolume((hub.status?.volume ?? 50) + 5) } }.keyboardShortcut(.upArrow, modifiers: [])
            Button("Volume down") { Task { await hub.setVolume((hub.status?.volume ?? 50) - 5) } }.keyboardShortcut(.downArrow, modifiers: [])
            Button("Mute") { Task { await hub.toggleMute() } }.keyboardShortcut("m", modifiers: [])
            Button("Trackpad", action: onTrackpad).keyboardShortcut("t", modifiers: [])
            Button("Your PC's screen", action: onScreen).keyboardShortcut("s", modifiers: [])
            ForEach(Tab.allCases) { tab in Button(tab.title) { withAnimation { page = tab } }.keyboardShortcut(KeyEquivalent(Character(String(tab.rawValue + 1))), modifiers: .command) }
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }
}

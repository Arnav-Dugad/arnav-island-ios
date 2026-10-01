import IslandKit
import QuickLook
import SwiftUI
import WebKit

/// A sheet's content, centred, with the app's glass behind (iOS 26 makes the sheet itself Liquid Glass).
struct SheetBody<Content: View>: View {
    var detents: Set<PresentationDetent> = [.medium, .large]
    /// A picture to glow behind a full-height sheet (a song's cover); else the app's own light.
    var backdrop: UIImage? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        let sheet = ScrollView { VStack(spacing: 0) { content() }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 20).frame(maxWidth: 520).frame(maxWidth: .infinity) }
            .scrollBounceBehavior(.basedOnSize)
            .presentationDetents(detents).presentationDragIndicator(.visible)
            .presentationCornerRadius(38)
        // Half-height sheets are Liquid Glass by themselves; full-height ones get the app's light behind them.
        if detents == [.large] { sheet.presentationBackground { SheetBackdrop(image: backdrop) } } else { sheet }
    }
}

/// Behind a full-height sheet: the app's slow light, or a picture (a song's cover) blurred into a glow.
struct SheetBackdrop: View {
    var image: UIImage? = nil
    @Environment(\.tokens) private var t
    var body: some View {
        ZStack {
            Ambient(playing: false, still: true)
            if let image {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: 70).opacity(0.75).ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(t.dark ? 0.25 : 0.05), .black.opacity(t.dark ? 0.6 : 0.2)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            }
        }
    }
}

/// Files a PC offers: what, how much, from whom; Accept or Decline.
struct OfferSheet: View {
    let transfer: Int
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SheetBody(detents: [.height(400)]) {
            if let o = hub.offers.first(where: { $0.transfer == transfer }) {
                Image(systemName: o.folder ? "folder.fill" : symbolFor(o.title)).font(.system(size: 32, weight: .semibold)).foregroundStyle(t.good)
                    .frame(width: 74, height: 74).background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(t.good.opacity(0.18)))
                    .symbolEffect(.bounce, options: .nonRepeating)
                Text("\(o.name) is sending").font(TypeScale.title).foregroundStyle(t.text).multilineTextAlignment(.center).padding(.top, 14)
                Text(o.title).font(TypeScale.bodyStrong).foregroundStyle(t.text).lineLimit(2).multilineTextAlignment(.center).padding(.top, 4)
                Text("\(o.count > 1 ? "\(o.count) files  ·  " : "")\(sizeText(o.size))  ·  into Files › Arnav Island").font(TypeScale.caption).foregroundStyle(t.muted).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    GlassButton(wide: true, action: { hub.answer(o, accept: false); dismiss() }) { Text("Decline").font(TypeScale.bodyStrong) }
                    GlassButton(prominent: true, wide: true, action: { Haptics.success(); hub.answer(o, accept: true); dismiss() }) { Text("Accept").font(TypeScale.bodyStrong) }
                }
                .padding(.top, 24)
            }
        }
        .onChange(of: hub.offers.contains { $0.transfer == transfer }) { _, still in if !still { dismiss() } }
        .onDisappear { if let o = hub.offers.first(where: { $0.transfer == transfer }) { hub.answer(o, accept: false) } }
    }
}

/// Music a PC offers to continue here: its cover (with its own light beneath), where it is, Play here or Not now.
struct MusicSheet: View {
    let transfer: Int
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SheetBody(detents: [.large], backdrop: hub.music?.music.cover.flatMap { UIImage(data: Data($0)) }) {
            if let m = hub.music, m.transfer == transfer {
                let cover = m.music.cover.flatMap { UIImage(data: Data($0)) }
                let palette = cover.flatMap(Art.palette)
                ZStack {
                    Circle().fill((palette?.accent ?? t.accent).opacity(0.55)).frame(width: 200, height: 200).blur(radius: 50)
                    CoverImage(image: cover, radius: 28).frame(width: 190, height: 190).shadow(color: .black.opacity(0.35), radius: 20, y: 12)
                }
                .frame(height: 230)
                Text("Continue on this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")?").font(TypeScale.caption).foregroundStyle(t.muted).padding(.top, 14)
                Text(m.music.title).font(TypeScale.title).foregroundStyle(t.text).multilineTextAlignment(.center).lineLimit(2)
                Text([m.music.artist.isEmpty ? nil : m.music.artist, "from \(m.name)", m.music.duration > 0 ? "at \(clock(m.music.position)) of \(clock(m.music.duration))" : nil].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(TypeScale.caption).foregroundStyle(t.muted).multilineTextAlignment(.center)
                if m.fetching {
                    let moving = hub.transfers[m.transfer]
                    HStack(spacing: 10) { ProgressRing(fraction: moving?.fraction ?? 0, size: 28, stroke: 3); Text("Bringing the song over… \(Int((moving?.fraction ?? 0) * 100))%").font(TypeScale.body).foregroundStyle(t.text).contentTransition(.numericText()) }
                        .padding(.top, 24)
                } else {
                    HStack(spacing: 12) {
                        GlassButton(wide: true, action: { hub.answerMusic(m, play: false); dismiss() }) { Text("Not now").font(TypeScale.bodyStrong) }
                        GlassButton(prominent: true, wide: true, action: { Haptics.success(); hub.answerMusic(m, play: true); if m.music.fileSize <= 0 { dismiss() } }) { Image(systemName: "play.fill"); Text("Play here").font(TypeScale.bodyStrong) }
                    }
                    .padding(.top, 24)
                    if m.music.fileSize <= 0 { Text("Your PC plays it from an app, so it continues in \(m.music.app.localizedCaseInsensitiveContains("spotify") ? "Spotify" : m.music.app.localizedCaseInsensitiveContains("youtube") ? "YouTube Music" : "Apple Music") here").font(TypeScale.caption).foregroundStyle(t.faint).multilineTextAlignment(.center).padding(.top, 12) }
                    else { Text("The song comes over and plays here from where it was, with AirPlay and your Lock Screen").font(TypeScale.caption).foregroundStyle(t.faint).multilineTextAlignment(.center).padding(.top, 12) }
                }
            }
        }
        .onChange(of: hub.music?.transfer) { _, now in if now != transfer { dismiss() } }
        .onChange(of: Player.shared.active) { _, a in if a { dismiss() } }
        .onDisappear { if let m = hub.music, m.transfer == transfer, !m.fetching { hub.answerMusic(m, play: false) } }
    }
}

/// A link to open in the PC's browser: typed, or already on the clipboard.
struct LinkSheet: View {
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        SheetBody(detents: [.height(300)]) {
            Text("Open on \(hub.pc()?.name ?? "your PC")").font(TypeScale.title).foregroundStyle(t.text).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                TextField("A web address", text: $text).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go).focused($focused).onSubmit(go)
                PasteButton(payloadType: String.self) { s in if let first = s.first { text = first.trimmingCharacters(in: .whitespacesAndNewlines) } }
                    .labelStyle(.iconOnly).buttonBorderShape(.circle).tint(t.accent)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .glassCapsule(.control, interactive: false)
            .padding(.top, 16)
            GlassButton(prominent: true, wide: true, action: go) { Image(systemName: "globe"); Text("Open").font(TypeScale.bodyStrong) }.padding(.top, 16).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
    }
    private func go() {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !s.isEmpty else { return }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        Task { if await hub.openOnPC(url) { Haptics.success(); hub.show(Banner(kind: .page, title: "Opened on \(hub.pc()?.name ?? "your PC")", detail: String(s.prefix(60)))); dismiss() } }
    }
}

/// A web page your PC handed over, open here at the same place, in a reader; Continue on your PC hands it back where
/// you've got to.
struct PageSheet: View {
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss
    @State private var scroll = 0.0
    @State private var title = ""
    var body: some View {
        if let p = hub.page {
            NavigationStack {
                PageReader(url: p.url, start: p.scroll, scroll: $scroll, title: $title)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(title.isEmpty ? (p.title.isEmpty ? (p.url.host ?? "A page") : p.title) : title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Done") { hub.page = nil; dismiss() } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("Open in Safari", systemImage: "safari") { UIApplication.shared.open(p.url); hub.page = nil; dismiss() }
                                Button("Copy the link", systemImage: "link") { UIPasteboard.general.url = p.url; hub.show(Banner(kind: .clipboard, title: "Link copied")) }
                                ShareLink(item: p.url) { Label("Share", systemImage: "square.and.arrow.up") }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                        ToolbarItem(placement: .bottomBar) {
                            Button { Task { if await hub.pageToPC(p.url, title: title.isEmpty ? p.title : title, scroll: scroll) { hub.page = nil; dismiss() } } } label: {
                                Label("Continue on \(p.from)  ·  \(Int(scroll * 100))%", systemImage: "laptopcomputer.and.arrow.down").font(TypeScale.bodyStrong)
                            }
                        }
                    }
            }
            .presentationDetents([.large])
            .onDisappear { hub.page = nil }
        }
    }
}
/// WebKit, scrolled to where the PC was once the page has laid out, and telling how far down it is.
struct PageReader: UIViewRepresentable {
    let url: URL; let start: Double
    @Binding var scroll: Double; @Binding var title: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); c.defaultWebpagePreferences.preferredContentMode = .mobile
        let w = WKWebView(frame: .zero, configuration: c); w.navigationDelegate = context.coordinator; w.scrollView.delegate = context.coordinator
        w.allowsBackForwardNavigationGestures = true; w.load(URLRequest(url: url)); context.coordinator.web = w
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        let parent: PageReader; weak var web: WKWebView?; private var placed = false
        init(_ p: PageReader) { parent = p }
        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            parent.title = w.title ?? ""
            guard !placed, parent.start > 0.01 else { return }; placed = true
            // Pages keep growing as they load: placed now, and again a moment later.
            for delay in [0.1, 0.8, 1.8] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.place() } }
        }
        private func place() {
            guard let w = web else { return }
            let s = w.scrollView, h = s.contentSize.height - s.bounds.height + s.adjustedContentInset.bottom
            guard h > 0 else { return }
            s.setContentOffset(CGPoint(x: 0, y: max(-s.adjustedContentInset.top, h * parent.start)), animated: true)
        }
        func scrollViewDidScroll(_ s: UIScrollView) {
            let h = s.contentSize.height - s.bounds.height; guard h > 0 else { return }
            parent.scroll = max(0, min(1, (s.contentOffset.y + s.adjustedContentInset.top) / h))
        }
    }
}

/// A PC asks for a photo while something else was open.
struct PhotoAskSheet: View {
    var onCamera: () -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    var body: some View {
        SheetBody(detents: [.height(350)]) {
            Image(systemName: "camera.fill").font(.system(size: 30)).foregroundStyle(t.accent).frame(width: 70, height: 70).background(Circle().fill(t.accent.opacity(0.18)))
            Text("Your PC asks for a photo").font(TypeScale.title).foregroundStyle(t.text).padding(.top, 14)
            Text("It lands on the island’s Shelf").font(TypeScale.caption).foregroundStyle(t.muted)
            GlassButton(prominent: true, wide: true, action: onCamera) { Image(systemName: "camera"); Text("Take a photo").font(TypeScale.bodyStrong) }.padding(.top, 22)
        }
    }
}

/// Files that arrived: shown here (Quick Look: pictures, videos, PDFs, documents), to save or share.
struct ReceivedSheet: View {
    let files: [String]
    @State private var index = 0
    var body: some View {
        QuickLookView(urls: files.map(FolderInbox.url), index: $index).ignoresSafeArea()
            .presentationDetents([.large])
    }
}
struct QuickLookView: UIViewControllerRepresentable {
    let urls: [URL]; @Binding var index: Int
    func makeUIViewController(context: Context) -> UINavigationController {
        let q = QLPreviewController(); q.dataSource = context.coordinator; q.currentPreviewItemIndex = index
        return UINavigationController(rootViewController: q)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(urls) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]; init(_ u: [URL]) { urls = u }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { urls[index] as NSURL }
    }
}

/// Text from your PC's clipboard, to copy.
struct ClipSheet: View {
    let text: String
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SheetBody(detents: [.medium]) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 26)).foregroundStyle(t.accent).frame(width: 60, height: 60).background(Circle().fill(t.accent.opacity(0.18)))
            Text("From your PC’s clipboard").font(TypeScale.title).foregroundStyle(t.text).padding(.top, 12)
            Text(String(text.prefix(600))).font(TypeScale.body).foregroundStyle(t.text).padding(16).frame(maxWidth: .infinity, alignment: .leading).glass(RoundedRectangle(cornerRadius: 20, style: .continuous), .control).padding(.top, 14)
            GlassButton(prominent: true, wide: true, action: { UIPasteboard.general.string = text; Haptics.success(); hub.show(Banner(kind: .clipboard, title: "Copied")); dismiss() }) { Image(systemName: "doc.on.doc"); Text("Copy").font(TypeScale.bodyStrong) }.padding(.top, 18)
        }
    }
}

/// Files from elsewhere (dropped, pasted, opened in the app), AirDrop-style: your PCs as glowing bubbles; tap one and a ring
/// fills round it as they go, then turns to a tick.
struct ShareToPCSheet: View {
    let files: [URL]
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.dismiss) private var dismiss
    @State private var sending: [String: Int] = [:]
    var body: some View {
        SheetBody(detents: [.medium, .large]) {
            Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) items").font(TypeScale.title).foregroundStyle(t.text).lineLimit(2).multilineTextAlignment(.center)
            Text("Tap a PC to send").font(TypeScale.caption).foregroundStyle(t.muted)
            HStack(alignment: .top, spacing: 22) {
                ForEach(hub.pairedPCs) { p in
                    let id = sending[p.id], tr = id.flatMap { hub.transfers[$0] }, outcome = id.flatMap { hub.outcomes[$0] }
                    Button { guard sending[p.id] == nil else { return }; Haptics.tap(); Task { if let id = await hub.send(p.id, files: files, toShelf: p.revision >= 3) { sending[p.id] = id } } } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle().fill(t.accent.opacity(0.18)).frame(width: 76, height: 76)
                                Image(systemName: outcome == true ? "checkmark" : outcome == false ? "xmark" : "laptopcomputer").font(.system(size: 28, weight: .semibold)).foregroundStyle(outcome == false ? t.danger : t.accent)
                                    .contentTransition(.symbolEffect(.replace))
                                if id != nil && outcome == nil { ProgressRing(fraction: tr?.fraction ?? 0.02, color: t.accent, size: 84, stroke: 4) }
                                if outcome == true { Circle().stroke(t.good, lineWidth: 4).frame(width: 84, height: 84) }
                            }
                            .frame(width: 88, height: 88)
                            .opacity(p.online ? 1 : 0.5)
                            Text(p.name).font(TypeScale.caption).foregroundStyle(t.text).lineLimit(1)
                            Text(outcome == true ? "Sent" : outcome == false ? "Didn’t go" : id != nil ? "\(Int((tr?.fraction ?? 0) * 100))%" : p.online ? "Here" : "Away").font(TypeScale.micro).foregroundStyle(t.muted)
                        }
                        .frame(width: 96)
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.top, 22)
        }
    }
}

/// What the app does, and what's new.
struct WhatsNewSheet: View {
    @Environment(\.tokens) private var t
    private let items: [(String, String, String)] = [
        ("platter.filled.top.iphone", "It lives in your Dynamic Island", "What plays on your PC, files on their way and your PC’s focus clock, on the Lock Screen and in the Dynamic Island; the app’s own island grows right out of it."),
        ("laptopcomputer", "Your PC, in your hand", "Play, pause, skip and scrub, its volume on a dial, lyrics word by word, its clipboard, lock it, find it."),
        ("square.grid.2x2.fill", "The whole island", "Its numbers live (scrub the graphs), its battery, Wi-Fi, Bluetooth, dark mode, the focus clock, its command bar, power, where its sound goes, and every one of its settings."),
        ("paperplane.fill", "Send anything, both ways", "Photos at full quality, files and folders of any size, documents scanned as PDFs, straight from the share sheet in any app; on any network, end-to-end encrypted."),
        ("display", "Its screen here", "See your PC’s screen live and touch it, in Picture in Picture too; or show this iPhone’s camera in a window there."),
        ("music.note", "Music hands over", "A song on your PC continues here from the same second, on AirPods and AirPlay; hand it back when you sit down."),
        ("safari.fill", "Pages hand over", "Share a page from Safari and it opens on your PC where you were; pages from your PC open here the same way."),
        ("sparkles", "Siri, Shortcuts, Control Center", "“Lock my PC”, “Find my PC”, play and pause from Siri, the Action button, Control Center, widgets and the Lock Screen."),
        ("bell.and.waves.left.and.right.fill", "Find this iPhone", "Your PC rings it, even on silent, with the flashlight blinking."),
        ("lock.shield.fill", "Private by design", "Your key lives in the Secure Enclave; Face ID guards the app; nothing goes anywhere but your own devices."),
    ]
    var body: some View {
        SheetBody(detents: [.large]) {
            Image(uiImage: UIImage(named: "AppIcon") ?? UIImage()).resizable().frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            Text("Arnav Island for iPhone").font(TypeScale.title).foregroundStyle(t.text).padding(.top, 14)
            Text("Version \(appVersion)").font(TypeScale.caption).foregroundStyle(t.muted)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, x in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: x.0).font(.system(size: 20, weight: .semibold)).foregroundStyle(t.accent).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) { Text(x.1).font(TypeScale.bodyStrong).foregroundStyle(t.text); Text(x.2).font(TypeScale.caption).foregroundStyle(t.muted) }
                    }
                    .arrive(i)
                }
            }
            .padding(.top, 24)
        }
    }
}
struct AboutSheet: View { var body: some View { WhatsNewSheet() } }

/// Siri, Shortcuts, the Action button, Control Center and widgets.
struct ShortcutsSheet: View {
    @Environment(\.tokens) private var t
    var body: some View {
        SheetBody(detents: [.large]) {
            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(t.accent).frame(width: 70, height: 70).background(Circle().fill(t.accent.opacity(0.18)))
            Text("Siri and Shortcuts").font(TypeScale.title).foregroundStyle(t.text).padding(.top, 14)
            VStack(alignment: .leading, spacing: 14) {
                row("mic.fill", "Ask Siri", "“Lock my PC with Arnav Island”, “Find my PC”, “How’s my PC”, “Play or pause on my PC”")
                row("button.horizontal.top.press.fill", "The Action button", "Settings › Action Button › Shortcut › Arnav Island: lock your PC, find it, or open its trackpad with a press")
                row("switch.2", "Control Center", "Swipe down, tap +, then Add a Control › Arnav Island: play and pause, lock, find your PC")
                row("square.grid.2x2", "Widgets", "What plays on your PC and its numbers, on your Home Screen and Lock Screen; play and pause right there")
                row("platter.filled.top.iphone", "Live Activities", "What plays on your PC in the Dynamic Island, with play, pause and skip")
                row("square.and.arrow.up", "The share sheet", "Share anything from any app to Arnav Island to send it; share a page from Safari to open it on your PC where you were")
            }
            .padding(.top, 20)
            Link(destination: URL(string: "shortcuts://")!) { Label("Open Shortcuts", systemImage: "arrow.up.right.square").font(TypeScale.bodyStrong) }.padding(.top, 20)
        }
    }
    private func row(_ s: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: s).font(.system(size: 19, weight: .semibold)).foregroundStyle(t.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(TypeScale.bodyStrong).foregroundStyle(t.text); Text(detail).font(TypeScale.caption).foregroundStyle(t.muted) }
        }
    }
}
struct KeysSheet: View {
    @Environment(\.tokens) private var t
    var body: some View {
        SheetBody(detents: [.medium, .large]) {
            Text("Keyboard shortcuts").font(TypeScale.title).foregroundStyle(t.text)
            VStack(spacing: 10) {
                ForEach([("Space", "Play or pause on your PC"), ("← →", "Previous, next"), ("↑ ↓", "Volume"), ("M", "Mute"), ("⌘1 – ⌘5", "Switch tabs"), ("T", "Trackpad"), ("S", "Your PC’s screen")], id: \.0) { k in
                    HStack { Text(k.0).font(TypeScale.bodyStrong.monospaced()).foregroundStyle(t.accent).frame(width: 90, alignment: .leading); Text(k.1).font(TypeScale.body).foregroundStyle(t.text); Spacer() }
                }
            }
            .padding(.top, 18)
        }
    }
}

import IslandKit
import SwiftUI

let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"

/// This iPhone, your PCs (anywhere, through the relay), what the island may show of it, what it does in the background,
/// its security (Face ID, its key in the Secure Enclave), Siri and widgets, and how the app looks.
struct DevicesScreen: View {
    var onPair: () -> Void; var onScan: () -> Void; var onSheet: (Sheet) -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var editing = false
    @State private var name = ""
    @State private var erasing = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let paired = hub.peers.filter(\.paired)
        VStack(spacing: 0) {
            ScreenTitle(title: "Devices", over: "Arnav Island")
            thisIPhone.arrive(0)

            SectionLabel(text: "Your PCs")
            GlassPanel(padding: 14) {
                VStack(spacing: 0) {
                    ForEach(paired) { p in PcRow(p: p, chosen: p.id == hub.pc()?.id); Divider().overlay(t.hairline) }
                    Button { Haptics.tap(); onScan() } label: { SettingRow(symbol: "qrcode.viewfinder", title: "Scan the QR code", detail: "On your PC: the island’s Shelf › Nearby › Pair with a code. Any network works") { chevron } }.buttonStyle(PressStyle(scale: 0.98))
                    Divider().overlay(t.hairline)
                    Button { Haptics.tap(); onPair() } label: { SettingRow(symbol: "keyboard", title: "Type a code", detail: "The eight letters and digits the island shows") { chevron } }.buttonStyle(PressStyle(scale: 0.98))
                }
            }
            .arrive(1)

            SectionLabel(text: "On your PC’s island")
            GlassPanel(padding: 14) {
                VStack(spacing: 0) {
                    ToggleRow(symbol: "battery.100percent", title: "This iPhone’s battery", detail: "Its level on the island, and a word when it’s low", on: hub.pref(\.battery))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "iphone", title: "This iPhone’s details", detail: "Storage, memory, the network, the sound and more, in the island’s view of this iPhone", on: Binding(get: { hub.prefs.details }, set: { v in hub.update { $0.details = v }; if v { hub.sendDetails(force: true) } }))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "photo.badge.arrow.down", title: "Photos you take", detail: "A photo or screenshot shows on the island right away, to paste or keep on its Shelf. Only its small picture goes until you use it there", on: Binding(get: { hub.prefs.recentPhotos }, set: { v in
                        if v { Task { if await RecentPhotos.shared.requestAccess() { hub.update { $0.recentPhotos = true } } else { hub.show(Banner(kind: .info, title: "Photos access is off", detail: "Allow it in Settings › Arnav Island › Photos")) } } }
                        else { hub.update { $0.recentPhotos = false } }
                    }))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "arrow.down.doc", title: "Accept files from my PCs", detail: "Without asking each time", on: hub.pref(\.autoAccept))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "doc.on.clipboard", title: "Send copies automatically", detail: "What you copy here goes to your PC’s clipboard when you open the app (when its universal clipboard is on). iOS asks to allow pasting; choose Allow in Settings › Arnav Island to stop it asking", on: hub.pref(\.clipAuto))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "globe", title: "Reach my PCs anywhere", detail: "Through free public relays, end-to-end encrypted, when your PC isn’t on the same Wi-Fi", on: hub.pref(\.internet))
                }
            }
            .arrive(2)

            SectionLabel(text: "In the background")
            GlassPanel(padding: 14) {
                VStack(spacing: 0) {
                    ToggleRow(symbol: "antenna.radiowaves.left.and.right", title: "Stay reachable", detail: "Your PCs can ring this iPhone, send files and hand pages over while the app is in the background, as on Android. Keeps a silent sound playing (it mixes with your music); uses a little more battery", on: hub.pref(\.stayReachable))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "platter.filled.top.iphone", title: "Live Activities", detail: "What plays on your PC, files on their way and its focus clock, in the Dynamic Island and on the Lock Screen", on: hub.pref(\.liveActivity))
                }
            }
            .arrive(3)

            SectionLabel(text: "Security")
            GlassPanel(padding: 14) {
                VStack(spacing: 0) {
                    ToggleRow(symbol: "faceid", title: "Face ID", detail: hub.prefs.faceID ? "Asked for when the app opens, and after half a minute away. The app switcher shows it frosted" : "Ask for Face ID before the app opens", on: Binding(get: { hub.prefs.faceID }, set: { v in hub.update { $0.faceID = v }; if v { Haptics.success(); hub.show(Banner(kind: .info, title: "Face ID is on", detail: "It’s asked for when the app opens")) } }))
                    Divider().overlay(t.hairline)
                    SettingRow(symbol: "key.fill", title: "This iPhone’s key", detail: keyText) { EmptyView() }
                    Divider().overlay(t.hairline)
                    Button { Haptics.tap(); erasing = true } label: { SettingRow(symbol: "trash.fill", title: "Erase this iPhone", detail: "Forgets every PC and its key. Pair again to use it", tint: t.danger) { EmptyView() } }.buttonStyle(PressStyle(scale: 0.98))
                }
            }
            .arrive(4)

            SectionLabel(text: "On this iPhone")
            GlassPanel(padding: 14) {
                VStack(spacing: 0) {
                    Button { Haptics.tap(); onSheet(.shortcuts) } label: { SettingRow(symbol: "sparkles", title: "Siri, Shortcuts and the Action button", detail: "“Lock my PC”, “Find my PC”, play and pause; Control Center, widgets and the Lock Screen too") { chevron } }.buttonStyle(PressStyle(scale: 0.98))
                    Divider().overlay(t.hairline)
                    Button { Haptics.tap(); onSheet(.keys) } label: { SettingRow(symbol: "keyboard.badge.ellipsis", title: "Keyboard shortcuts", detail: "With a keyboard (iPad): space plays, arrows change the volume, ⌘1 to ⌘5 switch tabs") { chevron } }.buttonStyle(PressStyle(scale: 0.98))
                }
            }
            .arrive(5)

            SectionLabel(text: "Appearance")
            HStack(spacing: 8) {
                ForEach(Array([("Automatic", "circle.lefthalf.filled"), ("Dark", "moon.fill"), ("Light", "sun.max.fill")].enumerated()), id: \.offset) { i, x in
                    GlassChip(label: x.0, symbol: x.1, selected: hub.prefs.theme == i) { withAnimation(.easeInOut(duration: 0.4)) { hub.update { $0.theme = i } } }
                }
                Spacer()
            }
            GlassPanel(padding: 14) {
                VStack(spacing: 0) {
                    ToggleRow(symbol: "drop.fill", title: "Liquid glass", detail: hub.prefs.solidGlass ? "Off: solid surfaces, calmer and lighter on the battery" : "Surfaces bend and frost what’s behind them and catch the light", on: Binding(get: { !hub.prefs.solidGlass }, set: { v in withAnimation(.easeInOut(duration: 0.4)) { hub.update { $0.solidGlass = !v } } }))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "gyroscope", title: "Light follows your tilt", detail: "The light on the glass, the background and the cover lean as you tilt the iPhone", on: Binding(get: { hub.prefs.tilt }, set: { v in hub.update { $0.tilt = v }; if v { Tilt.shared.start() } else { Tilt.shared.stop() } }))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "cloud.rain.fill", title: "Weather on the glass", detail: "Rain, snow or sun motes on the app when that’s the weather where your PC is", on: hub.pref(\.weather))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "hand.tap.fill", title: "Haptics", detail: "A light tick as you touch the controls", on: hub.pref(\.haptics))
                    Divider().overlay(t.hairline)
                    ToggleRow(symbol: "photo", title: "Photos as JPEG", detail: "HEIC photos go as JPEG, which every PC opens (as iOS’s “Most Compatible”)", on: hub.pref(\.compatible))
                }
            }
            .padding(.top, 10)

            SectionLabel(text: "Privacy")
            GlassPanel {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Only between your own devices", systemImage: "checkmark.shield.fill").font(TypeScale.bodyStrong).foregroundStyle(t.good)
                    Text("This app talks to your PCs straight over your Wi-Fi when it can, else through free public relays (MQTT over TLS), sealed end to end: a relay sees only random-looking topics and encrypted bytes, never what they carry. Every connection is encrypted with ECDH P-256 and AES-256-GCM, only with devices you paired. This iPhone’s private key lives in its Secure Enclave and never leaves it. No account, no server of our own, no analytics.")
                        .font(TypeScale.caption).foregroundStyle(t.muted)
                }
            }

            SectionLabel(text: "About")
            GlassPanel(padding: 14) {
                VStack(spacing: 0) {
                    Button { Haptics.tap(); onSheet(.whatsNew) } label: { SettingRow(symbol: "sparkle", title: "Arnav Island for iPhone \(appVersion)", detail: "What it does, and what’s new") { chevron } }.buttonStyle(PressStyle(scale: 0.98))
                    Divider().overlay(t.hairline)
                    Link(destination: URL(string: "https://github.com/Arnav-Dugad/arnav-island-ios")!) { SettingRow(symbol: "arrow.up.right.square", title: "Arnav Island on GitHub", detail: "The island for Windows, the Android app and this app") { EmptyView() } }
                }
            }
        }
        .confirmationDialog("Erase this iPhone?", isPresented: $erasing, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It forgets every PC, its key and its history here. Your PCs keep it paired until you forget it there too.") }
    }

    private var chevron: some View { Image(systemName: "chevron.right").foregroundStyle(t.muted) }
    private var keyText: String {
        guard let pub = hub.link?.publicKey, !pub.isEmpty else { return "Making it…" }
        let p = Crypto.keyPrint(pub).hex.uppercased(); let groups = stride(from: 0, to: p.count, by: 4).map { i -> String in let s = p.index(p.startIndex, offsetBy: i); return String(p[s..<p.index(s, offsetBy: min(4, p.count - i))]) }
        return "Fingerprint \(groups.joined(separator: " ")). Its private half lives in the Secure Enclave: not even this app can read it"
    }

    private var thisIPhone: some View {
        GlassPanel {
            HStack(spacing: 14) {
                Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone.gen3").font(.system(size: 26, weight: .medium)).foregroundStyle(t.accent)
                    .frame(width: 52, height: 52).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(t.accent.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    if editing {
                        TextField("This iPhone’s name", text: $name).font(TypeScale.headline).focused($nameFocused).submitLabel(.done)
                            .onSubmit { hub.update { $0.name = String(name.prefix(40)) }; editing = false }
                    } else {
                        Button { name = hub.phoneName(); editing = true; nameFocused = true } label: {
                            HStack(spacing: 6) { Text(hub.phoneName()).font(TypeScale.headline).foregroundStyle(t.text).lineLimit(1); Image(systemName: "pencil").font(.system(size: 13)).foregroundStyle(t.faint) }
                        }
                        .accessibilityLabel("Rename this iPhone")
                    }
                    Text(status).font(TypeScale.caption).foregroundStyle(hub.failure != nil ? t.danger : t.muted)
                }
                Spacer()
                LiveDot(on: hub.running && hub.internet && hub.failure == nil)
            }
        }
    }
    private var status: String {
        if let f = hub.failure { return f }
        if !hub.running { return "Starting…" }
        if !hub.prefs.internet { return "On this Wi-Fi only" }
        let relays = hub.link?.relayBrokersUp ?? 0
        return hub.internet ? "Reachable by your PCs anywhere\(relays > 1 ? ", through \(relays) free relays" : "")" : "Connecting to the internet…"
    }
    private func erase() {
        let hub = self.hub
        hub.stop(); KeychainStore.shared.erase(); hub.clearMoments()
        AppGroup.defaults.removeObject(forKey: "pc"); AppGroup.defaults.removeObject(forKey: "focus")
        try? FileManager.default.removeItem(at: Snapshot.file); try? FileManager.default.removeItem(at: Snapshot.coverFile)
        LiveActivities.shared.endAll(); Snapshotter.shared.reload()
        Haptics.success()
        Task { try? await Task.sleep(for: .milliseconds(400)); await hub.start(); hub.show(Banner(kind: .info, title: "Erased", detail: "A new key was made. Pair again to use it")) }
    }
}

struct PcRow: View {
    let p: PeerView; let chosen: Bool
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var confirm = false
    @State private var renaming = false
    @State private var newName = ""
    var body: some View {
        let q = Quality.of(p, t)
        Button { if !p.phone { Haptics.tick(); hub.choose(p.id) } } label: {
            SettingRow(symbol: p.phone ? "iphone" : "laptopcomputer", title: p.name,
                       detail: [q.text, chosen ? "Remote and sends go here" : "", p.online && !p.remote ? "Update its island for the remote" : ""].filter { !$0.isEmpty }.joined(separator: "  ·  "),
                       tint: p.online ? t.good : t.faint) {
                HStack(spacing: 8) {
                    if p.online { QualityRing(q: q, size: 18, stroke: 2.4) }
                    if chosen { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(t.accent) }
                }
            }
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .contextMenu {
            if !p.phone { Button("Use this PC", systemImage: "checkmark.circle") { hub.choose(p.id) } }
            Button("Rename", systemImage: "pencil") { newName = p.name; renaming = true }
            Button("Forget", systemImage: "trash", role: .destructive) { confirm = true }
        }
        .confirmationDialog("Forget \(p.name)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { Haptics.thud(); hub.forget(p.id) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Pair again to reach it from this iPhone.") }
        .alert("Rename \(p.name)", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { hub.rename(p.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .swipeActions { Button("Forget", role: .destructive) { confirm = true } }
    }
}

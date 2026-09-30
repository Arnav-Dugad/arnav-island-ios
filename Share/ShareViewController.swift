import IslandKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share › Arnav Island, from any app: your PCs as glowing bubbles, AirDrop-style; tap one and a ring fills round it as it
/// goes, then turns to a tick. A page from Safari opens on the PC where you were; text goes to its clipboard. When the PC
/// isn't reachable, it's left for the app to send when it next opens.
final class ShareViewController: UIViewController {
    private let model = ShareModel()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        model.done = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareView(model: model))
        host.view.backgroundColor = .clear
        addChild(host); view.addSubview(host.view); host.view.frame = view.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; host.didMove(toParent: self)
        model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); model.close() }
}

/// A PC to send to, as the share sheet shows it.
struct SharePC: Identifiable, Equatable { let id: String; var name: String; var online: Bool; var revision: Int; var lan: Bool }

@MainActor
final class ShareModel: ObservableObject {
    enum What: Equatable { case loading, files([URL]), page(URL, String, Double), text(String), nothing }
    @Published var what: What = .loading
    @Published var pcs: [SharePC] = []
    @Published var progress: [String: Double] = [:]
    @Published var outcome: [String: Bool] = [:]
    @Published var note: String?
    @Published var connecting = true
    var done: () -> Void = {}
    private var link: IslandKit.Link?
    private var transfers: [Int: String] = [:]
    private var closed = false
    private let accent = Color(red: 0.65, green: 0.85, blue: 0.77)

    // ---- what was shared ----
    func load(_ items: [NSExtensionItem]) {
        Task {
            var files: [URL] = []; var page: (URL, String, Double)?; var text: String?
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for item in items {
                for p in item.attachments ?? [] {
                    // Safari: the page with how far down it was (PagePosition.js).
                    if p.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                       let dict = try? await p.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? [String: Any],
                       let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any], let u = (results["url"] as? String).flatMap(URL.init(string:)) {
                        page = (u, results["title"] as? String ?? "", results["scroll"] as? Double ?? 0); continue
                    }
                    if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || p.hasItemConformingToTypeIdentifier(UTType.image.identifier) || p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) || p.hasItemConformingToTypeIdentifier(UTType.data.identifier) && !p.hasItemConformingToTypeIdentifier(UTType.url.identifier) && !p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        if let f = await Self.file(p, into: out) { files.append(f) }; continue
                    }
                    if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                        if u.isFileURL { if let f = Self.copy(u, into: out) { files.append(f) } } else if page == nil { page = (u, item.attributedContentText?.string ?? "", 0) }
                        continue
                    }
                    if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { text = (text.map { $0 + "\n" } ?? "") + s }
                }
            }
            if !files.isEmpty { what = .files(files) } else if let page { what = .page(page.0, page.1, page.2) } else if let text, !text.isEmpty { what = .text(text) } else { what = .nothing }
        }
        startLink()
    }
    private static func file(_ p: NSItemProvider, into dir: URL) async -> URL? {
        let type = p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
        return await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { c.resume(returning: nil); return }
                var name = url.lastPathComponent
                if let suggested = p.suggestedName, !suggested.isEmpty { let ext = url.pathExtension; name = ext.isEmpty || suggested.hasSuffix("." + ext) ? suggested : suggested + "." + ext }
                let dest = dir.appendingPathComponent(safeName(name))
                c.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil)
            }
        }
    }
    private static func copy(_ u: URL, into dir: URL) -> URL? {
        let scoped = u.startAccessingSecurityScopedResource(); defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        let dest = dir.appendingPathComponent(safeName(u.lastPathComponent)); return (try? FileManager.default.copyItem(at: u, to: dest)) != nil ? dest : nil
    }

    // ---- the link, as a guest beside the app ----
    private func startLink() {
        let store = KeychainStore.shared
        let known = store.loadPeers().filter { !$0.phone }
        pcs = known.map { SharePC(id: $0.id, name: $0.name, online: false, revision: $0.revision, lan: false) }
        guard store.hasIdentity, !known.isEmpty else { connecting = false; note = "Open Arnav Island and pair with your PC first"; return }
        let prefs = (AppGroup.defaults.data(forKey: "prefs").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let name = (prefs["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UIDevice.current.model
        let l = IslandKit.Link(store: store, name: name, inbox: NoInbox(), options: IslandKit.Link.Options(phone: true, direct: false, guest: true)) { [weak self] e in DispatchQueue.main.async { self?.event(e) } }
        link = l
        Task.detached { [weak self] in
            let ok = l.start()
            await MainActor.run { if !ok { self?.connecting = false; self?.note = "Couldn’t reach the internet" } }
            _ = l.waitConnected(10)
            await MainActor.run { self?.peersChanged(l.peerViews()) }
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run { self?.connecting = false }
        }
    }
    private func event(_ e: LinkEvent) {
        switch e {
        case .peers(let list): peersChanged(list)
        case .progress(let t, _, _, _, let done, let total, _): if let pc = transfers[t] { progress[pc] = total > 0 ? Double(done) / Double(total) : 0 }
        case .sent(let t, _, _, _, _, _): if let pc = transfers[t] { outcome[pc] = true; progress[pc] = 1; finishSoon() }
        case .failed(let t, _, _, _, let detail, _): if let pc = transfers[t] { outcome[pc] = false; note = detail }
        default: break
        }
    }
    private func peersChanged(_ list: [PeerView]) {
        for v in list where v.paired && !v.phone {
            if let i = pcs.firstIndex(where: { $0.id == v.id }) { pcs[i].online = v.online; pcs[i].revision = v.revision; pcs[i].lan = v.lan; pcs[i].name = v.name }
        }
        if pcs.contains(where: { $0.online }) { connecting = false }
    }

    // ---- sending ----
    func send(to pc: SharePC) {
        guard outcome[pc.id] == nil, progress[pc.id] == nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let l = link, pc.online else { later(pc); return }
        progress[pc.id] = 0.02
        switch what {
        case .files(let files):
            let sources = Sources.of(files)
            let title = files.count == 1 ? files[0].lastPathComponent : "\(files[0].lastPathComponent) and \(files.count - 1) more"
            Task.detached { let id = l.send(pc.id, items: sources, title: title, toShelf: pc.revision >= 3); await MainActor.run { self.transfers[id] = pc.id } }
        case .page(let url, let title, let scroll):
            Task.detached {
                let r = pc.revision >= 8 ? l.remote(pc.id, Proto.cmdPage, Frames.page(url: url.absoluteString, title: title, scroll: Float(scroll))) : l.remote(pc.id, Proto.cmdOpen, Array(url.absoluteString.utf8))
                await MainActor.run { self.outcome[pc.id] = r?.ok == true; self.progress[pc.id] = 1; if r?.ok == true { self.finishSoon() } else { self.note = r == nil ? "\(pc.name) didn't answer" : "Turn on “My phone can control this PC” on \(pc.name)’s island" } }
            }
        case .text(let s):
            Task.detached {
                let r = l.remote(pc.id, Proto.cmdClipSet, Array(s.prefix(100_000).utf8))
                await MainActor.run { self.outcome[pc.id] = r?.ok == true; self.progress[pc.id] = 1; if r?.ok == true { self.finishSoon() } else { self.note = "\(pc.name) didn't take it" } }
            }
        default: break
        }
    }
    /// Left for the app, which sends it when it next opens.
    func later(_ pc: SharePC) {
        var ok = false
        switch what {
        case .files(let files): ok = ShareInbox.leave(peer: pc.id, toShelf: pc.revision >= 3, files: files)
        case .page(let u, let t, let s): ok = ShareInbox.leave(peer: pc.id, toShelf: false, files: [], page: u.absoluteString, title: t, scroll: s)
        case .text(let s): UIPasteboard.general.string = s; ok = true
        default: break
        }
        note = ok ? "\(pc.name) is away. It goes when you next open Arnav Island" : "Couldn’t keep it for later"
        if ok { outcome[pc.id] = true; finishSoon(after: 1.8) }
    }
    private func finishSoon(after: Double = 1.1) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { try? await Task.sleep(for: .seconds(after)); done() }
    }
    func close() { guard !closed else { return }; closed = true; let l = link; link = nil; DispatchQueue.global().async { l?.stop() } }
}

/// The share sheet never receives anything.
final class NoInbox: Inbox {
    func folder(_ name: String) -> String { name }
    func create(_ parts: [String], size: Int64) -> Sink? { nil }
    func song(_ name: String, size: Int64) -> Sink? { nil }
    func room(_ bytes: Int64) -> Bool { false }
}

/// Files and folders as the link sends them (as the app's own).
enum Sources {
    static func of(_ urls: [URL]) -> [Source] {
        urls.compactMap { u in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Source(rel: safeName(u.lastPathComponent), size: Int64($0), url: u) } }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    @Environment(\.colorScheme) private var scheme
    private let accent = Color(red: 0.65, green: 0.85, blue: 0.77)
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)
                HStack {
                    Text(title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                    Spacer()
                    Button { model.done() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 34, height: 34).background(Circle().fill(.secondary.opacity(0.18))) }.foregroundStyle(.primary)
                }
                .padding(.horizontal, 22).padding(.top, 14)
                Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 2)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(model.pcs) { pc in bubble(pc) }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 22)
                }
                .scrollIndicators(.hidden)
                if let note = model.note { Text(note).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 22).padding(.bottom, 12).transition(.opacity) }
                Label("End-to-end encrypted, only to your own PCs", systemImage: "lock.fill").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tertiary).padding(.bottom, 22)
            }
            .frame(maxWidth: 560)
            .background { shape.fill(.regularMaterial) }
            .modifier(ShareGlass())
            .clipShape(shape)
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: model.progress)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: model.outcome)
        .animation(.easeInOut, value: model.note)
        .tint(accent)
    }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 36, style: .continuous) }
    private var title: String {
        switch model.what {
        case .loading: return "Getting it ready…"
        case .files(let f): return f.count == 1 ? f[0].lastPathComponent : "\(f.count) items"
        case .page(let u, let t, _): return t.isEmpty ? (u.host ?? "A page") : t
        case .text(let s): return String(s.prefix(60))
        case .nothing: return "Nothing to send"
        }
    }
    private var subtitle: String {
        switch model.what {
        case .page(_, _, let s): return "Opens on your PC\(s > 0.02 ? ", \(Int(s * 100))% of the way down, where you were" : "")"
        case .text: return "To your PC’s clipboard"
        case .files: return model.connecting ? "Finding your PCs…" : "Tap a PC to send; it lands on its island’s Shelf"
        default: return ""
        }
    }
    private func bubble(_ pc: SharePC) -> some View {
        let p = model.progress[pc.id], o = model.outcome[pc.id]
        return Button { model.send(to: pc) } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(accent.opacity(pc.online ? 0.22 : 0.1)).frame(width: 74, height: 74)
                        .shadow(color: accent.opacity(pc.online ? 0.5 : 0), radius: 12)
                    Image(systemName: o == true ? "checkmark" : o == false ? "xmark" : "laptopcomputer").font(.system(size: 27, weight: .semibold)).foregroundStyle(o == false ? .red : accent)
                        .contentTransition(.symbolEffect(.replace))
                    if let p, o == nil { Circle().trim(from: 0, to: max(0.02, p)).stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: 84, height: 84) }
                    if o == true { Circle().stroke(.green, lineWidth: 4).frame(width: 84, height: 84) }
                    if model.connecting && !pc.online && p == nil { ProgressView().offset(x: 30, y: 30) }
                }
                .frame(width: 88, height: 88)
                Text(pc.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(o == true ? "Sent" : o == false ? "Didn’t go" : p != nil ? "\(Int((p ?? 0) * 100))%" : pc.online ? (pc.lan ? "On this Wi-Fi" : "Here") : model.connecting ? "Looking…" : "Away · later").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(width: 94)
        }
        .buttonStyle(.plain)
        .disabled(model.what == .loading || model.what == .nothing)
        .opacity(pc.online || !model.connecting ? 1 : 0.6)
    }
}

/// The share sheet in Liquid Glass on iOS 26.
struct ShareGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous)) } else { content }
    }
}

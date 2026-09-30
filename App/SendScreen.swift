import IslandKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// A photo or video picked from Photos, as its own file (full quality), copied where the link can read it.
struct PickedMedia: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in PickedMedia(url: try copy(received.file)) }
        FileRepresentation(importedContentType: .image) { received in PickedMedia(url: try copy(received.file)) }
    }
    static func copy(_ file: URL) throws -> URL {
        let dest = Sources.outgoing().appendingPathComponent(safeName(file.lastPathComponent))
        try FileManager.default.copyItem(at: file, to: dest); return dest
    }
}

/// Sending to your PC (photos, files, a document scanned, a photo taken for its Shelf, the clipboard), transfers as they
/// go, and what came and went.
struct SendScreen: View {
    var onPair: () -> Void; var onOpen: ([String]) -> Void; var onShare: ([URL]) -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var scanning = false
    @State private var preparing = false

    var body: some View {
        let pc = hub.pc(), paired = hub.pairedPCs, compatible = hub.prefs.compatible
        VStack(spacing: 0) {
            ScreenTitle(title: "Send", over: pc.map { "To \($0.name)" } ?? "Pair a PC first") { if preparing { ProgressView() } }
            if paired.count > 1 {
                ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(paired) { p in GlassChip(label: p.name, symbol: "laptopcomputer", selected: p.id == pc?.id, symbolTint: p.online ? t.good : nil) { hub.choose(p.id) } } } }
                    .scrollIndicators(.hidden).scrollClipDisabled().padding(.bottom, 14)
            }
            if let pc {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    PhotosPicker(selection: $picked, maxSelectionCount: 50, matching: .any(of: [.images, .videos, .livePhotos]), preferredItemEncoding: .current) {
                        TileFace(symbol: "photo.on.rectangle.angled", title: "Photos & videos", detail: compatible ? "Full quality; HEIC as JPEG" : "Full quality, as they are", tint: t.accent)
                    }
                    .buttonStyle(PressStyle(scale: 0.95))
                    GlassTile(symbol: "folder.fill", title: "Files", detail: "Anything, any size, folders too", tint: t.accent2) { importing = true }
                    GlassTile(symbol: "camera.fill", title: "Camera", detail: pc.revision >= 3 ? "Straight onto \(pc.name)’s Shelf" : "A photo, to \(pc.name)", tint: t.accent2) { CameraCapture.present() }
                    GlassTile(symbol: "doc.viewfinder", title: "Scan a document", detail: "As a PDF, edges found for you") { scanning = true }
                    GlassTile(symbol: "doc.on.clipboard", title: "Clipboard", detail: "Text or a picture, to \(pc.name)") { sendClipboard(pc) }
                    GlassTile(symbol: "safari.fill", title: "A page from Safari", detail: "Share › Arnav Island, where you are", tint: t.accent2) { hub.show(Banner(kind: .info, title: "In Safari, tap Share", detail: "Then Arnav Island: the page opens on your PC where you were")) }
                }
                Label(pc.online ? (pc.lan ? "On this Wi-Fi, straight to it: end-to-end encrypted" : "Through the relay, end-to-end encrypted, on any network") : "\(pc.name) is away. Files go once Arnav Island runs there, on any network.", systemImage: pc.online ? "lock.shield" : "moon.zzz")
                    .font(TypeScale.caption).foregroundStyle(t.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.top, 12)
                let list = hub.transfers.values.sorted { $0.id < $1.id }
                if !list.isEmpty {
                    SectionLabel(text: "Now")
                    GlassPanel(padding: 14) {
                        VStack(spacing: 0) { ForEach(Array(list.enumerated()), id: \.element.id) { i, tr in if i > 0 { Divider().overlay(t.hairline) }; TransferRow(tr: tr) } }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !hub.moments.isEmpty {
                    SectionLabel(text: "Recent", action: ("Clear", { hub.clearMoments() }))
                    GlassPanel(padding: 14) {
                        VStack(spacing: 0) {
                            ForEach(Array(hub.moments.prefix(20).enumerated()), id: \.element.id) { i, m in
                                if i > 0 { Divider().overlay(t.hairline) }
                                Button { if m.kind != 1 { open(m) } } label: {
                                    SettingRow(symbol: m.kind == 0 ? "arrow.down.circle.fill" : m.kind == 2 ? "tray.and.arrow.down.fill" : "paperplane.fill", title: m.title,
                                               detail: "\(m.kind == 1 ? "To" : "From") \(m.from)  ·  \(sizeText(m.size))  ·  \(ago(m.at))", tint: m.kind == 1 ? t.accent2 : t.good) {
                                        if m.kind != 1 && !m.files.isEmpty { Image(systemName: "eye").foregroundStyle(t.muted) }
                                    }
                                }
                                .buttonStyle(PressStyle(scale: 0.98))
                                .contextMenu { if m.kind != 1, !m.files.isEmpty { Button("Show", systemImage: "eye") { open(m) }; ShareLink(items: m.files.map(FolderInbox.url)) { Label("Share", systemImage: "square.and.arrow.up") } } }
                            }
                        }
                    }
                }
            } else {
                GlassButton(prominent: true, action: onPair) { Image(systemName: "laptopcomputer"); Text("Pair with your PC").font(TypeScale.bodyStrong) }.padding(.top, 20)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: hub.transfers.count)
        .onChange(of: picked) { _, items in guard !items.isEmpty, let pc = hub.pc() else { return }; picked = []; Task { await sendPicked(items, to: pc) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r, let pc = hub.pc() else { return }
            Task { preparing = true; let dir = Sources.outgoing(); let files = await io { urls.compactMap { Sources.copyIn($0, to: dir) } }; preparing = false; await hub.send(pc.id, files: files) }
        }
        .fullScreenCover(isPresented: $scanning) { DocumentScanner { pdf in scanning = false; if let pdf, let pc = hub.pc() { Task { await hub.send(pc.id, files: [pdf], toShelf: pc.revision >= 3) } } }.ignoresSafeArea() }
        .dropDestination(for: URL.self) { urls, _ in guard let pc = hub.pc() else { return false }; Task { let dir = Sources.outgoing(); let files = await io { urls.compactMap { Sources.copyIn($0, to: dir) } }; await hub.send(pc.id, files: files) }; return true }
    }

    private func sendPicked(_ items: [PhotosPickerItem], to pc: PeerView) async {
        preparing = true; defer { preparing = false }
        var files: [URL] = []
        for item in items {
            guard let media = try? await item.loadTransferable(type: PickedMedia.self) else { continue }
            var url = media.url
            if hub.prefs.compatible, ["heic", "heif"].contains(url.pathExtension.lowercased()), let data = try? Data(contentsOf: url) {
                let jpg = url.deletingPathExtension().appendingPathExtension("jpg")
                if await io({ RecentPhotos.jpeg(data, to: jpg) }) { url = jpg }
            }
            files.append(url)
        }
        guard !files.isEmpty else { hub.show(Banner(kind: .failed, title: "Couldn't read those")); return }
        await hub.send(pc.id, files: files)
    }
    private func sendClipboard(_ pc: PeerView) {
        let board = UIPasteboard.general
        if board.hasImages, let img = board.image, let data = img.pngData() {
            let dir = Sources.outgoing(); if let f = Sources.write(data, name: "Pasted \(Date().formatted(.dateTime.hour().minute().second())).png".replacingOccurrences(of: ":", with: "."), to: dir) { Task { await hub.send(pc.id, files: [f], toShelf: pc.revision >= 3) } }
        } else if board.hasURLs, let u = board.url, u.scheme?.hasPrefix("http") == true { Task { _ = await hub.pageToPC(u, title: "", scroll: 0) } }
        else if let s = board.string, !s.isEmpty { Task { await hub.clipboardToPC(s) } }
        else { hub.show(Banner(kind: .info, title: "Nothing to send", detail: "Copy some text or a picture first")) }
    }
    private func open(_ m: Moment) {
        let there = m.files.filter { FileManager.default.fileExists(atPath: FolderInbox.url($0).path) }
        if there.isEmpty { hub.show(Banner(kind: .info, title: "It’s no longer here", detail: "It was moved or deleted in Files")) } else { onOpen(there) }
    }
}

/// A tile's face without its button (for pickers that are buttons themselves).
struct TileFace: View {
    let symbol: String; let title: String; let detail: String; let tint: Color
    @Environment(\.tokens) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint).frame(width: 42, height: 42).background(Circle().fill(tint.opacity(t.dark ? 0.18 : 0.14)))
            Spacer(minLength: 14)
            Text(title).font(TypeScale.bodyStrong).foregroundStyle(t.text).lineLimit(1)
            Text(detail).font(TypeScale.caption).foregroundStyle(t.muted).lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading).padding(16)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassCard(24)
    }
}

struct TransferRow: View {
    let tr: Transfer
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                ProgressRing(fraction: tr.fraction, color: tr.outgoing ? t.accent2 : t.good, size: 42, stroke: 3.5)
                Image(systemName: tr.outgoing ? "arrow.up" : "arrow.down").font(.system(size: 15, weight: .bold)).foregroundStyle(tr.outgoing ? t.accent2 : t.good)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tr.title).font(TypeScale.bodyStrong).foregroundStyle(t.text).lineLimit(1)
                Text(["\(tr.outgoing ? "To" : "From") \(tr.name)", "\(Int(tr.fraction * 100))%", tr.rate > 0 ? rateText(tr.rate) : "", tr.rate > 0 ? leftText(Double(tr.total - tr.done) / tr.rate) : ""].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(TypeScale.caption.monospacedDigit()).foregroundStyle(t.muted).lineLimit(1).contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            GlassIconButton(symbol: "xmark", label: "Stop", size: 36, iconSize: 14) { hub.cancel(tr.id) }
        }
        .padding(.vertical, 10)
    }
}

/// VisionKit's document camera: finds the page's edges, flattens it; the pages become one PDF.
struct DocumentScanner: UIViewControllerRepresentable {
    let done: (URL?) -> Void
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController { let v = VNDocumentCameraViewController(); v.delegate = context.coordinator; return v }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done) }
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: (URL?) -> Void
        init(_ done: @escaping (URL?) -> Void) { self.done = done }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { done(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let url = Sources.outgoing().appendingPathComponent("Scan \(Date().formatted(.dateTime.year().month().day().hour().minute())).pdf".replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-"))
            let first = scan.imageOfPage(at: 0), bounds = CGRect(origin: .zero, size: first.size)
            let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
                for i in 0..<scan.pageCount { let img = scan.imageOfPage(at: i); ctx.beginPage(withBounds: CGRect(origin: .zero, size: img.size), pageInfo: [:]); img.draw(at: .zero) }
            }
            done((try? data.write(to: url)) != nil ? url : nil)
        }
    }
}

/// The camera, for a photo straight to your PC (onto its island's Shelf).
@MainActor
enum CameraCapture {
    private static var holder: Delegate?
    static func present() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera), let top = topController() else { Hub.shared.show(Banner(kind: .failed, title: "No camera here")); return }
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.cameraCaptureMode = .photo
        let d = Delegate(); holder = d; picker.delegate = d
        top.present(picker, animated: true)
    }
    static func topController() -> UIViewController? {
        var c = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let p = c?.presentedViewController { c = p }
        return c
    }
    final class Delegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true); Task { @MainActor in CameraCapture.holder = nil; Hub.shared.photoFor = nil } }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            let image = info[.originalImage] as? UIImage
            Task { @MainActor in
                CameraCapture.holder = nil
                guard let data = image?.jpegData(compressionQuality: 0.92) else { return }
                let name = "Photo \(Date().formatted(.dateTime.hour().minute().second())).jpg".replacingOccurrences(of: ":", with: ".")
                if let f = Sources.write(data, name: name, to: Sources.outgoing()) { Hub.shared.sendPhoto(f) }
            }
        }
    }
}

/// Your PC's Shelf: what is on it, each taken here with a tap (or held, for more).
struct ShelfScreen: View {
    let shown: Bool; var onPair: () -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var list: ShelfList?
    @State private var loading = false
    @State private var taken = Set<String>()
    var body: some View {
        let pc = hub.pc()
        VStack(spacing: 0) {
            ScreenTitle(title: "Shelf", over: pc.map { "\($0.name)’s" } ?? "Your PC’s") {
                if pc != nil { GlassIconButton(symbol: "arrow.clockwise", label: "Refresh", size: 42, iconSize: 18) { Task { await load() } }.rotationEffect(.degrees(loading ? 360 : 0)).animation(loading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: loading) }
            }
            if let pc {
                if !pc.online { EmptyCard(symbol: "wifi.slash", title: "\(pc.name) is away", detail: "Its Shelf shows here when Arnav Island runs there") }
                else if let list {
                    if let e = list.error { EmptyCard(symbol: "exclamationmark.triangle", title: "Couldn’t look", detail: e) }
                    else if !list.shared { EmptyCard(symbol: "lock.fill", title: "\(pc.name) keeps its Shelf to itself", detail: "Turn on “My PCs can take from the Shelf” in the island’s Settings › Privacy & productivity") }
                    else if list.items.isEmpty { EmptyCard(symbol: "tray", title: "The Shelf is empty", detail: "Drop files on the island’s Shelf and they show up here") }
                    else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(Array(list.items.enumerated()), id: \.offset) { i, item in
                                let moving = hub.transfers.values.first { !$0.outgoing && $0.title == item.name && $0.peer == pc.id }
                                ShelfTile(item: item, moving: moving, done: taken.contains(item.name)) { if moving == nil { hub.take(pc.id, index: i, item: item); taken.insert(item.name); Haptics.success() } }
                                    .arrive(i)
                            }
                        }
                    }
                } else { EmptyCard(symbol: "tray.full", title: "Looking at \(pc.name)’s Shelf…", detail: "") }
            } else {
                EmptyCard(symbol: "tray.full", title: "Pair with your PC", detail: "Then take anything on its Shelf with a tap") { GlassButton(prominent: true, action: onPair) { Text("Pair").font(TypeScale.bodyStrong) } }
            }
        }
        .task(id: "\(pc?.id ?? "")|\(shown)|\(pc?.online == true)") { if shown && pc?.online == true { await load() } }
        .onChange(of: pc?.id) { _, _ in list = nil; taken = [] }
    }
    private func load() async {
        guard let pc = hub.pc(), !loading else { return }
        loading = true; let l = await hub.shelf(pc.id); withAnimation(.spring(response: 0.45)) { list = l }; loading = false
    }
}

struct ShelfTile: View {
    let item: ShelfItem; let moving: Transfer?; let done: Bool; let onTake: () -> Void
    @Environment(\.tokens) private var t
    var body: some View {
        Button { Haptics.tap(); onTake() } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.aspectRatio(1.25, contentMode: .fit).overlay {
                    if let p = item.preview, let img = UIImage(data: Data(p)) { Image(uiImage: img).resizable().scaledToFill() }
                    else { ZStack { t.accent.opacity(0.1); Image(systemName: item.folder ? "folder.fill" : symbolFor(item.name)).font(.system(size: 34)).foregroundStyle(t.accent) } }
                }
                .overlay {
                    if let m = moving { Color.black.opacity(0.45); ProgressRing(fraction: m.fraction, track: .white.opacity(0.25), color: .white, size: 46, stroke: 4) }
                    else if done {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.white, t.good).symbolEffect(.bounce, value: done)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8).transition(.scale.combined(with: .opacity))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(item.name).font(TypeScale.bodyStrong).foregroundStyle(t.text).lineLimit(1).padding(.top, 9).padding(.horizontal, 4)
                Text(item.folder ? "Folder  ·  \(sizeText(item.size))" : sizeText(item.size)).font(TypeScale.caption).foregroundStyle(t.muted).padding(.horizontal, 4)
            }
            .padding(10)
            .glassCard(24)
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .accessibilityLabel("Take \(item.name)")
    }
}

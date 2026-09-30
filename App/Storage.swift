import Foundation
import IslandKit
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// Where what your PCs send lands: the app's Documents folder, which the Files app shows under On My iPhone › Arnav Island
/// (and which a Mac or PC reaches over a cable). Songs handed over to play go to a cache instead.
final class FolderInbox: Inbox {
    static let shared = FolderInbox()
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var songs: URL { let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Songs"); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }
    private let lock = NSLock()
    /// Names handed out but not yet kept (two arriving at once mustn't take the same one).
    private var reserved = Set<String>()

    static func relative(_ url: URL) -> String? {
        let root = documents.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : nil
    }
    static func url(_ relative: String) -> URL { documents.appendingPathComponent(relative) }

    /// A free name in [dir]: "name", then "name (2)"…
    private func free(_ name: String, in dir: URL) -> String {
        lock.lock(); defer { lock.unlock() }
        let ext = (name as NSString).pathExtension, base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name; var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) || reserved.contains(dir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"; n += 1
        }
        reserved.insert(dir.appendingPathComponent(candidate).path)
        return candidate
    }
    fileprivate func release(_ path: String) { lock.lock(); reserved.remove(path); lock.unlock() }

    func folder(_ name: String) -> String { free(safeName(name), in: Self.documents) }
    func create(_ parts: [String], size: Int64) -> Sink? {
        guard !parts.isEmpty else { return nil }
        var dir = Self.documents
        for p in parts.dropLast() { dir.appendPathComponent(p) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = free(parts.last!, in: dir)
        return FileSink(dir.appendingPathComponent(name), inbox: self)
    }
    func song(_ name: String, size: Int64) -> Sink? {
        // Only the last few songs are kept.
        let dir = Self.songs
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]), old.count > 6 {
            for u in old.sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }).prefix(old.count - 6) { try? FileManager.default.removeItem(at: u) }
        }
        return FileSink(dir.appendingPathComponent(free(safeName(name), in: dir)), inbox: self)
    }
    func room(_ bytes: Int64) -> Bool {
        let v = try? Self.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = v?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > bytes + 200 << 20
    }
}

/// A file arriving: written beside its name (hidden), kept under it once whole.
final class FileSink: Sink {
    private let url: URL, part: URL; private let handle: FileHandle?; private weak var inbox: FolderInbox?
    init(_ url: URL, inbox: FolderInbox) {
        self.url = url; self.inbox = inbox
        part = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".part")
        FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        handle = try? FileHandle(forWritingTo: part)
    }
    func write(_ b: ArraySlice<UInt8>) -> Bool { guard let handle else { return false }; do { try b.withUnsafeBytes { try handle.write(contentsOf: $0) }; return true } catch { return false } }
    func commit() -> URL? {
        defer { inbox?.release(url.path) }
        do { try handle?.close(); try FileManager.default.moveItem(at: part, to: url); return url } catch { try? FileManager.default.removeItem(at: part); return nil }
    }
    func abort() { try? handle?.close(); try? FileManager.default.removeItem(at: part); inbox?.release(url.path) }
}

/// Files and folders as the link sends them: each file with its path under the folder it was in.
enum Sources {
    static func of(_ urls: [URL]) -> [Source] {
        var out: [Source] = []
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                let root = url.standardizedFileURL.path, top = safeName(url.lastPathComponent)
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    guard let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
                    let rel = String(f.standardizedFileURL.path.dropFirst(root.count + 1))
                    out.append(Source(rel: top + "/" + rel, size: Int64(v.fileSize ?? 0), url: f))
                    if out.count >= Proto.maxFiles { return out }
                }
            } else if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                out.append(Source(rel: safeName(url.lastPathComponent), size: Int64(size), url: url))
            }
        }
        return out
    }
    /// Somewhere to copy what's picked (from Photos, Files, the camera, another app) before it goes: the link reads it
    /// later, on its own threads. Old copies are cleared at start.
    static func outgoing() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("Outgoing").appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    static func clearOld() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Outgoing")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for d in dirs where ((try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < Date().addingTimeInterval(-6 * 3600) { try? FileManager.default.removeItem(at: d) }
    }
    /// A copy of a picked file (security-scoped, from Files or another app) in [outgoing].
    static func copyIn(_ url: URL, to dir: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = dir.appendingPathComponent(safeName(url.lastPathComponent))
        var error: NSError?; var ok = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.forUploading], error: &error) { real in
            ok = (try? FileManager.default.copyItem(at: real, to: dest)) != nil
        }
        if !ok { ok = (try? FileManager.default.copyItem(at: url, to: dest)) != nil }
        return ok ? dest : nil
    }
    /// Data (a pasted picture, text, a photo) as a file in [dir].
    static func write(_ data: Data, name: String, to dir: URL) -> URL? {
        let dest = dir.appendingPathComponent(safeName(name)); return (try? data.write(to: dest)) != nil ? dest : nil
    }
}

/// A small picture of a file for the island to show as it arrives (a JPEG within the protocol's limit).
enum Previews {
    static func of(_ url: URL, side: CGFloat = 120, limit: Int = Proto.previewLimit) async -> [UInt8]? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 1, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return jpeg(rep.uiImage, limit: limit)
    }
    static func jpeg(_ image: UIImage, side: CGFloat? = nil, limit: Int) -> [UInt8]? {
        var img = image
        if let side, max(image.size.width, image.size.height) > side {
            let k = side / max(image.size.width, image.size.height)
            let size = CGSize(width: max(1, (image.size.width * k).rounded()), height: max(1, (image.size.height * k).rounded()))
            let f = UIGraphicsImageRendererFormat(); f.scale = 1
            img = UIGraphicsImageRenderer(size: size, format: f).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        var q: CGFloat = 0.8
        while q > 0.15 { if let d = img.jpegData(compressionQuality: q), d.count <= limit { return [UInt8](d) }; q -= 0.12 }
        return nil
    }
}

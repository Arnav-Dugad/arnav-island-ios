import Foundation
import ImageIO
import IslandKit
import Photos
import UIKit
import UniformTypeIdentifiers

/// A photo (or screenshot) you just took shows on your PCs' islands, with Paste and Shelf there. Only its small picture goes
/// at first; the photo itself goes only when a PC asks for one it was told about, within ten minutes. On with Devices ›
/// Photos you take, which asks for access to Photos; it watches only while the app runs.
@MainActor
final class RecentPhotos: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = RecentPhotos()
    /// What each PC was told about (read from the link's threads when a PC asks).
    nonisolated static let told = Told()
    private var watching = false
    private var ids: [UInt64: String] = [:]
    private var announced: [String] = []
    private var nextId = UInt64.random(in: 1...(1 << 40))
    private var pending: Task<Void, Never>?

    var authorized: Bool { let s = PHPhotoLibrary.authorizationStatus(for: .readWrite); return s == .authorized || s == .limited }
    func requestAccess() async -> Bool { let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite); return s == .authorized || s == .limited }
    func sync() {
        let want = Hub.shared.prefs.recentPhotos && authorized
        if want && !watching { PHPhotoLibrary.shared().register(self); watching = true }
        else if !want && watching { PHPhotoLibrary.shared().unregisterChangeObserver(self); watching = false }
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            // A camera writes a photo in steps: look once they've settled.
            self.pending?.cancel(); self.pending = Task { try? await Task.sleep(for: .milliseconds(700)); if !Task.isCancelled { await self.check() } }
        }
    }

    private func check() async {
        let hub = Hub.shared
        let pcs = hub.peers.filter { $0.paired && !$0.phone && $0.online && $0.revision >= 8 }; guard !pcs.isEmpty else { return }
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "creationDate >= %@", Date().addingTimeInterval(-30) as NSDate)
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; o.fetchLimit = 3
        let found = PHAsset.fetchAssets(with: .image, options: o)
        var fresh: [PHAsset] = []
        found.enumerateObjects { a, _, _ in fresh.append(a) }
        for asset in fresh.reversed() where !announced.contains(asset.localIdentifier) {
            announced.append(asset.localIdentifier); if announced.count > 64 { announced.removeFirst() }
            guard let picture = await small(asset) else { continue }
            let id = nextId; nextId += 1; ids[id] = asset.localIdentifier
            let resource = PHAssetResource.assetResources(for: asset).first
            let name = jpegName(resource?.originalFilename ?? "Photo.jpg")
            let size = (resource?.value(forKey: "fileSize") as? CLong).map(Int64.init) ?? 0
            let frame = Frames.photo(id: id, name: name, size: size, width: asset.pixelWidth, height: asset.pixelHeight, picture: picture)
            for pc in pcs where await hub.notice(pc.id, frame) { Self.told.add(pc.id, id) }
        }
    }
    private func small(_ asset: PHAsset) async -> [UInt8]? {
        await withCheckedContinuation { c in
            let o = PHImageRequestOptions(); o.deliveryMode = .highQualityFormat; o.isNetworkAccessAllowed = false; o.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 480, height: 480), contentMode: .aspectFit, options: o) { image, _ in
                c.resume(returning: image.flatMap { Previews.jpeg($0, side: 480, limit: 90 * 1024) })
            }
        }
    }
    private func jpegName(_ n: String) -> String { ((n as NSString).deletingPathExtension.isEmpty ? "Photo" : (n as NSString).deletingPathExtension) + ".jpg" }

    /// A PC asked for a photo it was told about: the photo itself goes, as a JPEG (the PC may not read HEIC).
    func send(peer: String, id: UInt64, toShelf: Bool, ask: Int) {
        guard let local = ids[id], let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject else { return }
        let name = jpegName(PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Photo.jpg")
        let o = PHImageRequestOptions(); o.isNetworkAccessAllowed = true; o.version = .current; o.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, _ in
            guard let data else { return }
            let dir = Sources.outgoing(), dest = dir.appendingPathComponent(name)
            guard RecentPhotos.jpeg(data, to: dest) else { return }
            Task { @MainActor in await Hub.shared.send(peer, files: [dest], toShelf: toShelf, ask: ask) }
        }
    }
    /// Any picture as a JPEG, keeping its details (when it was taken, its orientation).
    nonisolated static func jpeg(_ data: Data, to dest: URL) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var out = props; out[kCGImageDestinationLossyCompressionQuality] = 0.92
        CGImageDestinationAddImageFromSource(d, src, 0, out as CFDictionary)
        return CGImageDestinationFinalize(d)
    }

    final class Told: @unchecked Sendable {
        private let lock = NSLock(); private var map: [String: [UInt64: Date]] = [:]
        func add(_ peer: String, _ id: UInt64) { lock.lock(); map[peer, default: [:]][id] = Date(); lock.unlock() }
        func has(_ peer: String, _ id: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return map[peer]?[id].map { Date().timeIntervalSince($0) < 600 } ?? false }
    }
    nonisolated func told(_ peer: String, _ id: UInt64) -> Bool { Self.told.has(peer, id) }
}

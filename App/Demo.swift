import IslandKit
import SwiftUI
import UIKit

/// The app with a made-up PC (launched with -demo): for screenshots and the simulator. No link starts; nothing is sent.
@MainActor
enum Demo {
    static let on = ProcessInfo.processInfo.arguments.contains("-demo")
    static func argument(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments; guard let i = a.firstIndex(of: "-" + name), i + 1 < a.count else { return nil }; return a[i + 1]
    }

    static func load(_ hub: Hub) {
        let cover = art()
        let bytes = cover.jpegData(compressionQuality: 0.85).map { [UInt8]($0) }
        hub.peers = [Sample.peer()]; hub.selected = Sample.pcId; hub.running = true; hub.internet = true
        hub.status = Sample.status(cover: bytes); hub.cover = cover; hub.palette = Art.palette(cover) ?? .standard
        hub.lyrics = Sample.lyrics()
        let stats = Sample.stats(); hub.pcStats = stats
        hub.statsTrail = stats.cpuHistory.enumerated().map { StatsPoint(at: Date().addingTimeInterval(-Double(stats.cpuHistory.count - $0.offset)), cpu: $0.element, gpu: $0.element * 0.5, download: $0.element * 90_000, upload: 20_000) }
        hub.pcControls = Sample.controls(); hub.controlsAt = Date()
        hub.pcBattery = Sample.battery(); hub.islandSettings = Sample.settings(); hub.outputs = Sample.outputs()
        hub.moments = [
            Moment(kind: 0, title: "Moodboard.png", from: "Studio PC", count: 1, size: 2_400_000, at: Date().addingTimeInterval(-120), files: []),
            Moment(kind: 1, title: "IMG_2041.jpg and 11 more", from: "Studio PC", count: 12, size: 48_000_000, at: Date().addingTimeInterval(-3600), files: []),
            Moment(kind: 2, title: "Invoice October.pdf", from: "Studio PC", count: 1, size: 184_000, at: Date().addingTimeInterval(-86_000), files: []),
        ]
        if argument("transfer") != nil { hub.transfers = [7: Transfer(id: 7, peer: Sample.pcId, name: "Studio PC", title: "Holiday.mov", done: 312_000_000, total: 540_000_000, outgoing: true, rate: 18_400_000)] }
        if let b = argument("banner") { hub.show(Banner(kind: .received, title: b, detail: "From Studio PC  ·  2.4 MB")) }
    }
    static var shelfPreview: [UInt8]? { art(side: 160).jpegData(compressionQuality: 0.7).map { [UInt8]($0) } }

    /// A cover: soft colour fields and rings, like an album's.
    static func art(side: CGFloat = 600) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { c in
            let g = c.cgContext, space = CGColorSpaceCreateDeviceRGB()
            let colors = [UIColor(red: 0.98, green: 0.45, blue: 0.55, alpha: 1).cgColor, UIColor(red: 0.45, green: 0.35, blue: 0.95, alpha: 1).cgColor, UIColor(red: 0.08, green: 0.1, blue: 0.3, alpha: 1).cgColor] as CFArray
            g.drawLinearGradient(CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!, start: .zero, end: CGPoint(x: side, y: side), options: [])
            for i in 0..<5 {
                let r = side * (0.12 + CGFloat(i) * 0.09)
                g.setStrokeColor(UIColor.white.withAlphaComponent(0.5 - CGFloat(i) * 0.08).cgColor); g.setLineWidth(side * 0.012)
                g.strokeEllipse(in: CGRect(x: side * 0.62 - r, y: side * 0.38 - r, width: r * 2, height: r * 2))
            }
            g.setFillColor(UIColor(red: 1, green: 0.85, blue: 0.5, alpha: 0.9).cgColor); g.fillEllipse(in: CGRect(x: side * 0.55, y: side * 0.31, width: side * 0.14, height: side * 0.14))
        }
    }
}

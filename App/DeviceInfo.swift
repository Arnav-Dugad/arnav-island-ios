import AVFoundation
import Foundation
import Network
import UIKit

/// This iPhone as the island shows it in its own view: the battery (level, charging, how long it lasts), Low Power Mode,
/// how warm it runs, storage, memory, the network, the sound (and where it plays: AirPods, a speaker), iOS, how long it has
/// been on, and what this app plays. Only readings iOS gives any app; nothing identifying beyond the model.
@MainActor
enum DeviceInfo {
    /// "iPhone 15", from the model's identifier (iOS no longer tells apps the name you gave it).
    static let modelName: String = {
        var u = utsname(); uname(&u)
        var id = withUnsafeBytes(of: &u.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { id = sim }
        let names: [String: String] = [
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
            "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,4": "iPhone Air",
        ]
        if let n = names[id] { return n }
        if id.hasPrefix("iPad") { return "iPad" }
        return UIDevice.current.model
    }()

    static func battery() -> (Int, Bool) {
        let d = UIDevice.current; d.isBatteryMonitoringEnabled = true
        let level = d.batteryLevel; let percent = level < 0 ? -1 : Int((level * 100).rounded())
        return (percent, d.batteryState == .charging || d.batteryState == .full)
    }

    static func read() -> [(String, String)] {
        var out: [(String, String)] = []
        let (percent, charging) = battery()
        if percent >= 0 { out.append(("Battery", "\(percent)%")) }
        out.append(("Charging", charging ? "Yes" : "No"))
        if let f = BatteryForecast.forecast() { out.append((f.charging ? "Full by" : "Lasts until", f.at.formatted(date: .omitted, time: .shortened))) }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { out.append(("Low Power Mode", "On")) }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "Cool"; case .fair: thermal = "Warm"; case .serious: thermal = "Hot"; case .critical: thermal = "Too hot"; @unknown default: thermal = "Unknown" }
        out.append(("Temperature", thermal))
        if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity {
            out.append(("Storage", "\(gb(free)) free of \(gb(Int64(total)))"))
        }
        if let free = freeMemory() { out.append(("Memory", "\(gb(free)) free of \(gb(Int64(ProcessInfo.processInfo.physicalMemory)))")) }
        out.append(("Network", NetWatch.shared.describe))
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.first
        let where_ = route.map { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver ? "speaker" : $0.portName } ?? "speaker"
        out.append(("Sound", "media \(Int((session.outputVolume * 100).rounded()))%  ·  \(where_)"))
        out.append(("iOS", UIDevice.current.systemVersion))
        out.append(("Uptime", uptime(ProcessInfo.processInfo.systemUptime)))
        out.append(("Model", modelName))
        if let p = Player.shared.nowPlayingLine { out.append(("Playing", p)) }
        return out
    }
    /// The readings a PC's Phone page asks for every two seconds: all of the above, and the screen.
    static func live() -> [(String, String)] {
        var out = read()
        out.append(("Screen", UIApplication.shared.applicationState == .background ? "off" : "on"))
        out.append(("Brightness", "\(Int((currentScreen?.brightness ?? 0.5) * 100))%"))
        return out
    }
    static var currentScreen: UIScreen? { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen }
    private static func gb(_ bytes: Int64) -> String { bytes >= 10 << 30 ? "\(bytes >> 30) GB" : String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    private static func uptime(_ s: TimeInterval) -> String { let m = Int(s / 60); return m < 60 ? "\(m) min" : m < 48 * 60 ? "\(m / 60) h \(m % 60) min" : "\(m / 1440) days" }
    /// Free and reclaimable memory, as the system counts its pages.
    private static func freeMemory() -> Int64? {
        var stats = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        guard r == KERN_SUCCESS else { return nil }
        var page: vm_size_t = 0; host_page_size(mach_host_self(), &page)
        return Int64(stats.free_count + stats.inactive_count + stats.purgeable_count) * Int64(page)
    }
}

/// The network this iPhone is on (Wi-Fi, mobile data), and when it changes (the link reconnects at once then).
final class NetWatch: @unchecked Sendable {
    static let shared = NetWatch()
    private let monitor = NWPathMonitor()
    private(set) var path: NWPath?
    var onChange: (() -> Void)?
    private init() {
        monitor.pathUpdateHandler = { [weak self] p in
            let changed = self?.path.map { !($0.status == p.status && $0.availableInterfaces.map(\.name) == p.availableInterfaces.map(\.name)) } ?? false
            self?.path = p
            if changed { DispatchQueue.main.async { self?.onChange?() } }
        }
        monitor.start(queue: DispatchQueue(label: "netwatch"))
    }
    var describe: String {
        guard let p = path, p.status == .satisfied else { return "Offline" }
        var s = p.usesInterfaceType(.wifi) ? "Wi-Fi" : p.usesInterfaceType(.cellular) ? "Mobile data" : p.usesInterfaceType(.wiredEthernet) ? "Ethernet" : "Online"
        if p.isConstrained { s += "  ·  Low Data Mode" }
        return s
    }
}

/// How long the battery lasts (or how soon it's full), from this iPhone's own recent history: the slope of the level over
/// the last stretch at the same state, when that stretch is long enough to say.
@MainActor
enum BatteryForecast {
    struct Point: Codable { let at: Date; let percent: Int; let charging: Bool }
    struct Forecast { let at: Date; let charging: Bool }
    private static let key = "batteryHistory"
    private static var cache: [Point]?
    private static var points: [Point] {
        get { if let cache { return cache }; let p = AppGroup.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Point].self, from: $0) } ?? []; cache = p; return p }
        set { cache = newValue; if let d = try? JSONEncoder().encode(newValue) { AppGroup.defaults.set(d, forKey: key) } }
    }
    static func record(_ percent: Int, _ charging: Bool) {
        guard percent >= 0 else { return }
        var p = points
        if let last = p.last, last.percent == percent, last.charging == charging { return }
        p.append(Point(at: Date(), percent: percent, charging: charging))
        let cutoff = Date().addingTimeInterval(-36 * 3600); p.removeAll { $0.at < cutoff }
        if p.count > 400 { p.removeFirst(p.count - 400) }
        points = p
    }
    static func forecast() -> Forecast? {
        let p = points; guard let last = p.last else { return nil }
        // The stretch at the current state.
        var run: [Point] = []
        for q in p.reversed() { if q.charging != last.charging { break }; run.insert(q, at: 0) }
        guard run.count >= 3, let first = run.first, last.at.timeIntervalSince(first.at) >= 15 * 60 else { return nil }
        let t0 = first.at.timeIntervalSince1970
        let xs = run.map { $0.at.timeIntervalSince1970 - t0 }, ys = run.map { Double($0.percent) }
        let n = Double(run.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }, sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx // percent a second
        let (percent, charging) = DeviceInfo.battery(); guard percent >= 0 else { return nil }
        if charging { guard slope > 0.0003, percent < 100 else { return nil }; let s = Double(100 - percent) / slope; return s < 12 * 3600 ? Forecast(at: Date().addingTimeInterval(s), charging: true) : nil }
        guard slope < -0.00005 else { return nil }
        let s = Double(percent) / -slope; return s < 72 * 3600 ? Forecast(at: Date().addingTimeInterval(s), charging: false) : nil
    }
}

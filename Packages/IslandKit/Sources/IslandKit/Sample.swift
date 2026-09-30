import Foundation

/// A made-up PC and what it reports, for the app's demo mode (screenshots, the simulator): nothing real, nothing sent.
public enum Sample {
    public static let pcId = "5a17e0c0ffee0000000000000000beef"
    public static func peer(name: String = "Studio PC", online: Bool = true) -> PeerView {
        PeerView(id: pcId, name: name, paired: true, online: online, phone: false, version: Proto.version, revision: Proto.revision, internet: true, path: 1, rtt: 38, relays: 3, v6: false, lan: false)
    }
    public static func status(cover: [UInt8]?, playing: Bool = true) -> PcStatus {
        PcStatus(available: true, playing: playing, canPrevious: true, canNext: true, canToggle: true, canSeek: true, muted: false, charging: true, batteryPresent: true,
                 position: 71, duration: 214, volume: 42, battery: 86, cpu: 18, title: "Glass Horizons", artist: "Aurora Fields", app: "Spotify", pcName: "Studio PC", weather: "Light rain, 18°",
                 cover: cover, coverHash: cover.map { Crypto.sha256($0) }, at: Date(), clipboard: true)
    }
    public static func lyrics() -> Lyrics {
        let words = ["Under a sky of glass we run", "Chasing the light of a hidden sun", "Every island calls my name", "Nothing here will stay the same", "Hold on, hold on", "Till the morning comes"]
        let lines = words.enumerated().map { i, t -> LyricsLine in
            let start = 60 + Double(i) * 5.5
            var at = 0; var ws: [WordTime] = []
            for (k, w) in t.split(separator: " ").enumerated() { ws.append(WordTime(time: start + Double(k) * 0.55, at: at)); at += w.count + 1 }
            return LyricsLine(time: start, text: t, words: ws)
        }
        return Lyrics(state: 2, key: "Glass Horizons\tAurora Fields", lines: lines)
    }
    public static func stats() -> PcStats {
        let cpu = (0..<60).map { 18 + 14 * sin(Double($0) / 6) + Double($0 % 7) }
        return PcStats(cpu: 23, gpu: 12, ramUsedGiB: 13.4, ramTotalGiB: 32, ramPercent: 42, diskUsedPercent: 61, diskFreeGiB: 372, diskTotalGiB: 953, download: 2_400_000, upload: 310_000,
                       uptime: 3 * 86400 + 5 * 3600, logical: 16, battery: 86, charging: true, batteryMinutes: 0,
                       cpuHistory: cpu, gpuHistory: cpu.map { $0 * 0.5 }, downloadHistory: cpu.map { $0 * 90_000 },
                       name: "Studio PC", model: "Aurora Book Pro 16", os: "Windows 11 Pro 25H2", cpuName: "Ryzen 9 8945HS", gpuName: "Radeon 780M",
                       cores: (0..<16).map { 10 + Double(($0 * 37) % 70) })
    }
    public static func battery() -> PcBattery {
        let now = Int64(Date().timeIntervalSince1970)
        let day = (0..<48).map { i -> BatteryPoint in let charging = i > 36; return BatteryPoint(at: now - Int64(48 - i) * 1800, percent: charging ? 40 + (i - 36) * 4 : 100 - i * 2 + (i > 20 ? 0 : 0), charging: charging) }
        return PcBattery(percent: 86, present: true, online: true, charging: true, saver: false, critical: false, minutesLeft: 0, minutesToFull: 24,
                         designMwh: 76_000, fullMwh: 71_400, remainingMwh: 61_400, rateMw: 38_000, voltageMv: 17_200, cycles: 212, temperatureDeciK: 3046, health: 0.94, healthBefore: 0.941,
                         chemistry: "LiP", manufacturer: "Aurora", name: "AB16", day: day)
    }
    public static func controls() -> PcControls {
        PcControls(wifi: 1, bluetooth: 1, dark: 1, brightness: 70, volume: 42, muted: false, micAvailable: true, micMuted: false, focusRunning: true, focusFinished: false, focusMode: 0, focusDuration: 1500, focusShown: 1112, busy: 0)
    }
    public static func settings() -> IslandSettings {
        func item(_ section: Int, _ control: Int, _ key: String, _ title: String, _ detail: String, value: Int = 1, lo: Int = 0, hi: Int = 1, step: Int = 1, unit: String = "", options: [String] = [], colours: [Int] = [], action: Int = 0) -> IslandSetting {
            IslandSetting(section: section, control: control, key: key, title: title, detail: detail, lo: lo, hi: hi, step: step, value: value, action: action, unit: unit, options: options, colours: colours)
        }
        return IslandSettings(sections: ["General", "Layout", "Colours", "Motion", "Text", "Music", "Battery", "Home", "Privacy & productivity", "About"], items: [
            item(0, 0, "startup", "Start with Windows", "Opens the island when you sign in"),
            item(0, 1, "hoverDelay", "Open on hover after", "How long the pointer rests on the island", value: 700, lo: 0, hi: 2000, step: 50, unit: " ms"),
            item(1, 2, "position", "Where it sits", "", value: 1, hi: 2, options: ["Left", "Centre", "Right"]),
            item(2, 4, "accent", "Accent", "", value: 0, hi: 4, options: ["Mint", "Periwinkle", "Rose", "Amber", "Snow"], colours: [0xA5D8C5, 0x8FA8FF, 0xFF8FB1, 0xFFC04D, 0xF5F7FA]),
            item(3, 0, "reduceMotion", "Reduce motion", "Calmer animations", value: 0),
            item(5, 0, "lyrics", "Lyrics", "Word by word, from the internet"),
            item(8, 0, "sharing", "Share with my PCs", "Files, the Shelf and the remote"),
            item(8, 0, "phoneControl", "My phone can control this PC", "The remote, the trackpad and the screen"),
            item(8, 0, "relay", "Reach my PCs anywhere", "Through free relays, end-to-end encrypted"),
        ])
    }
    public static func outputs() -> [AudioOutput] {
        [AudioOutput(id: "spk", name: "Speakers (Realtek)", current: false, form: 1), AudioOutput(id: "buds", name: "Aurora Buds", current: true, form: 3), AudioOutput(id: "hdmi", name: "Studio Display", current: false, form: 1)]
    }
    public static func shelf(preview: [UInt8]?) -> ShelfList {
        ShelfList(shared: true, items: [ShelfItem(name: "Moodboard.png", size: 2_400_000, folder: false, preview: preview), ShelfItem(name: "Invoice October.pdf", size: 184_000, folder: false, preview: nil),
                                        ShelfItem(name: "Holiday photos", size: 812_000_000, folder: true, preview: nil), ShelfItem(name: "Notes.txt", size: 3_200, folder: false, preview: nil)], error: nil)
    }
}

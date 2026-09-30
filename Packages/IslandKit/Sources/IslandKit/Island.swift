import Foundation

/// What a PC tells this app, and the frames this app sends it: the island's payloads (ShareService.h), read exactly as the
/// Android app's Island.kt, Link.kt and Models.kt read them.
public enum IslandWire {
    public static let wifi = 1, bluetooth = 2, dark = 3, airplane = 4, brightness = 5, volume = 6, mute = 7, mic = 8, lock = 9, sleep = 10, restart = 11, shutDown = 12, emptyBin = 13
    public static let focus = 15, breakTime = 16, focusToggle = 17, focusReset = 18, stopwatch = 19
    public static let pages = ["Home", "Media", "Stats", "Focus", "Settings", "Shelf", "Audio", "Controls", "Phone"]

    private static func list<T>(_ n: Int?, _ f: () -> T?) -> [T]? {
        guard let n else { return nil }
        var out: [T] = []; out.reserveCapacity(n)
        for _ in 0..<n { guard let v = f() else { return nil }; out.append(v) }
        return out
    }
    private static func pct(_ b: Int) -> Double { b == 255 ? -1 : Double(b) }

    public static func stats(_ p: [UInt8]) -> PcStats? {
        let r = Reader(p); guard r.u8() == 1 else { return nil }
        guard let v = list(10, { r.f64() }), let uptime = r.i64(), let logical = r.u16(), let battery = r.i8(), let charging = r.u8(), let minutes = r.f64(), let n = r.u8() else { return nil }
        guard let cpu = list(n, { r.u8().map(pct) }), let gpu = list(n, { r.u8().map(pct) }), let down = list(n, { r.u32().map { Double($0) } }), let texts = list(5, { r.string(4096) }) else { return nil }
        var cores: [Double] = []
        if let c = r.u8() { cores = list(c, { r.u8().map(pct) }) ?? [] }
        return PcStats(cpu: v[0], gpu: v[1], ramUsedGiB: v[2], ramTotalGiB: v[3], ramPercent: v[4], diskUsedPercent: v[5], diskFreeGiB: v[6], diskTotalGiB: v[7], download: v[8], upload: v[9],
                       uptime: uptime, logical: logical, battery: battery, charging: charging != 0, batteryMinutes: minutes, cpuHistory: cpu, gpuHistory: gpu, downloadHistory: down,
                       name: texts[0], model: texts[1], os: texts[2], cpuName: texts[3], gpuName: texts[4], cores: cores)
    }
    public static func battery(_ p: [UInt8]) -> PcBattery? {
        let r = Reader(p); guard r.u8() == 1 else { return nil }
        guard let percent = r.i8(), let flags = r.u8(), let left = r.i32(), let toFull = r.i32(), let caps = list(5, { r.i64() }), let cycles = r.u32(), let temp = r.i32(),
              let health = r.f64(), let before = r.f64(), let texts = list(3, { r.string(1024) }), let n = r.u16() else { return nil }
        guard let day = list(n, { () -> BatteryPoint? in guard let t = r.i64(), let pc = r.u8(), let ch = r.u8() else { return nil }; return BatteryPoint(at: t, percent: pc, charging: ch != 0) }) else { return nil }
        return PcBattery(percent: percent, present: flags & 1 != 0, online: flags & 2 != 0, charging: flags & 4 != 0, saver: flags & 8 != 0, critical: flags & 16 != 0,
                         minutesLeft: left, minutesToFull: toFull, designMwh: caps[0], fullMwh: caps[1], remainingMwh: caps[2], rateMw: caps[3], voltageMv: caps[4],
                         cycles: cycles, temperatureDeciK: temp, health: health, healthBefore: before, chemistry: texts[0], manufacturer: texts[1], name: texts[2], day: day)
    }
    public static func focus(_ p: [UInt8], at: Date = Date()) -> FocusState? {
        let r = Reader(p); guard let mode = r.u8(), let running = r.u8(), let finished = r.u8(), let shown = r.f64(), let duration = r.f64(), let pc = r.string(512) else { return nil }
        return FocusState(mode: mode, running: running != 0, finished: finished != 0, shown: shown, duration: duration, pcName: pc, at: at)
    }
    public static func settings(_ p: [UInt8]) -> IslandSettings? {
        let r = Reader(p); guard r.u8() == 1, let sections = list(r.u8(), { r.string(1024) }) else { return nil }
        guard let items = list(r.u16(), { () -> IslandSetting? in
            guard let section = r.u8(), let control = r.u8(), let key = r.string(256), let title = r.string(1024), let detail = r.string(2048),
                  let lo = r.i32(), let hi = r.i32(), let step = r.i32(), let value = r.i32(), let action = r.u8(), let unit = r.string(128),
                  let options = list(r.u8(), { r.string(512) }), let colours = list(r.u8(), { r.u32() }) else { return nil }
            return IslandSetting(section: section, control: control, key: key, title: title, detail: detail, lo: lo, hi: hi, step: step, value: value, action: action, unit: unit, options: options, colours: colours)
        }) else { return nil }
        return IslandSettings(sections: sections, items: items)
    }
    public static func controls(_ p: [UInt8]) -> PcControls? {
        let r = Reader(p); guard r.u8() == 1 else { return nil }
        guard let wifi = r.i8(), let bt = r.i8(), let dark = r.i8(), let brightness = r.i8(), let volume = r.u8(), let flags = r.u8(), let mode = r.u8(), let duration = r.f64(), let shown = r.f64(), let busy = r.u8() else { return nil }
        return PcControls(wifi: wifi, bluetooth: bt, dark: dark, brightness: brightness, volume: volume, muted: flags & 1 != 0, micAvailable: flags & 2 != 0, micMuted: flags & 4 != 0,
                          focusRunning: flags & 8 != 0, focusFinished: flags & 16 != 0, focusMode: mode, focusDuration: duration, focusShown: shown, busy: busy)
    }
    public static func commands(_ p: [UInt8]) -> CommandResults? {
        let r = Reader(p); guard r.u8() == 1, let final = r.u8() else { return nil }
        guard let rows = list(r.u8(), { () -> CommandRow? in
            guard let kind = r.u8(), let confirm = r.u8(), let title = r.string(2048), let detail = r.string(2048), let answer = r.string(512) else { return nil }
            return CommandRow(kind: kind, confirm: confirm != 0, title: title, detail: detail, answer: answer)
        }) else { return nil }
        return CommandResults(final: final != 0, rows: rows)
    }
    public static func outcome(_ p: [UInt8]) -> CommandOutcome? { let r = Reader(p); guard let o = r.u8(), let m = r.string(2048) else { return nil }; return CommandOutcome(outcome: o, message: m) }
    public static func outputs(_ p: [UInt8]) -> [AudioOutput]? {
        let r = Reader(p); guard r.u8() == 1 else { return nil }
        return list(r.u8(), { () -> AudioOutput? in
            guard let id = r.string(2048), let name = r.string(1024), let cur = r.u8(), let form = r.i8() else { return nil }
            return AudioOutput(id: id, name: name, current: cur != 0, form: form)
        })
    }
    public static func value(_ p: [UInt8]) -> Int? { Reader(p).i32() }

    /// The status payload: u16 flags, f64 position, f64 duration, u8 volume, i8 battery, u8 cpu (255 unknown), then the cover
    /// (u8 0 none / 1 included with 32-byte hash and u32 length / 2 unchanged), then u32 length and UTF-8 lines: title,
    /// artist, app, the PC's name, a weather line.
    public static func status(_ p: [UInt8], previous: PcStatus?) -> PcStatus? {
        let r = Reader(p)
        guard let flags = r.u16(), let position = r.f64(), let duration = r.f64(), let volume = r.u8(), let battery = r.i8(), let cpu = r.u8(), let kind = r.u8() else { return nil }
        var cover: [UInt8]? = nil, hash: [UInt8]? = nil
        if kind == 1 { guard let h = r.bytes(32), let c = r.blob(Proto.coverLimit) else { return nil }; hash = h; cover = c }
        else if kind == 2 { cover = previous?.cover; hash = previous?.coverHash }
        guard let text = r.string(64 * 1024) else { return nil }
        let lines = text.components(separatedBy: "\n") + ["", "", "", "", ""]
        func bit(_ i: Int) -> Bool { flags & (1 << i) != 0 }
        return PcStatus(available: bit(0), playing: bit(1), canPrevious: bit(2), canNext: bit(3), canToggle: bit(4), canSeek: bit(7), muted: bit(5), charging: bit(6), batteryPresent: bit(8),
                        position: max(0, position), duration: max(0, duration), volume: min(100, max(0, volume)), battery: battery, cpu: cpu == 255 ? -1 : cpu,
                        title: lines[0], artist: lines[1], app: lines[2], pcName: lines[3], weather: lines[4], cover: (cover?.isEmpty ?? true) ? nil : cover, coverHash: hash, at: Date(), clipboard: bit(9))
    }
    public static func lyrics(_ p: [UInt8]) -> Lyrics? {
        let r = Reader(p); guard let state = r.u8(), let key = r.string(4096), let n = r.u32(), n <= 400 else { return nil }
        var lines: [LyricsLine] = []
        for _ in 0..<n {
            guard let time = r.f64(), let text = r.string(4096), let wn = r.u8() else { return nil }
            var words: [WordTime] = []
            for _ in 0..<wn { guard let wt = r.f64(), let at = r.u16() else { return nil }; words.append(WordTime(time: wt, at: at)) }
            lines.append(LyricsLine(time: time, text: text, words: words))
        }
        return Lyrics(state: state, key: key, lines: lines)
    }
}

/// The frames this app sends a PC.
public enum Frames {
    public static func status(battery: Int, charging: Bool) -> [UInt8] { Wire().u8(Proto.frameNotice).u8(Proto.noticeStatus).u8(battery).u8(charging ? 1 : 0).build() }
    /// This device's readings for the island, one "name<TAB>value" a line.
    public static func details(_ d: [(String, String)]) -> [UInt8] {
        let text = d.map { $0.0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") + "\t" + $0.1.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        return Wire().u8(Proto.frameNotice).u8(Proto.noticeDetails).string(String(text.prefix(12_000))).build()
    }
    public static func notification(app: String, title: String, text: String, phone: String, urgent: Bool, icon: [UInt8]? = nil) -> [UInt8] {
        let lines = [String(app.prefix(80)), String(title.prefix(200)), String(text.prefix(600)), String(phone.prefix(64))].map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        return Wire().u8(Proto.frameNotice).u8(Proto.noticeNotification).u8(urgent ? 1 : 0).string(lines).blob((icon?.count ?? 0) <= 24 * 1024 ? (icon ?? []) : []).string("").u8(0).build()
    }
    public static func gone(_ key: String) -> [UInt8] { Wire().u8(Proto.frameNotice).u8(Proto.noticeGone).string(String(key.prefix(200))).build() }
    /// A photo just taken here, with its picture.
    public static func photo(id: UInt64, name: String, size: Int64, width: Int, height: Int, picture: [UInt8]) -> [UInt8] {
        Wire().u8(Proto.frameNotice).u8(Proto.noticePhoto).u64(id).string(String(name.prefix(200))).i64(size).u16(min(65535, max(0, width))).u16(min(65535, max(0, height))).blob(picture).build()
    }
    /// A web page where it was scrolled to (0..1, below 0 unknown).
    public static func page(url: String, title: String, scroll: Float) -> [UInt8] { Wire().f32(scroll).string(String(url.prefix(4000))).string(String(title.prefix(300))).build() }
    public static func move(_ dx: Int, _ dy: Int) -> [UInt8] { Wire().u8(Proto.inputMove).u16(clamp16(dx) & 0xFFFF).u16(clamp16(dy) & 0xFFFF).build() }
    /// button: 0 left, 1 right, 2 middle; state: 0 up, 1 down, 2 a click.
    public static func button(_ button: Int, _ state: Int) -> [UInt8] { Wire().u8(Proto.inputButton).u8(button).u8(state).build() }
    /// In wheel units (120 a notch).
    public static func scroll(_ vertical: Int, _ horizontal: Int) -> [UInt8] { Wire().u8(Proto.inputScroll).u16(clamp16(vertical) & 0xFFFF).u16(clamp16(horizontal) & 0xFFFF).build() }
    public static func text(_ t: String) -> [UInt8] { Wire().u8(Proto.inputText).text(String(t.prefix(2000))).build() }
    /// A Windows virtual-key code, pressed and let go (state 2), or down (1) or up (0).
    public static func key(_ vk: Int, _ state: Int = 2) -> [UInt8] { Wire().u8(Proto.inputKey).u16(vk).u8(state).build() }
    /// A point on the PC's screen as it's shown here (0 to 1 each way).
    public static func point(_ x: Double, _ y: Double) -> [UInt8] { Wire().u8(Proto.inputPoint).u16(Int(min(1, max(0, x)) * 65535)).u16(Int(min(1, max(0, y)) * 65535)).build() }
    static func clamp16(_ v: Int) -> Int { max(-32768, min(32767, v)) }
}

/// Windows virtual-key codes.
public enum VK { public static let back = 0x08, tab = 0x09, enter = 0x0D, shift = 0x10, control = 0x11, alt = 0x12, escape = 0x1B, pageUp = 0x21, pageDown = 0x22, end = 0x23, home = 0x24, left = 0x25, up = 0x26, right = 0x27, down = 0x28, delete = 0x2E, win = 0x5B }

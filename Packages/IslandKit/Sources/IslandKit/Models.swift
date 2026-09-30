import Foundation

/// A paired PC (or phone): how it's reached and what it runs.
public struct PeerView: Identifiable, Equatable, Hashable {
    public let id: String
    public var name: String
    public var paired: Bool
    public var online: Bool
    public var phone: Bool
    public var version: Int
    public var revision: Int
    /// Reached over the internet: path 1 through the relay, 2 directly; its round trip (ms); relays it's heard on; IPv6; on this network.
    public var internet: Bool
    public var path: Int
    public var rtt: Double
    public var relays: Int
    public var v6: Bool
    public var lan: Bool
    /// Revision 2 (Arnav Island 0.19 and later) answers the remote, notices and find my phone.
    public var remote: Bool { version >= Proto.version && revision >= 2 }
}

/// Music handed from one device to another: what plays, where it is, and (for a song the island plays) its file.
public struct Handoff: Equatable {
    public var title: String, artist: String, album: String, app: String, fileName: String
    public var position: Double, duration: Double, playing: Bool, fileSize: Int64
    public var cover: [UInt8]?
    public init(title: String, artist: String = "", album: String = "", app: String = "", fileName: String = "", position: Double = 0, duration: Double = 0, playing: Bool = true, fileSize: Int64 = 0, cover: [UInt8]? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.app = app; self.fileName = fileName
        self.position = position; self.duration = duration; self.playing = playing; self.fileSize = fileSize; self.cover = cover
    }
}

public struct ShelfItem: Equatable, Hashable { public let name: String; public let size: Int64; public let folder: Bool; public let preview: [UInt8]? }
public struct ShelfList: Equatable { public let shared: Bool; public let items: [ShelfItem]; public let error: String? }

/// What the PC reports for the remote: its media, sound, battery and a few readings.
public struct PcStatus: Equatable {
    public var available, playing, canPrevious, canNext, canToggle, canSeek, muted, charging, batteryPresent: Bool
    public var position, duration: Double
    public var volume, battery, cpu: Int
    public var title, artist, app, pcName, weather: String
    public var cover: [UInt8]?, coverHash: [UInt8]?
    /// When this was read, for moving the position on while it plays.
    public var at: Date
    /// The island's universal clipboard is on.
    public var clipboard: Bool
    public func positionNow(_ now: Date = Date()) -> Double { playing && duration > 0 ? min(duration, position + now.timeIntervalSince(at)) : position }
}

public struct RemoteReply { public let status: Int; public let payload: [UInt8]; public var ok: Bool { status == Proto.ok } }

/// The song's lyrics from the PC: state 0 off there, 1 being looked for, 2 found, 3 none; key "title<TAB>artist".
public struct Lyrics: Equatable { public var state: Int; public var key: String; public var lines: [LyricsLine] }
public struct LyricsLine: Equatable, Hashable { public let time: Double; public let text: String; public let words: [WordTime] }
public struct WordTime: Equatable, Hashable { public let time: Double; public let at: Int }

/// The PC's numbers, live, with their last samples, and what the PC is.
public struct PcStats: Equatable {
    public var cpu, gpu, ramUsedGiB, ramTotalGiB, ramPercent, diskUsedPercent, diskFreeGiB, diskTotalGiB, download, upload: Double
    public var uptime: Int64, logical: Int, battery: Int, charging: Bool, batteryMinutes: Double
    public var cpuHistory: [Double], gpuHistory: [Double], downloadHistory: [Double]
    public var name, model, os, cpuName, gpuName: String
    public var cores: [Double]
}
/// The PC's battery in full. Capacities in mWh (0 unknown); rate in mW (negative draining); health 0..1 (-1 unknown).
public struct PcBattery: Equatable {
    public var percent: Int, present, online, charging, saver, critical: Bool
    public var minutesLeft, minutesToFull: Int
    public var designMwh, fullMwh, remainingMwh, rateMw, voltageMv: Int64
    public var cycles: Int, temperatureDeciK: Int, health, healthBefore: Double
    public var chemistry, manufacturer, name: String
    /// The last day: seconds since 1970, percent, charging.
    public var day: [BatteryPoint]
}
public struct BatteryPoint: Equatable, Hashable { public let at: Int64; public let percent: Int; public let charging: Bool }
/// What a PC tells this device about its focus clock. mode 0 focus, 1 break, 2 stopwatch.
public struct FocusState: Equatable, Codable { public var mode: Int, running: Bool, finished: Bool, shown: Double, duration: Double, pcName: String, at: Date }
/// One of the island's settings. control: 0 switch, 1 slider, 2 choice, 3 stepper, 4 swatch, 5 button.
public struct IslandSetting: Equatable, Identifiable {
    public var id: String { key + "|" + title }
    public var section, control: Int, key, title, detail: String
    public var lo, hi, step, value, action: Int, unit: String, options: [String], colours: [Int]
}
public struct IslandSettings: Equatable { public var sections: [String]; public var items: [IslandSetting] }
/// The island's Controls page, the volume and its focus clock. Radios and dark mode: 1 on, 0 off, -1 unknown, -2 none.
public struct PcControls: Equatable {
    public var wifi, bluetooth, dark, brightness, volume: Int
    public var muted, micAvailable, micMuted, focusRunning, focusFinished: Bool
    public var focusMode: Int, focusDuration, focusShown: Double, busy: Int
    public var airplane: Bool { wifi == 0 && (bluetooth == 0 || bluetooth == -2) }
}
public struct CommandRow: Equatable, Hashable { public let kind: Int; public let confirm: Bool; public let title, detail, answer: String }
public struct CommandResults: Equatable { public let final: Bool; public let rows: [CommandRow] }
/// What running one did: 0 done, 1 needs a yes first (message asks), 2 failed, 3 the results changed.
public struct CommandOutcome: Equatable { public let outcome: Int; public let message: String }
public struct AudioOutput: Equatable, Identifiable { public let id: String; public let name: String; public var current: Bool; public let form: Int }

public enum LinkEvent {
    case peers([PeerView])
    /// The six digits both show. confirmed: this device already said yes (it scanned that PC's QR code); only the PC asks.
    case pairCode(peer: String, name: String, code: Int, confirmed: Bool)
    case paired(peer: String, name: String, ok: Bool, detail: String)
    case offer(transfer: Int, peer: String, name: String, title: String, count: Int, size: Int64, folder: Bool)
    case progress(transfer: Int, peer: String, name: String, title: String, done: Int64, total: Int64, outgoing: Bool)
    case received(transfer: Int, peer: String, name: String, title: String, count: Int, size: Int64, files: [URL], taken: Bool)
    case sent(transfer: Int, peer: String, name: String, title: String, count: Int, size: Int64)
    case failed(transfer: Int, peer: String, name: String, title: String, detail: String, outgoing: Bool)
    case music(transfer: Int, peer: String, name: String, music: Handoff)
    case musicFile(transfer: Int, peer: String, name: String, music: Handoff, file: URL)
    case ring(peer: String, name: String)
    case photoRequested(peer: String, name: String)
    case internet(Bool)
}

/// Something to send: its path as the other side will keep it ("Photos/a.jpg"), its size and where its bytes are.
public struct Source { public let rel: String; public let size: Int64; public let url: URL
    public init(rel: String, size: Int64, url: URL) { self.rel = rel; self.size = size; self.url = url } }

/// Where received files go.
public protocol Inbox: AnyObject {
    /// A free name for a top-level folder ("Photos (2)").
    func folder(_ name: String) -> String
    /// A file at these safe path parts; nil when it can't be made.
    func create(_ parts: [String], size: Int64) -> Sink?
    func song(_ name: String, size: Int64) -> Sink?
    func room(_ bytes: Int64) -> Bool
}
public protocol Sink: AnyObject {
    func write(_ b: ArraySlice<UInt8>) -> Bool
    /// Keeps the file under its name: where it is, or nil when it couldn't be kept.
    func commit() -> URL?
    func abort()
}

public struct StoredPeer: Codable, Equatable { public var id: String; public var key: [UInt8]; public var name: String; public var phone: Bool; public var revision: Int
    public init(id: String, key: [UInt8], name: String, phone: Bool, revision: Int) { self.id = id; self.key = key; self.name = name; self.phone = phone; self.revision = revision } }
public struct StoredIdentity { public let id: [UInt8]; public let key: IdentityKey
    public init(id: [UInt8], key: IdentityKey) { self.id = id; self.key = key } }

/// Keeps the identity and the paired devices.
public protocol LinkStore: AnyObject {
    func loadIdentity() -> StoredIdentity?
    func saveIdentity(_ identity: StoredIdentity) -> Bool
    func loadPeers() -> [StoredPeer]
    func savePeers(_ peers: [StoredPeer])
}

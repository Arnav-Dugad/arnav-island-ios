import ActivityKit
import Foundation
import IslandKit
import UIKit
import WidgetKit

/// What plays on your PC, a file on its way and your PC's focus clock, in the Dynamic Island and on the Lock Screen.
/// Updated only when something you'd see changes (the song's clock runs by itself there).
@MainActor
final class LiveActivities {
    static let shared = LiveActivities()
    private var playing: Activity<NowPlayingAttributes>?
    private var lastPlaying: NowPlayingAttributes.ContentState?
    private var idleSince: Date?
    private var transfers: [Int: Activity<TransferAttributes>] = [:]
    private var transferAt: [Int: Date] = [:]
    private var focusActivity: Activity<FocusAttributes>?
    private init() {}

    private var enabled: Bool { Hub.shared.prefs.liveActivity && ActivityAuthorizationInfo().areActivitiesEnabled }
    private var foreground: Bool { UIApplication.shared.applicationState == .active }

    func sync() {
        // Ones left from before (the app was closed) are picked up again.
        if playing == nil { playing = Activity<NowPlayingAttributes>.activities.first }
        if focusActivity == nil { focusActivity = Activity<FocusAttributes>.activities.first }
        if !enabled { endAll() }
    }
    func endAll() {
        for a in Activity<NowPlayingAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        for a in Activity<TransferAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        for a in Activity<FocusAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        playing = nil; lastPlaying = nil; transfers = [:]; focusActivity = nil
    }

    func nowPlaying(_ s: PcStatus, pc: PeerView) {
        guard enabled else { return }
        guard s.available, !s.title.isEmpty else {
            // Nothing plays: it goes after a minute of that.
            if idleSince == nil { idleSince = Date() } else if Date().timeIntervalSince(idleSince!) > 60, let a = playing { playing = nil; lastPlaying = nil; Task { await a.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        idleSince = nil
        let pos = s.positionNow()
        let state = NowPlayingAttributes.ContentState(title: s.title, artist: s.artist, playing: s.playing, started: Date().addingTimeInterval(-pos), duration: s.duration, pausedAt: pos, accent: Hub.shared.palette.accent.hexString, hasCover: s.cover != nil)
        if let a = playing, a.activityState == .active {
            guard let last = lastPlaying else { lastPlaying = state; Task { await a.update(ActivityContent(state: state, staleDate: nil)) }; return }
            let jumped = abs(last.started.timeIntervalSince(state.started)) > 2.5 && s.playing
            if last.title != state.title || last.artist != state.artist || last.playing != state.playing || last.accent != state.accent || last.hasCover != state.hasCover || jumped || (!s.playing && abs(last.pausedAt - pos) > 1) {
                lastPlaying = state; Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
            }
        } else if foreground && s.playing {
            playing = try? Activity.request(attributes: NowPlayingAttributes(pcName: pc.name), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            lastPlaying = state
        }
    }
    /// The PC went away or another was chosen.
    func stopPlaying() { if let a = playing { playing = nil; lastPlaying = nil; Task { await a.end(nil, dismissalPolicy: .immediate) } } }

    func transfer(_ t: Transfer) {
        guard enabled, t.total >= 8 << 20 else { return }
        let state = TransferAttributes.ContentState(done: t.done, total: t.total, rate: t.rate, finished: false, failed: false)
        if let a = transfers[t.id] {
            if Date().timeIntervalSince(transferAt[t.id] ?? .distantPast) < 1 { return }
            transferAt[t.id] = Date(); Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
        } else if foreground {
            transfers[t.id] = try? Activity.request(attributes: TransferAttributes(title: t.title, pcName: t.name, outgoing: t.outgoing), content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            transferAt[t.id] = Date()
        }
    }
    func transferEnded(_ t: Transfer, ok: Bool) {
        guard let a = transfers.removeValue(forKey: t.id) else { return }; transferAt[t.id] = nil
        let state = TransferAttributes.ContentState(done: ok ? t.total : t.done, total: t.total, rate: 0, finished: ok, failed: !ok)
        Task { await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(4))) }
    }

    func focus(_ f: FocusState) {
        guard enabled else { return }
        let end = Hub.shared.focusEnd(f)
        let state = FocusAttributes.ContentState(mode: f.mode, running: f.running, ends: end, shown: f.shown, duration: f.duration)
        if !f.running && !f.finished && f.shown <= 0 { if let a = focusActivity { focusActivity = nil; Task { await a.end(nil, dismissalPolicy: .immediate) } }; return }
        if f.finished { if let a = focusActivity { focusActivity = nil; Task { await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8))) } }; return }
        if let a = focusActivity { Task { await a.update(ActivityContent(state: state, staleDate: f.running && f.mode != 2 ? end : nil)) } }
        else if foreground || KeepAlive.shared.on {
            focusActivity = try? Activity.request(attributes: FocusAttributes(pcName: f.pcName), content: ActivityContent(state: state, staleDate: f.running && f.mode != 2 ? end : nil), pushType: nil)
        }
    }
}

/// What the widgets, Control Center and Siri show of your PC, written for them as the app sees it.
@MainActor
final class Snapshotter {
    static let shared = Snapshotter()
    private var snap = Snapshot.load()
    private var lastReload = Date.distantPast, pending: Task<Void, Never>?
    private var coverHash: [UInt8]?
    private init() {}

    func status(_ s: PcStatus, pc: PeerView) {
        var n = snap
        n.pcId = pc.id; n.pcName = pc.name; n.online = pc.online
        n.title = s.available ? s.title : ""; n.artist = s.artist; n.app = s.app; n.playing = s.playing; n.position = s.position; n.duration = s.duration; n.at = s.at
        n.volume = s.volume; n.muted = s.muted; n.battery = s.batteryPresent ? s.battery : -1; n.charging = s.charging; n.cpu = s.cpu; n.weather = s.weather
        let p = Hub.shared.palette; n.accent = p.accent.hexString; n.accent2 = p.accent2.hexString; n.deep = p.deep.hexString
        if s.coverHash != coverHash {
            coverHash = s.coverHash
            if let c = s.cover, let img = UIImage(data: Data(c)), let jpg = Previews.jpeg(img, side: 240, limit: 60_000) { try? Data(jpg).write(to: Snapshot.coverFile, options: .atomic) }
            else { try? FileManager.default.removeItem(at: Snapshot.coverFile) }
        }
        let big = n.title != snap.title || n.playing != snap.playing || n.online != snap.online || n.pcName != snap.pcName || n.accent != snap.accent
        n.updated = Date(); snap = n; snap.save()
        if big { reload() } else if Date().timeIntervalSince(lastReload) > 300 { reload() }
    }
    func stats(_ s: PcStats) {
        snap.gpu = s.gpu; snap.ram = s.ramPercent; snap.cpu = Int(s.cpu); snap.updated = Date(); snap.save()
        if Date().timeIntervalSince(lastReload) > 600 { reload() }
    }
    func peersChanged() {
        let hub = Hub.shared; guard let p = hub.pc() else { return }
        if p.online != snap.online || p.name != snap.pcName { snap.pcId = p.id; snap.pcName = p.name; snap.online = p.online; snap.save(); reload() }
        if !p.online { LiveActivities.shared.stopPlaying() }
    }
    /// The widgets are redrawn (at most every 15 seconds: iOS limits how often).
    func reload() {
        let wait = 15 - Date().timeIntervalSince(lastReload)
        if wait <= 0 { lastReload = Date(); WidgetCenter.shared.reloadAllTimelines(); if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }; return }
        guard pending == nil else { return }
        pending = Task { try? await Task.sleep(for: .seconds(wait)); pending = nil; reload() }
    }
}

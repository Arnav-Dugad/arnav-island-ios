import AVFoundation
import IslandKit
import MediaPlayer
import Observation
import SwiftUI
import UIKit

/// Music a PC handed over, playing here: from where the PC was, with its cover on the Lock Screen, in Control Center and on
/// AirPods' controls, over AirPlay too; and handed back to the PC at the same place.
@Observable @MainActor
final class Player {
    static let shared = Player()
    var music: Handoff?
    var peer: String?
    var pcName: String?
    var playing = false
    var position = 0.0
    var duration = 0.0
    var artwork: UIImage?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var ended: NSObjectProtocol?
    @ObservationIgnored private var commandsReady = false
    private init() {}

    var active: Bool { music != nil }
    var nowPlayingLine: String? { guard playing, let m = music else { return nil }; return m.artist.isEmpty ? m.title : "\(m.title) — \(m.artist)" }

    func play(_ m: Handoff, file: URL, peer: String, pcName: String, from start: Double) {
        stop(keepSession: true)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        try? s.setActive(true)
        let item = AVPlayerItem(url: file); let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p; music = m; self.peer = peer; self.pcName = pcName
        artwork = m.cover.flatMap { UIImage(data: Data($0)) }
        duration = m.duration
        p.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { _ in }
        p.play(); playing = true; position = start
        if duration <= 0 { Task { if let d = try? await item.asset.load(.duration), d.isNumeric { duration = d.seconds; updateNowPlaying() } } }
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { guard let self else { return }; self.position = t.seconds.isFinite ? t.seconds : 0 }
        }
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playing = false; self?.updateNowPlaying() }
        }
        commands(); updateNowPlaying()
        Hub.shared.show(Banner(kind: .music, title: "Playing \(m.title)", detail: "From \(pcName), where it was"))
    }
    func toggle() { guard let p = player else { return }; if playing { p.pause() } else { p.play() }; playing.toggle(); Haptics.tap(); updateNowPlaying() }
    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)); position = max(0, seconds); updateNowPlaying() }
    func skip(by seconds: Double) { seek(to: position + seconds) }
    func stop(keepSession: Bool = false) {
        player?.pause(); if let observer { player?.removeTimeObserver(observer) }; observer = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }; ended = nil
        player = nil; playing = false; music = nil; artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if !keepSession { KeepAlive.shared.restoreSession() }
    }
    /// Hands the song back to the PC it came from, at the same place.
    func handBack() {
        guard let m = music, let peer else { return }
        var back = m; back.position = position; back.playing = true; back.duration = duration
        Hub.shared.handBack(back, to: peer)
    }
    /// The cover of what plays here, small, for the island's view of this iPhone.
    func coverJPEG() -> [UInt8]? { guard playing, let artwork else { return nil }; return Previews.jpeg(artwork, side: 160, limit: 48_000) }

    private func updateNowPlaying() {
        guard let m = music else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: m.title, MPMediaItemPropertyArtist: m.artist, MPMediaItemPropertyAlbumTitle: m.album,
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0, MPMediaItemPropertyPlaybackDuration: duration]
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }
    private func commands() {
        guard !commandsReady else { return }; commandsReady = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in MainActor.assumeIsolated { let p = Player.shared; if !p.playing { p.toggle() } }; return .success }
        c.pauseCommand.addTarget { _ in MainActor.assumeIsolated { let p = Player.shared; if p.playing { p.toggle() } }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.toggle() }; return .success }
        c.skipForwardCommand.preferredIntervals = [15]; c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.skip(by: 15) }; return .success }
        c.skipBackwardCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.skip(by: -15) }; return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { Player.shared.seek(to: e.positionTime) }; return .success
        }
    }

    /// Continues a PC's song in this iPhone's music app by searching for it: Spotify when the PC played it there, else
    /// Apple Music.
    static func playFromSearch(_ m: Handoff) {
        let q = [m.title, m.artist].filter { !$0.isEmpty }.joined(separator: " ")
        let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var tries: [(URL, String)] = []
        if m.app.localizedCaseInsensitiveContains("spotify"), let u = URL(string: "spotify:search:\(enc)") { tries.append((u, "Spotify")) }
        if m.app.localizedCaseInsensitiveContains("youtube"), let u = URL(string: "https://music.youtube.com/search?q=\(enc)") { tries.append((u, "YouTube Music")) }
        if let u = URL(string: "music://music.apple.com/search?term=\(enc)") { tries.append((u, "Apple Music")) }
        if let u = URL(string: "https://music.apple.com/search?term=\(enc)") { tries.append((u, "Apple Music")) }
        func attempt(_ i: Int) {
            guard i < tries.count else { Hub.shared.show(Banner(kind: .failed, title: "No music app opened", detail: "Play it on the PC, or install Apple Music or Spotify")); return }
            UIApplication.shared.open(tries[i].0, options: [:]) { ok in
                MainActor.assumeIsolated { if ok { Hub.shared.show(Banner(kind: .music, title: "Continuing \(m.title)", detail: "In \(tries[i].1)")) } else { attempt(i + 1) } }
            }
        }
        attempt(0)
    }
}

/// Keeps the app running while it's in the background, when you choose Stay reachable: a silent sound that mixes with
/// whatever else plays (so your PCs can ring this iPhone, send files and hand over pages any time, as on Android).
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()
    private var engine: AVAudioEngine?, node: AVAudioPlayerNode?
    private var interruption: NSObjectProtocol?
    private init() {}
    var on: Bool { engine != nil }
    func sync() { if Hub.shared.prefs.stayReachable { start() } else { stop() } }
    func restoreSession() {
        let s = AVAudioSession.sharedInstance()
        if on { try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers]); try? s.setActive(true); if engine?.isRunning == false { try? engine?.start(); node?.play() } }
        else { try? s.setActive(false, options: .notifyOthersOnDeactivation) }
    }
    func start() {
        guard engine == nil, !Player.shared.playing else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers]); try? s.setActive(true)
        let e = AVAudioEngine(), n = AVAudioPlayerNode(); e.attach(n)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1), let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050) else { return }
        silence.frameLength = 22_050
        e.connect(n, to: e.mainMixerNode, format: format)
        n.scheduleBuffer(silence, at: nil, options: .loops)
        do { try e.start(); n.play(); engine = e; node = n } catch { return }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .ended
            if ended { MainActor.assumeIsolated { KeepAlive.shared.restoreSession() } }
        }
    }
    func stop() {
        node?.stop(); engine?.stop(); engine = nil; node = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption) }; interruption = nil
        if !Player.shared.playing && Ringer.shared.ringing == false { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}

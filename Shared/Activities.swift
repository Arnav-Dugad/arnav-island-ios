#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// What plays on your PC, in the Dynamic Island and on the Lock Screen (a Live Activity): the song, where it is (a timer the
/// system runs on its own, so it keeps moving while the app sleeps), and play, pause and skip that reach the PC.
struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String; var artist: String; var playing: Bool
        /// When the song started, so the system moves its progress on by itself; its length.
        var started: Date; var duration: Double; var pausedAt: Double
        var accent: String; var hasCover: Bool
    }
    var pcName: String
}

/// A file going to (or coming from) your PC.
struct TransferAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { var done: Int64; var total: Int64; var rate: Double; var finished: Bool; var failed: Bool }
    var title: String; var pcName: String; var outgoing: Bool
}

/// Your PC's focus clock, counting down in the Dynamic Island.
struct FocusAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { var mode: Int; var running: Bool; var ends: Date; var shown: Double; var duration: Double }
    var pcName: String
}
#endif

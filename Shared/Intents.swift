import AppIntents
import Foundation

// Your PC's actions for Siri, Shortcuts, Spotlight, the Action button, Control Center, widgets and Live Activities. They
// are Live Activity intents, so iOS runs them in the app itself (woken in the background if need be), which holds the
// keys to your PC; the widgets only carry the buttons.

struct PlayPausePCIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or Pause on My PC"
    static var description = IntentDescription("Plays or pauses what plays on your PC.")
    init() {}
    func perform() async throws -> some IntentResult {
        #if APP
        await IntentActions.media(1)
        #endif
        return .result()
    }
}
struct NextTrackPCIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next Song on My PC"
    init() {}
    func perform() async throws -> some IntentResult {
        #if APP
        await IntentActions.media(3)
        #endif
        return .result()
    }
}
struct PreviousTrackPCIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous Song on My PC"
    init() {}
    func perform() async throws -> some IntentResult {
        #if APP
        await IntentActions.media(2)
        #endif
        return .result()
    }
}
struct VolumeUpPCIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Turn Up My PC"
    init() {}
    func perform() async throws -> some IntentResult {
        #if APP
        await IntentActions.volume(by: 10)
        #endif
        return .result()
    }
}
struct VolumeDownPCIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Turn Down My PC"
    init() {}
    func perform() async throws -> some IntentResult {
        #if APP
        await IntentActions.volume(by: -10)
        #endif
        return .result()
    }
}
struct LockPCIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Lock My PC"
    static var description = IntentDescription("Locks your PC right away.")
    init() {}
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if APP
        return .result(dialog: IntentDialog(stringLiteral: await IntentActions.lock()))
        #else
        return .result(dialog: "")
        #endif
    }
}
struct FindPCIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Find My PC"
    static var description = IntentDescription("Your PC's island chimes and lights up.")
    init() {}
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if APP
        return .result(dialog: IntentDialog(stringLiteral: await IntentActions.ring()))
        #else
        return .result(dialog: "")
        #endif
    }
}
struct PCStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "How's My PC"
    static var description = IntentDescription("What plays on your PC, its battery and how busy it is.")
    init() {}
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if APP
        return .result(dialog: IntentDialog(stringLiteral: await IntentActions.summary()))
        #else
        return .result(dialog: "")
        #endif
    }
}
/// Opens the app on one of its places (the PC's screen, the trackpad, the remote).
struct OpenIslandIntent: AppIntent {
    static var title: LocalizedStringResource = "Open in Arnav Island"
    static var openAppWhenRun: Bool = true
    @Parameter(title: "Place", default: .remote) var place: IslandPlace
    init() {}
    init(_ place: IslandPlace) { self.place = place }
    func perform() async throws -> some IntentResult {
        AppGroup.defaults.set(place.rawValue, forKey: "pendingOpen")
        #if APP
        await IntentActions.open(place.rawValue)
        #endif
        return .result()
    }
}
enum IslandPlace: String, AppEnum {
    case remote, island, screen, trackpad, send, camera
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Place"
    static var caseDisplayRepresentations: [IslandPlace: DisplayRepresentation] = [
        .remote: "The remote", .island: "The island", .screen: "My PC's screen", .trackpad: "The trackpad", .send: "Send", .camera: "Camera on my PC",
    ]
}

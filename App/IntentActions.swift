import Foundation

/// What Siri, Shortcuts, widgets and Live Activities ask the app to do.
enum IntentActions {
    static func media(_ action: Int) async {}
    static func volume(by step: Int) async {}
    static func lock() async -> String { "" }
    static func ring() async -> String { "" }
    static func summary() async -> String { "" }
    static func open(_ place: String) async {}
}

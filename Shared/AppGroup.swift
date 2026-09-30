import Foundation

/// What the app, its widgets and its share sheet share: a folder, settings, and the keychain group the identity lives in.
enum AppGroup {
    static let fallback = "group.io.github.arnavdugad.arnavisland"
    /// AltStore and SideStore register a group of their own for a sideloaded app and list it in the app's Info.plist
    /// ("ALTAppGroups"); an extension reads the app's (two folders up).
    static let id: String = {
        func groups(_ b: Bundle) -> [String]? { b.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] }
        if let g = groups(.main)?.first { return g }
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app", let b = Bundle(url: app), let g = groups(b)?.first { return g }
        return fallback
    }()
    static var container: URL {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

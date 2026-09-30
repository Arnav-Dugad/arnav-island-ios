import AppIntents

/// What Siri and Spotlight offer without any setting up: "Lock my PC with Arnav Island", "Find my PC"…
struct IslandShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LockPCIntent(), phrases: ["Lock my PC with \(.applicationName)", "Lock my computer with \(.applicationName)"], shortTitle: "Lock My PC", systemImageName: "lock.fill")
        AppShortcut(intent: FindPCIntent(), phrases: ["Find my PC with \(.applicationName)", "Ring my PC with \(.applicationName)"], shortTitle: "Find My PC", systemImageName: "bell.and.waves.left.and.right")
        AppShortcut(intent: PlayPausePCIntent(), phrases: ["Play or pause my PC with \(.applicationName)", "Pause my PC with \(.applicationName)"], shortTitle: "Play or Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: PCStatusIntent(), phrases: ["How's my PC in \(.applicationName)", "What's playing on my PC in \(.applicationName)"], shortTitle: "How's My PC", systemImageName: "laptopcomputer")
        AppShortcut(intent: OpenIslandIntent(.trackpad), phrases: ["Open the trackpad in \(.applicationName)"], shortTitle: "Trackpad", systemImageName: "rectangle.and.hand.point.up.left")
        AppShortcut(intent: OpenIslandIntent(.screen), phrases: ["Show my PC's screen in \(.applicationName)"], shortTitle: "My PC's Screen", systemImageName: "display")
    }
    static var shortcutTileColor: ShortcutTileColor { .teal }
}

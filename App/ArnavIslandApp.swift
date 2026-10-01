import BackgroundTasks
import IslandKit
import LocalAuthentication
import SwiftUI
import UserNotifications

@main
struct ArnavIslandApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var hub = Hub.shared
    @State private var tilt = Tilt.shared
    var body: some Scene {
        WindowGroup { AppRoot().environment(hub).environment(tilt) }
    }
}

/// The look (the song's colours, light or dark, glass or solid), the lock, and what the app does as it comes and goes.
struct AppRoot: View {
    private var hub: Hub { Hub.shared }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    @State private var locked = Hub.shared.prefs.faceID
    @State private var backgroundAt: Date?
    var body: some View {
        let dark = hub.prefs.theme == 0 ? scheme == .dark : hub.prefs.theme == 1
        let tokens = Tokens(dark: dark, palette: hub.palette)
        ZStack {
            RootView()
            if locked { LockView { locked = false }.transition(.opacity.combined(with: .scale(scale: 1.04))).zIndex(10) }
            // What the app switcher shows while the lock is on: frosted, nothing readable.
            if phase != .active && hub.prefs.faceID && !locked { Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().zIndex(11) }
        }
        .environment(\.tokens, tokens)
        .environment(\.glassOn, !hub.prefs.solidGlass)
        .preferredColorScheme(hub.prefs.theme == 0 ? nil : hub.prefs.theme == 1 ? .dark : .light)
        .tint(tokens.accent)
        .onOpenURL { open($0) }
        .onChange(of: phase) { _, p in phaseChanged(p) }
        .task {
            if Demo.on { Demo.load(hub); if let r = Demo.argument("open") { try? await Task.sleep(for: .milliseconds(600)); hub.request = r }; return }
            Notify.setUp(); Sources.clearOld()
            NetWatch.shared.onChange = { Hub.shared.networkChanged() }
            await hub.start()
            // A test run (the simulator in CI): pairs with the island engine from its link.
            if let link = Demo.argument("pairlink"), hub.pairedPCs.isEmpty { _ = hub.open(pairLink: link) }
            KeepAlive.shared.sync(); RecentPhotos.shared.sync(); LiveActivities.shared.sync()
            NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Hub.shared.sendBattery() } }
            NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { Hub.shared.sendBattery() } }
            UIDevice.current.isBatteryMonitoringEnabled = true
            if let place = AppGroup.defaults.string(forKey: "pendingOpen") { AppGroup.defaults.removeObject(forKey: "pendingOpen"); hub.request = place }
            // Details every few minutes while the app runs (the island shows this iPhone's readings).
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(120)); hub.sendDetails() }
        }
    }

    private func phaseChanged(_ p: ScenePhase) {
        switch p {
        case .active:
            hub.visible = true; Tilt.shared.start()
            if hub.prefs.faceID, let at = backgroundAt, Date().timeIntervalSince(at) > 30 { locked = true }
            backgroundAt = nil
            Task { await hub.start(); hub.networkChanged(); hub.sendBattery(force: false); hub.sendDetails(); hub.clipboardOut() }
            if let place = AppGroup.defaults.string(forKey: "pendingOpen") { AppGroup.defaults.removeObject(forKey: "pendingOpen"); hub.request = place }
            // Files shared to your PC from other apps while the app was away.
            ShareInbox.collect()
        case .background:
            hub.visible = false; Tilt.shared.stop(); backgroundAt = Date()
            AppDelegate.scheduleRefresh()
        default: hub.visible = false
        }
    }

    /// arnavisland://pair/CODE?k=…, the island's QR code (the Camera app opens it here), and arnavisland://open/screen…
    private func open(_ url: URL) {
        let s = url.absoluteString
        if s.contains("/pair/") || url.host == "pair" {
            if hub.open(pairLink: s) { hub.request = "pairing" }
            else { hub.show(Banner(kind: .failed, title: "That link can’t pair", detail: "Scan the QR code on your PC’s island again")) }
            return
        }
        if url.host == "open" { hub.request = url.lastPathComponent; return }
    }
}

/// The app's lock: Face ID (or your passcode) before anything shows.
struct LockView: View {
    let onUnlock: () -> Void
    @Environment(\.tokens) private var t
    @State private var failed = false
    var body: some View {
        ZStack {
            Ambient(playing: false)
            VStack(spacing: 18) {
                Image(systemName: "faceid").font(.system(size: 56, weight: .light)).foregroundStyle(t.accent)
                    .frame(width: 120, height: 120).glass(Circle(), .control, tint: t.accent)
                    .symbolEffect(.bounce, value: failed)
                Text("Arnav Island is locked").font(TypeScale.title).foregroundStyle(t.text)
                Text(failed ? "That didn't match. Try again." : "Unlock to reach your PCs").font(TypeScale.body).foregroundStyle(t.muted)
                GlassButton(prominent: true, action: unlock) { Image(systemName: "lock.open.fill"); Text("Unlock").font(TypeScale.bodyStrong) }
            }
        }
        .onAppear(perform: unlock)
    }
    private func unlock() {
        let c = LAContext(); c.localizedCancelTitle = "Not now"
        var error: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { onUnlock(); return }
        c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Arnav Island") { ok, _ in
            DispatchQueue.main.async { if ok { Haptics.success(); withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { onUnlock() } } else { failed.toggle(); Haptics.error() } }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTask = "io.github.arnavdugad.arnavisland.refresh"
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Self.scheduleRefresh()
            let work = Task { @MainActor in
                // Wakes now and then: brings the widgets up to date with your PC.
                let hub = Hub.shared
                _ = await hub.start()
                for _ in 0..<60 where hub.pc()?.online != true { try? await Task.sleep(for: .milliseconds(200)) }
                if hub.pc()?.online == true { await hub.refreshStatus(); await hub.refreshIsland(withStats: true) }
                hub.sendBattery(force: true); Snapshotter.shared.reload()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        return true
    }
    static func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refreshTask); r.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // On screen the island says it; a notification would repeat it.
        []
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { Notify.respond(response) }
    }
}

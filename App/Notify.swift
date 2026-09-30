import Foundation
import UIKit
import UserNotifications

/// Notifications for what arrives while the app isn't on screen (with Stay reachable on, or in the moments before iOS
/// pauses it): files offered, music, a pairing's digits, a ring, a page, a photo asked for. Their buttons answer directly.
@MainActor
enum Notify {
    static let pair = "pair", offer = "offer-", musicId = "music", photoId = "photo", ringId = "ring", pageId = "page", receivedId = "received-"
    private static var center: UNUserNotificationCenter { .current() }

    static func setUp() {
        let accept = UNNotificationAction(identifier: "accept", title: "Accept", options: [])
        let decline = UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive])
        let play = UNNotificationAction(identifier: "play", title: "Play here", options: [.foreground])
        let notNow = UNNotificationAction(identifier: "notnow", title: "Not now", options: [])
        let stop = UNNotificationAction(identifier: "stop", title: "Stop ringing", options: [])
        let read = UNNotificationAction(identifier: "read", title: "Read here", options: [.foreground])
        let take = UNNotificationAction(identifier: "camera", title: "Take a photo", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "offer", actions: [accept, decline], intentIdentifiers: []),
            UNNotificationCategory(identifier: "music", actions: [play, notNow], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ring", actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: "page", actions: [read], intentIdentifiers: []),
            UNNotificationCategory(identifier: "photo", actions: [take], intentIdentifiers: []),
        ])
    }
    static func ask() { center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }

    private static func post(_ id: String, _ title: String, _ body: String, category: String? = nil, info: [String: Any] = [:], sound: UNNotificationSound? = .default, attachment: URL? = nil) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = sound; c.userInfo = info
        if let category { c.categoryIdentifier = category }
        c.interruptionLevel = .active; c.threadIdentifier = category ?? id
        if let attachment, let a = try? UNNotificationAttachment(identifier: "file", url: attachment, options: [UNNotificationAttachmentOptionsThumbnailHiddenKey: false]) { c.attachments = [a] }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
    static func cancel(_ id: String) { center.removeDeliveredNotifications(withIdentifiers: [id]); center.removePendingNotificationRequests(withIdentifiers: [id]) }

    static func pairing(name: String, code: Int) { post(pair, "Pair with \(name)?", "Check that \(String(format: "%06d", code)) shows on both, then open the app to confirm", info: ["open": "pair"]) }
    static func offer(transfer: Int, name: String, title: String, size: Int64) { post(offer + "\(transfer)", "\(name) wants to send \(title)", sizeText(size), category: "offer", info: ["transfer": transfer]) }
    static func music(transfer: Int, name: String, title: String, artist: String) { post(musicId, "Continue \(title) here?", artist.isEmpty ? "From \(name)" : "\(artist)  ·  from \(name)", category: "music", info: ["transfer": transfer]) }
    static func received(name: String, title: String, size: Int64, first: URL?) {
        // A copy of a picture for the notification (iOS moves attachments away).
        var attachment: URL?
        if let first, ["jpg", "jpeg", "png", "heic", "gif"].contains(first.pathExtension.lowercased()) {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + first.pathExtension)
            if (try? FileManager.default.copyItem(at: first, to: copy)) != nil { attachment = copy }
        }
        post(receivedId + UUID().uuidString, "Received \(title)", "From \(name)  ·  \(sizeText(size))  ·  in Files", info: ["open": "send"], attachment: attachment)
    }
    static func ring(name: String) { post(ringId, "\(name) is looking for this iPhone", "Tap to stop ringing", category: "ring", info: ["open": "ring"]) }
    static func photo(name: String) { post(photoId, "\(name) asks for a photo", "Take one for its Shelf", category: "photo", info: ["open": "camera"]) }
    static func page(from: String, url: URL, title: String, scroll: Double) {
        post(pageId, title.isEmpty ? (url.host ?? "A page") : title, "From \(from)  ·  \(scroll > 0.02 ? "where you were" : "tap to read")", category: "page", info: ["open": "page"])
    }

    /// A notification's button, or the notification itself, tapped.
    static func respond(_ r: UNNotificationResponse) {
        let hub = Hub.shared; let info = r.notification.request.content.userInfo
        switch r.actionIdentifier {
        case "accept": if let t = info["transfer"] as? Int { hub.answer(transfer: t, accept: true) }
        case "decline": if let t = info["transfer"] as? Int { hub.answer(transfer: t, accept: false) }
        case "play": if let m = hub.music { hub.answerMusic(m, play: true) }
        case "notnow": if let m = hub.music { hub.answerMusic(m, play: false) }
        case "stop": Ringer.shared.stop()
        case "read": hub.request = "page"
        case "camera": hub.request = "camera"
        default:
            if r.notification.request.content.categoryIdentifier == "ring" { Ringer.shared.stop() }
            if let open = info["open"] as? String { hub.request = open }
        }
    }
}

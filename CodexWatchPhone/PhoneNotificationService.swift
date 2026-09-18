import Foundation
import UserNotifications

final class PhoneNotificationService: NSObject, UNUserNotificationCenterDelegate {
    var onAction: ((String, String?) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    private let seenEventIDsKey = "codexWatchSeenEventIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func configure() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "codex-approval-needed",
                actions: [
                    UNNotificationAction(identifier: "approve", title: L10n.text("Approve"), options: [.foreground]),
                    UNNotificationAction(identifier: "approve-session", title: L10n.text("Approve for session"), options: [.foreground]),
                    UNNotificationAction(identifier: "decline", title: L10n.text("Deny"), options: [.destructive])
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: "codex-task-event",
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func handle(_ message: BridgeMessage) {
        guard let event = message.event, !event.isEmpty else { return }
        let eventID = message.eventID ?? "codex-event-\(UUID().uuidString)"
        guard rememberEventID(eventID) else { return }

        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: event, fallback: message.title)
        content.body = notificationBody(for: message)
        content.sound = .default
        content.badge = 1
        var userInfo: [String: Any] = [
            "event": event,
            "eventID": eventID
        ]
        if let requestID = message.requestID {
            userInfo["requestID"] = requestID
        }
        content.userInfo = userInfo
        if event == "approval-needed" {
            content.categoryIdentifier = "codex-approval-needed"
        } else {
            content.categoryIdentifier = "codex-task-event"
        }

        center.add(UNNotificationRequest(identifier: eventID, content: content, trigger: nil))
    }

    func sendTestNotification() {
        let message = BridgeMessage(
            type: "state",
            title: L10n.text("Codex Watch notification test"),
            body: L10n.text("If you can see this message, task notifications are enabled."),
            event: "task-complete",
            eventID: "test-\(UUID().uuidString)"
        )
        handle(message)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        guard action != UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let requestID = response.notification.request.content.userInfo["requestID"] as? String
        onAction?(action, requestID)
        completionHandler()
    }

    private func rememberEventID(_ eventID: String) -> Bool {
        var seen = defaults.stringArray(forKey: seenEventIDsKey) ?? []
        if seen.contains(eventID) {
            return false
        }
        seen.append(eventID)
        if seen.count > 100 {
            seen.removeFirst(seen.count - 100)
        }
        defaults.set(seen, forKey: seenEventIDsKey)
        return true
    }

    private func notificationTitle(for event: String, fallback: String?) -> String {
        switch event {
        case "task-complete":
            return L10n.text("Codex task completed")
        case "task-failed":
            return L10n.text("Codex task failed")
        case "approval-needed":
            return L10n.text("Codex is waiting for your approval")
        case "input-needed":
            return L10n.text("Codex is waiting for your input")
        default:
            return fallback.map(L10n.bridgeText) ?? "Codex Watch"
        }
    }

    private func notificationBody(for message: BridgeMessage) -> String {
        let source = (message.body ?? message.text).map(L10n.bridgeText) ?? L10n.text("Open Codex Watch for details.")
        let compact = source.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return compact.count > 220 ? String(compact.prefix(217)) + "..." : compact
    }
}

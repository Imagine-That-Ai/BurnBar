import Foundation
import UserNotifications

@MainActor
final class ChatPaneAlertCenter {
    struct Event: Sendable {
        let paneID: UUID
        let tabID: UUID
        let threadID: String
        let backendLabel: String
        let title: String
        let preview: String
        let isFailure: Bool
    }

    static let shared = ChatPaneAlertCenter()
    static let completionNotificationsKey = "paneWorkspace.completionNotificationsEnabled"
    static var paneCompletionTapHandler: ((UUID, UUID) -> Void)?

    private let center: UNUserNotificationCenter
    private var authorizationRequested = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    var completionNotificationsEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.completionNotificationsKey) != nil else { return true }
        return defaults.bool(forKey: Self.completionNotificationsKey)
    }

    func postCompletion(_ event: Event) {
        guard completionNotificationsEnabled else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = event.isFailure ? "\(event.backendLabel) needs attention" : "\(event.backendLabel) finished"
        let displayTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = event.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayTitle.isEmpty, !preview.isEmpty {
            content.body = "\(displayTitle): \(preview)"
        } else if !displayTitle.isEmpty {
            content.body = displayTitle
        } else if !preview.isEmpty {
            content.body = preview
        } else {
            content.body = "A background chat pane has an update."
        }
        content.sound = event.isFailure ? .defaultCritical : .default
        content.userInfo = [
            "type": "pane_completion",
            "pane_id": event.paneID.uuidString,
            "tab_id": event.tabID.uuidString,
            "thread_id": event.threadID,
            "backend": event.backendLabel
        ]

        let request = UNNotificationRequest(
            identifier: "burnbar.paneCompletion.\(event.paneID.uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        center.add(request) { _ in }
    }

    func withdraw(paneID: UUID) {
        let identifier = "burnbar.paneCompletion.\(paneID.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
}

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

    static let completionNotificationsKey = "paneWorkspace.completionNotificationsEnabled"
    static var paneCompletionTapHandler: ((UUID, UUID) -> Void)?

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    var completionNotificationsEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.completionNotificationsKey) != nil else { return true }
        return defaults.bool(forKey: Self.completionNotificationsKey)
    }

    func postCompletion(_ event: Event) async {
        guard completionNotificationsEnabled else { return }
        guard await notificationAuthorizationAllowsScheduling() else { return }

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
        do {
            try await center.add(request)
        } catch {
            return
        }
    }

    func withdraw(paneID: UUID) {
        let identifier = "burnbar.paneCompletion.\(paneID.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func notificationAuthorizationAllowsScheduling() async -> Bool {
        switch await notificationAuthorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestAuthorization()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        let rawValue = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus.rawValue)
            }
        }
        return UNAuthorizationStatus(rawValue: rawValue) ?? .denied
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}

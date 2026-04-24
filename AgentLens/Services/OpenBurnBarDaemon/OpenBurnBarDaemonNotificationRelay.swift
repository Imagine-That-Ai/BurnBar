import Foundation
import UserNotifications
import OpenBurnBarCore

/// Subscribes to `NSDistributedNotificationCenter` posts from the per-user daemon and mirrors them into
/// standard UserNotifications from the real app process (menu bar `.app`), avoiding helper-tool issues
/// and any `osascript` subprocess.
@MainActor
final class OpenBurnBarDaemonLocalNotificationRelay: NSObject {
    static let shared = OpenBurnBarDaemonLocalNotificationRelay()

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributed(_:)),
            name: OpenBurnBarDistributedNotifications.daemonLocalNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleDistributed(_ notification: Notification) {
        guard
            let title = notification.userInfo?[OpenBurnBarDistributedNotifications.titleKey] as? String,
            let body = notification.userInfo?[OpenBurnBarDistributedNotifications.bodyKey] as? String
        else {
            return
        }
        Task { [title, body] in
            await Self.deliverUserNotification(title: title, body: body)
        }
    }

    private static func deliverUserNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

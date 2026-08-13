import Foundation
import UserNotifications
import OpenBurnBarCore

enum QuotaResetCelebrationNotifier {
    static func post(_ event: QuotaResetEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.captionEyebrow
        let account = event.accountLabel.map { " · \($0)" } ?? ""
        content.body = event.captionHeadline + account
        content.sound = nil
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
            identifier: "quota-reset-\(event.resetBoundary)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

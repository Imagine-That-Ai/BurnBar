import Foundation
import UserNotifications

@MainActor
final class DailyDigestManager {
    static let shared = DailyDigestManager()

    private init() {}

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func scheduleDigest(from dataStore: DataStore, at hour: Int = 18) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [BurnBarIdentity.dailyDigestNotificationIdentifier] + BurnBarIdentity.legacyDailyDigestNotificationIdentifiers
        )
        let narrative = InsightEngine.generateNarrative(from: dataStore)
        let content = UNMutableNotificationContent()
        content.title = "\(BurnBarIdentity.productName) Daily Digest"
        content.body = [narrative.headline, narrative.detail].compactMap { $0 }.joined(separator: " ")
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: BurnBarIdentity.dailyDigestNotificationIdentifier,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    func cancelDigest() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [BurnBarIdentity.dailyDigestNotificationIdentifier] + BurnBarIdentity.legacyDailyDigestNotificationIdentifiers
        )
    }
}

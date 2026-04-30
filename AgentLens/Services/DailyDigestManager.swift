import Foundation
import UserNotifications

@MainActor
protocol OpenBurnBarUserNotificationCentering {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

@MainActor
private final class OpenBurnBarUserNotificationCenterAdapter: OpenBurnBarUserNotificationCentering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) {
        center.add(request, withCompletionHandler: nil)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

@MainActor
final class DailyDigestManager {
    static let shared = DailyDigestManager()

    private let notificationCenter: any OpenBurnBarUserNotificationCentering

    init(notificationCenter: any OpenBurnBarUserNotificationCentering = OpenBurnBarUserNotificationCenterAdapter()) {
        self.notificationCenter = notificationCenter
    }

    func requestAuthorization() async {
        _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound])
    }

    func scheduleDigest(from dataStore: DataStoreCoordinator, at hour: Int = 18) {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [OpenBurnBarIdentity.dailyDigestNotificationIdentifier] + OpenBurnBarIdentity.legacyDailyDigestNotificationIdentifiers
        )
        let narrative = InsightEngine.generateNarrative(from: dataStore)
        let content = UNMutableNotificationContent()
        content.title = "\(OpenBurnBarIdentity.productName) Daily Digest"
        content.body = [narrative.headline, narrative.detail].compactMap { $0 }.joined(separator: " ")
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: OpenBurnBarIdentity.dailyDigestNotificationIdentifier,
            content: content,
            trigger: trigger
        )
        notificationCenter.add(request)
    }

    func cancelDigest() {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [OpenBurnBarIdentity.dailyDigestNotificationIdentifier] + OpenBurnBarIdentity.legacyDailyDigestNotificationIdentifiers
        )
    }
}

import Foundation
import OpenBurnBarCore
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
        _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound]) // try?-ok(notification auth best-effort)
    }

    func scheduleDigest(from dataStore: DataStore, at hour: Int = 18) {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [OpenBurnBarCore.OpenBurnBarIdentity.dailyDigestNotificationIdentifier] + OpenBurnBarCore.OpenBurnBarIdentity.legacyDailyDigestNotificationIdentifiers
        )
        let narrative = InsightEngine.generateNarrative(from: dataStore)
        let content = UNMutableNotificationContent()
        content.title = "\(OpenBurnBarCore.OpenBurnBarIdentity.productName) Daily Digest"
        content.body = [narrative.headline, narrative.detail].compactMap { $0 }.joined(separator: " ")
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: OpenBurnBarCore.OpenBurnBarIdentity.dailyDigestNotificationIdentifier,
            content: content,
            trigger: trigger
        )
        notificationCenter.add(request)
    }

    /// Bind the digest's lifecycle to live settings.
    ///
    /// The call site registers this once at launch, WHETHER OR NOT the digest is
    /// currently on, and expects it to arm, re-arm and clear itself as the
    /// settings change — without waiting for the next launch.
    ///
    /// The inputs are stored rather than captured by the observation closure:
    /// `withObservationTracking`'s `onChange` is `@Sendable`, the settings
    /// getters are not, and this type is already `@MainActor` — so keeping them
    /// as properties lets the closure capture nothing but `self`.
    private var digestDataStore: DataStore?
    private var digestIsEnabled: (() -> Bool)?
    private var digestHour: (() -> Int)?

    func activate(
        from dataStore: DataStore,
        isEnabled: @escaping () -> Bool,
        hour: @escaping () -> Int
    ) {
        digestDataStore = dataStore
        digestIsEnabled = isEnabled
        digestHour = hour
        applyDigestState()
    }

    private func applyDigestState() {
        guard let dataStore = digestDataStore,
              let isEnabled = digestIsEnabled,
              let hour = digestHour
        else { return }

        let enabled = withObservationTracking {
            let enabled = isEnabled()
            // Read the hour INSIDE the tracked block too, so a changed hour
            // re-arms at the new time rather than waiting for a toggle.
            _ = hour()
            return enabled
        } onChange: { [weak self] in
            // `onChange` fires exactly once, so re-register on every change or
            // the digest would follow the settings a single time and go silent.
            Task { @MainActor in
                self?.applyDigestState()
            }
        }

        if enabled {
            scheduleDigest(from: dataStore, at: hour())
        } else {
            cancelDigest()
        }
    }

    func cancelDigest() {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [OpenBurnBarCore.OpenBurnBarIdentity.dailyDigestNotificationIdentifier] + OpenBurnBarCore.OpenBurnBarIdentity.legacyDailyDigestNotificationIdentifiers
        )
    }
}

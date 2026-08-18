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

    /// Cadence that keeps the pending digest armed with a body computed for
    /// the day it will describe.
    static let refreshCadenceID = "agentlens-daily-digest-refresh"

    /// How often the armed digest is rebuilt. The body only has to be correct
    /// for its *delivery* date, so this exists to pick up sessions imported
    /// after the previous arming — and to notice a changed digest setting —
    /// not to race the clock.
    private static let refreshInterval: TimeInterval = 15 * 60

    /// Leave the pending request alone this close to its fire date, in either
    /// direction. Re-arming across the delivery moment would remove a request
    /// the notification daemon is about to hand over and re-arm it for
    /// tomorrow, silently swallowing that day's digest.
    private static let reArmGuard: TimeInterval = 5 * 60

    /// How many days of one-shot digests stay armed at once.
    ///
    /// One armed day would mean a quit app delivers a single digest and then
    /// goes silent. The horizon keeps the cadence the user opted into running
    /// without the app: while it runs the cadence rewrites these every 15
    /// minutes, so only a quit app ever reaches day 2 and beyond.
    private static let horizonDays = 7

    private let notificationCenter: any OpenBurnBarUserNotificationCentering
    private let calendar: Calendar
    private let now: @MainActor () -> Date

    /// Fire date of the request this process currently has armed, used to
    /// honour `reArmGuard`. `nil` whenever no digest is armed.
    private(set) var armedFireDate: Date?
    private var hasRequestedAuthorization = false
    /// Whether the disabled path has already cleared any request left armed by
    /// a previous process, so later ticks can skip the call entirely.
    private var hasSweptWhileDisabled = false

    init(
        notificationCenter: any OpenBurnBarUserNotificationCentering = OpenBurnBarUserNotificationCenterAdapter(),
        calendar: Calendar = .current,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.notificationCenter = notificationCenter
        self.calendar = calendar
        self.now = now
    }

    func requestAuthorization() async {
        hasRequestedAuthorization = true
        _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound]) // try?-ok(notification auth best-effort)
    }

    // MARK: - Cadence

    /// Registers the recurring job that keeps the digest honest.
    ///
    /// `scheduleDigest` bakes its body into a `UNNotificationContent` at call
    /// time, so any single arming can only describe the data that existed when
    /// it ran. Re-arming on a cadence — rather than registering one repeating
    /// trigger at launch — is what makes the delivered text reflect the data,
    /// and the digest settings, as of delivery instead of as of app launch.
    ///
    /// Registered unconditionally: the cadence reads `isEnabled` on every tick,
    /// so switching the digest off clears the pending request instead of
    /// leaving a stale one armed until the next launch.
    func activate(
        from dataStore: DataStore,
        isEnabled: @escaping @MainActor () -> Bool,
        hour: @escaping @MainActor () -> Int,
        coordinator: BackgroundCadenceCoordinator = .shared
    ) {
        coordinator.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.refreshCadenceID,
                activeInterval: Self.refreshInterval,
                backgroundInterval: Self.refreshInterval,
                // Paused while the display sleeps: the OS still delivers what
                // is already armed, and the body is pinned to its delivery
                // date, so sleeping through a tick cannot stale the text.
                sleepInterval: nil,
                isEnabled: { true },
                fireImmediately: true,
                work: { [weak self] in
                    await self?.refreshArmedDigest(
                        from: dataStore,
                        isEnabled: isEnabled(),
                        hour: hour()
                    )
                }
            )
        )
    }

    private func refreshArmedDigest(from dataStore: DataStore, isEnabled: Bool, hour: Int) async {
        guard isEnabled else {
            // A request armed by a previous process outlives this one's state,
            // so the first tick has to sweep even with nothing armed here.
            // After that there is only something to clear if we armed it.
            if armedFireDate != nil || !hasSweptWhileDisabled {
                hasSweptWhileDisabled = true
                cancelDigest()
            }
            return
        }
        if !hasRequestedAuthorization {
            // The digest can be switched on long after launch, where the
            // startup authorization request never ran.
            await requestAuthorization()
        }
        await scheduleDigestUsingPersistedUsage(from: dataStore, at: hour)
    }

    // MARK: - Arming

    /// Arms one-shot notifications for the next `horizonDays` occurrences of
    /// `hour:00`, the first carrying a body computed for the day it describes.
    ///
    /// One-shot rather than `repeats: true` because a repeating trigger reuses
    /// the content it was registered with — a Mac left running would replay the
    /// sentence computed at launch every day. `activate` re-arms the whole
    /// horizon after each delivery.
    func scheduleDigest(from dataStore: DataStore, at hour: Int = 18) {
        guard let firstFireDate = firstFireDateForArming(at: hour) else { return }
        armDigest(usages: dataStore.usages, firstFireDate: firstFireDate)
    }

    /// Production arming path. Reads only the two calendar days needed by the
    /// first digest, directly from the indexed SQLite ledger, so daily digest
    /// remains correct while dashboard presentation is intentionally cold.
    func scheduleDigestUsingPersistedUsage(from dataStore: DataStore, at hour: Int = 18) async {
        guard let firstFireDate = firstFireDateForArming(at: hour) else { return }
        do {
            let usages = try await persistedDigestUsages(
                from: dataStore,
                deliveredAt: firstFireDate
            )
            armDigest(usages: usages, firstFireDate: firstFireDate)
        } catch {
            // Keep any previously armed notification instead of replacing it
            // with a confidently wrong empty digest.
            AppLogger.dataStore.silentFailure("daily_digest_usage_fetch_failed", error: error)
        }
    }

    private func firstFireDateForArming(at hour: Int) -> Date? {
        let reference = now()
        if let armedFireDate,
           abs(armedFireDate.timeIntervalSince(reference)) < Self.reArmGuard {
            return nil
        }
        return nextFireDate(after: reference, at: hour)
    }

    private func persistedDigestUsages(
        from dataStore: DataStore,
        deliveredAt fireDate: Date
    ) async throws -> [TokenUsage] {
        let window = InsightEngine.digestWindow(forDeliveryAt: fireDate, calendar: calendar)
        let priorStart = calendar.date(byAdding: .day, value: -1, to: window.lowerBound)
            ?? window.lowerBound.addingTimeInterval(-86_400)
        let usages = try await dataStore.fetchUsage(
            startingIn: priorStart..<window.upperBound,
            limit: Int.max
        )
        if !usages.isEmpty {
            return usages
        }

        // `generateDigestNarrative` distinguishes an empty ledger from a quiet
        // two-day window. One newest row preserves that wording without
        // materializing all history.
        return try await dataStore.fetchRecentUsage(limit: 1)
    }

    private func armDigest(usages: [TokenUsage], firstFireDate: Date) {
        removePendingDigests()
        for offset in 0..<Self.horizonDays {
            guard let fireDate = calendar.date(byAdding: .day, value: offset, to: firstFireDate) else { continue }
            notificationCenter.add(
                UNNotificationRequest(
                    identifier: Self.digestIdentifier(dayOffset: offset),
                    content: digestContent(from: usages, deliveredAt: fireDate, dayOffset: offset),
                    trigger: UNCalendarNotificationTrigger(
                        dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                        repeats: false
                    )
                )
            )
        }
        armedFireDate = firstFireDate
    }

    private func digestContent(
        from usages: [TokenUsage],
        deliveredAt fireDate: Date,
        dayOffset: Int
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(OpenBurnBarCore.OpenBurnBarIdentity.productName) Daily Digest"
        content.sound = .default
        if dayOffset == 0 {
            let narrative = InsightEngine.generateDigestNarrative(
                from: usages,
                deliveredAt: fireDate,
                calendar: calendar
            )
            content.body = [narrative.headline, narrative.detail].compactMap { $0 }.joined(separator: " ")
        } else {
            // Every day past the first covers a window that has not happened
            // yet, so there is no total to state. Name the day and invite the
            // user back rather than shipping a number we cannot know.
            let dayName = InsightEngine.digestDayName(forDeliveryAt: fireDate, calendar: calendar)
            content.body = "\(dayName)'s burn is ready — open \(OpenBurnBarCore.OpenBurnBarIdentity.productName) for the numbers."
        }
        return content
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
        removePendingDigests()
        armedFireDate = nil
    }

    /// Identifier for day `dayOffset` of the horizon. Offset 0 keeps the
    /// canonical identifier so existing pending requests — and the legacy
    /// sweep — still resolve to the next digest.
    static func digestIdentifier(dayOffset: Int) -> String {
        dayOffset == 0
            ? OpenBurnBarCore.OpenBurnBarIdentity.dailyDigestNotificationIdentifier
            : "\(OpenBurnBarCore.OpenBurnBarIdentity.dailyDigestNotificationIdentifier).day\(dayOffset)"
    }

    private func removePendingDigests() {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: (0..<Self.horizonDays).map { Self.digestIdentifier(dayOffset: $0) }
                + OpenBurnBarCore.OpenBurnBarIdentity.legacyDailyDigestNotificationIdentifiers
        )
    }

    private func nextFireDate(after date: Date, at hour: Int) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(24 * 60 * 60)
    }
}

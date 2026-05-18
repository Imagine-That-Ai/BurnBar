import Foundation

/// Cross-platform scheduling abstraction for the cadence stack.
///
/// Platform shells (macOS, iOS, Android) provide a concrete
/// `CadenceSchedulerBackend` that handles the actual OS-level
/// scheduling (BGTaskScheduler, UNUserNotificationCenter,
/// WorkManager, AlarmManager).
///
/// The scheduler itself is pure logic: given a user's preference
/// and the current time, it decides which cadences are due and
/// returns a schedule. The backend is responsible for waking the
/// app at the right moment.
public actor CadenceScheduler {

    public struct Schedule: Sendable {
        public let dailyAt: DateComponents
        public let weeklyAt: DateComponents
        public let monthlyAt: DateComponents
        public let anomalyEnabled: Bool
        public let milestoneEnabled: Bool
        public let emailOptIn: Bool

        public init(
            dailyAt: DateComponents = DateComponents(hour: 7, minute: 0),
            weeklyAt: DateComponents = DateComponents(hour: 18, minute: 0, weekday: 1),
            monthlyAt: DateComponents = DateComponents(day: 1, hour: 8, minute: 0),
            anomalyEnabled: Bool = true,
            milestoneEnabled: Bool = true,
            emailOptIn: Bool = false
        ) {
            self.dailyAt = dailyAt
            self.weeklyAt = weeklyAt
            self.monthlyAt = monthlyAt
            self.anomalyEnabled = anomalyEnabled
            self.milestoneEnabled = milestoneEnabled
            self.emailOptIn = emailOptIn
        }
    }

    public struct DueCadences: Sendable {
        public let cadences: [CadenceArtifact.Cadence]
        public let nextDaily: Date?
        public let nextWeekly: Date?
        public let nextMonthly: Date?
    }

    private var schedule: Schedule
    private var lastDelivered: [CadenceArtifact.Cadence: Date]
    private let calendar: Calendar

    public init(
        schedule: Schedule = Schedule(),
        lastDelivered: [CadenceArtifact.Cadence: Date] = [:],
        calendar: Calendar = .current
    ) {
        self.schedule = schedule
        self.lastDelivered = lastDelivered
        self.calendar = calendar
    }

    /// Compute which cadences are due right now.
    public func due(now: Date = Date()) -> DueCadences {
        var due: [CadenceArtifact.Cadence] = []

        let nextDaily = nextOccurrence(of: schedule.dailyAt, after: now)
        if shouldDeliver(.daily, scheduledFor: scheduledToday(components: schedule.dailyAt, now: now), now: now) {
            due.append(.daily)
        }

        let nextWeekly = nextOccurrence(of: schedule.weeklyAt, after: now)
        let isWeeklyDay = schedule.weeklyAt.weekday.map { calendar.component(.weekday, from: now) == $0 } ?? true
        if isWeeklyDay, shouldDeliver(.weekly, scheduledFor: scheduledToday(components: schedule.weeklyAt, now: now), now: now) {
            due.append(.weekly)
        }

        let nextMonthly = nextOccurrence(of: schedule.monthlyAt, after: now)
        let isMonthlyDay = schedule.monthlyAt.day.map { calendar.component(.day, from: now) == $0 } ?? true
        if isMonthlyDay, shouldDeliver(.monthly, scheduledFor: scheduledToday(components: schedule.monthlyAt, now: now), now: now) {
            due.append(.monthly)
        }

        return DueCadences(
            cadences: due,
            nextDaily: nextDaily,
            nextWeekly: nextWeekly,
            nextMonthly: nextMonthly
        )
    }

    private func scheduledToday(components: DateComponents, now: Date) -> Date? {
        var today = calendar.dateComponents([.year, .month, .day], from: now)
        today.hour = components.hour
        today.minute = components.minute
        today.second = 0
        return calendar.date(from: today)
    }

    /// Mark a cadence as delivered so it isn't re-fired until the next window.
    public func markDelivered(_ cadence: CadenceArtifact.Cadence, at: Date = Date()) {
        lastDelivered[cadence] = at
    }

    /// Update the schedule (e.g., when the user changes notification prefs).
    public func updateSchedule(_ newSchedule: Schedule) {
        schedule = newSchedule
    }

    // MARK: - Internal

    private func shouldDeliver(
        _ cadence: CadenceArtifact.Cadence,
        scheduledFor: Date?,
        now: Date
    ) -> Bool {
        guard let scheduled = scheduledFor else { return false }
        // Deliver if we're within 15 minutes of the scheduled time
        // and we haven't delivered in the minimum gap period.
        let window: TimeInterval = 15 * 60
        let sinceLast = lastDelivered[cadence].map { now.timeIntervalSince($0) } ?? .infinity
        let minGap: TimeInterval
        switch cadence {
        case .daily: minGap = 20 * 60 * 60
        case .weekly: minGap = 6 * 24 * 60 * 60
        case .monthly: minGap = 28 * 24 * 60 * 60
        case .annual: minGap = 300 * 24 * 60 * 60
        case .anomaly, .milestone: minGap = 4 * 60 * 60
        }
        return abs(now.timeIntervalSince(scheduled)) < window && sinceLast > minGap
    }

    private func nextOccurrence(of components: DateComponents, after: Date) -> Date? {
        calendar.nextDate(after: after, matching: components, matchingPolicy: .nextTime)
    }
}

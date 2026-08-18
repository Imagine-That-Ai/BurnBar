import Foundation

/// A standing order — recurring work the fleet performs without being asked
/// each time ("every weekday at 9, run the suite on the Mini"). W6 Rhythm of
/// `plans/2026-08-17-war-room-master-plan.md`.
///
/// An order names *what* and *when*; it deliberately does not name *where*
/// unless the user pinned a machine. An unpinned order hands its
/// `requiredCapabilities` to `FlameRouter` at fire time, so the fleet can
/// change shape between runs without the order going stale.
public struct StandingOrder: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// When an order comes due. Kept small and total on purpose: every case is
    /// something a user can state in one sentence, and every case has an exact
    /// next-fire answer (no cron ambiguity).
    public enum Cadence: Sendable, Equatable, Hashable, Codable {
        case everyMinutes(Int)
        case daily(hour: Int, minute: Int)
        /// `weekday` follows `Calendar` conventions: 1 = Sunday … 7 = Saturday.
        case weekly(weekday: Int, hour: Int, minute: Int)
    }

    public var id: String
    public var title: String
    public var instruction: String
    public var cadence: Cadence
    /// Pinned machine, or nil to let the Flame choose at fire time.
    public var targetBodyID: String?
    public var requiredCapabilities: Set<String>
    public var isEnabled: Bool
    public var lastFiredAt: Date?

    public init(
        id: String,
        title: String,
        instruction: String,
        cadence: Cadence,
        targetBodyID: String? = nil,
        requiredCapabilities: Set<String> = [],
        isEnabled: Bool = true,
        lastFiredAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.cadence = cadence
        self.targetBodyID = targetBodyID
        self.requiredCapabilities = requiredCapabilities
        self.isEnabled = isEnabled
        self.lastFiredAt = lastFiredAt
    }

    /// Attribution for work this order starts. A standing order is a mission in
    /// the STARTED BY vocabulary — scheduled by the user, not decided by the
    /// Flame, so it must not be labelled as a Flame decision.
    public var originator: BurnBarOriginator {
        BurnBarOriginator(kind: .mission, missionID: id, confidence: .exact)
    }
}

public enum StandingOrderScheduler {
    /// The next moment this order should fire strictly after `date`.
    ///
    /// Returns nil for a disabled order or a nonsensical cadence, so callers
    /// can treat "no next fire" as a first-class state rather than guessing a
    /// far-future sentinel.
    public static func nextFireDate(
        for order: StandingOrder,
        after date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard order.isEnabled else { return nil }
        switch order.cadence {
        case let .everyMinutes(minutes):
            guard minutes > 0 else { return nil }
            // Interval cadences run from the last fire, so a machine that was
            // asleep resumes the rhythm instead of stampeding to catch up.
            let anchor = order.lastFiredAt ?? date
            let next = anchor.addingTimeInterval(TimeInterval(minutes * 60))
            return next > date ? next : date.addingTimeInterval(TimeInterval(minutes * 60))

        case let .daily(hour, minute):
            guard isValidTime(hour: hour, minute: minute) else { return nil }
            return nextOccurrence(
                of: DateComponents(hour: hour, minute: minute),
                after: date,
                calendar: calendar
            )

        case let .weekly(weekday, hour, minute):
            guard (1...7).contains(weekday), isValidTime(hour: hour, minute: minute) else { return nil }
            return nextOccurrence(
                of: DateComponents(hour: hour, minute: minute, weekday: weekday),
                after: date,
                calendar: calendar
            )
        }
    }

    /// `true` when the order's next fire has already arrived.
    public static func isDue(
        _ order: StandingOrder,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard order.isEnabled else { return false }
        let reference = order.lastFiredAt ?? .distantPast
        guard let next = nextFireDate(for: order, after: reference, calendar: calendar) else {
            return false
        }
        return next <= now
    }

    /// Every order that has come due, in the order they should be dispatched:
    /// longest-overdue first, then by id so a tie is deterministic.
    public static func due(
        orders: [StandingOrder],
        now: Date,
        calendar: Calendar = .current
    ) -> [StandingOrder] {
        orders
            .filter { isDue($0, now: now, calendar: calendar) }
            .sorted { lhs, rhs in
                let lhsFired = lhs.lastFiredAt ?? .distantPast
                let rhsFired = rhs.lastFiredAt ?? .distantPast
                if lhsFired != rhsFired { return lhsFired < rhsFired }
                return lhs.id < rhs.id
            }
    }

    private static func isValidTime(hour: Int, minute: Int) -> Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }

    private static func nextOccurrence(
        of components: DateComponents,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        // `.distantPast` predates the proleptic range Calendar will search from,
        // so anchor an unfired order at the caller's clock instead.
        let anchor = max(date, Date(timeIntervalSince1970: 0))
        return calendar.nextDate(
            after: anchor,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }
}

import Foundation

// MARK: - Pace Severity

public enum PaceSeverity: String, Codable, Sendable, Hashable {
    /// |delta| < onPaceThreshold — usage tracks elapsed time.
    case onPace
    /// delta > 0 — used more of the quota than time elapsed (burning fast).
    case aheadOfBudget
    /// delta < 0 — used less of the quota than time elapsed (headroom).
    case behindBudget
}

// MARK: - Ideal Pace

/// A snapshot of where a bucket's usage *should* be if it's to last the
/// full window. Pure derivation — never persisted, never networked.
public struct IdealPace: Hashable, Sendable {
    /// First moment of the current window (`windowEnd - duration`).
    public let windowStart: Date
    /// Last moment of the current window (the bucket's `resetsAt`).
    public let windowEnd: Date
    /// Fraction of the window that has elapsed at `now`, clamped to 0…1.
    public let elapsedFraction: Double
    /// Fraction of the quota used at `now`, clamped to 0…1.
    public let usedFraction: Double
    /// `usedFraction - elapsedFraction`. Positive = ahead of budget.
    public let delta: Double
    /// Bucketed signal for UI tinting.
    public let severity: PaceSeverity
    /// Short human label — `"on pace"`, `"+12% pace"`, `"-8% pace"`.
    public let humanLabel: String

    public init(
        windowStart: Date,
        windowEnd: Date,
        elapsedFraction: Double,
        usedFraction: Double,
        delta: Double,
        severity: PaceSeverity,
        humanLabel: String
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.elapsedFraction = elapsedFraction
        self.usedFraction = usedFraction
        self.delta = delta
        self.severity = severity
        self.humanLabel = humanLabel
    }
}

// MARK: - Pacing Math

public enum PacingMath {
    /// Below this absolute delta, the bucket is "on pace" and the UI
    /// should suppress the badge to avoid noise.
    public static let onPaceThreshold: Double = 0.03

    /// Duration of the active window ending at `resetsAt` for the given kind.
    /// Returns nil for kinds that don't have a finite repeating window.
    public static func windowDuration(
        for kind: ProviderQuotaWindowKind,
        resetsAt: Date,
        calendar: Calendar = .current
    ) -> TimeInterval? {
        switch kind {
        case .rollingHours:
            return 5 * 60 * 60
        case .daily:
            return 24 * 60 * 60
        case .weekly, .rollingDays:
            return 7 * 24 * 60 * 60
        case .monthly:
            // Use true calendar arithmetic so February (28d) and March
            // (31d) report different durations. Falls back to 30d if the
            // calendar refuses the operation.
            guard let start = calendar.date(byAdding: .month, value: -1, to: resetsAt) else {
                return 30 * 24 * 60 * 60
            }
            let interval = resetsAt.timeIntervalSince(start)
            return interval > 0 ? interval : 30 * 24 * 60 * 60
        case .lifetime, .custom:
            return nil
        }
    }

    /// Compute the ideal pace for a bucket. Returns nil when there is no
    /// meaningful window (lifetime, custom, or missing `resetsAt`).
    ///
    /// - Parameters:
    ///   - windowKind: Window kind of the bucket.
    ///   - resetsAt: When the current window ends.
    ///   - progressFraction: How much of the quota is used (0…1).
    ///   - now: Reference time. Default `Date()`.
    ///   - calendar: Calendar for month arithmetic.
    public static func pace(
        windowKind: ProviderQuotaWindowKind,
        resetsAt: Date?,
        progressFraction: Double,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> IdealPace? {
        guard let resetsAt else { return nil }
        guard let duration = windowDuration(for: windowKind, resetsAt: resetsAt, calendar: calendar) else {
            return nil
        }
        guard duration > 0 else { return nil }

        let windowEnd: Date
        let windowStart: Date
        let elapsedFraction: Double

        if now > resetsAt {
            // Snapshot is stale (the user's `resetsAt` is in the past).
            // Assume the next window has just begun at `resetsAt`; the
            // user is at the very start of the new period.
            windowEnd = resetsAt.addingTimeInterval(duration)
            windowStart = resetsAt
            elapsedFraction = 0
        } else {
            windowEnd = resetsAt
            windowStart = resetsAt.addingTimeInterval(-duration)
            let raw = now.timeIntervalSince(windowStart) / duration
            elapsedFraction = min(max(raw, 0), 1)
        }

        let used = min(max(progressFraction, 0), 1)
        let delta = used - elapsedFraction
        let severity: PaceSeverity = {
            if abs(delta) < onPaceThreshold { return .onPace }
            return delta > 0 ? .aheadOfBudget : .behindBudget
        }()

        return IdealPace(
            windowStart: windowStart,
            windowEnd: windowEnd,
            elapsedFraction: elapsedFraction,
            usedFraction: used,
            delta: delta,
            severity: severity,
            humanLabel: humanLabel(for: delta, severity: severity)
        )
    }

    /// Short label suitable for a badge: `"on pace"`, `"+12% pace"`,
    /// `"-8% pace"`. Rounded to the nearest whole percent.
    public static func humanLabel(for delta: Double, severity: PaceSeverity) -> String {
        switch severity {
        case .onPace:
            return "on pace"
        case .aheadOfBudget:
            return "+\(Int((delta * 100).rounded()))% pace"
        case .behindBudget:
            return "\(Int((delta * 100).rounded()))% pace"
        }
    }
}

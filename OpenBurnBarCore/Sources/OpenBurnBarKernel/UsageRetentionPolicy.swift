import Foundation

/// Default local retention for unbounded primary tables. The UI setting
/// overrides this when present; until then RefreshOrchestrator uses the
/// default so history cannot grow without a named bound.
public enum UsageRetentionPolicy: Sendable {
    public static let defaultRetentionDays = 180

    public static func cutoff(now: Date, retentionDays: Int = defaultRetentionDays) -> Date {
        now.addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))
    }

    public static func shouldReap(eventDate: Date, now: Date, retentionDays: Int = defaultRetentionDays) -> Bool {
        eventDate < cutoff(now: now, retentionDays: retentionDays)
    }
}

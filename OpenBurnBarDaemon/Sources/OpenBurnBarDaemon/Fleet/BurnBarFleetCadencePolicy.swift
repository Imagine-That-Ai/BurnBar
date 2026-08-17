/// Cadence tolerance shared by the ticker documentation and hardening tests.
///
/// The scheduler anchors each deadline to a monotonic clock rather than
/// sleeping for `cadence + buildDuration`, so build work does not accumulate
/// drift. The tolerance scales with overrides while preserving a small
/// absolute floor for short hermetic cadences.
public enum BurnBarFleetCadencePolicy {
    public static let defaultCadenceSeconds = 15
    public static let defaultToleranceSeconds: Double = 2
    public static let minimumToleranceSeconds: Double = 0.5

    /// Absolute interval and end-to-end drift tolerance for a cadence.
    ///
    /// `max(0.5s, 2s × cadence / 15s)` gives the default 13–17s window and
    /// keeps short test overrides observable without demanding sub-scheduler
    /// precision.
    public static func toleranceSeconds(for cadenceSeconds: Int) -> Double {
        max(
            minimumToleranceSeconds,
            defaultToleranceSeconds * Double(max(cadenceSeconds, 1))
                / Double(defaultCadenceSeconds)
        )
    }

    public static func intervalBounds(for cadenceSeconds: Int) -> ClosedRange<Double> {
        let cadence = Double(max(cadenceSeconds, 1))
        let tolerance = toleranceSeconds(for: cadenceSeconds)
        return (cadence - tolerance)...(cadence + tolerance)
    }
}

/// Monotonic deadline state used by the service ticker.
struct BurnBarFleetCadenceSchedule: Sendable {
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    let intervalNanoseconds: UInt64
    private(set) var nextDeadline: UInt64

    init(startingAt: UInt64, cadenceSeconds: Int) {
        let maxRepresentableSeconds = Int(UInt64.max / Self.nanosecondsPerSecond)
        let seconds = min(max(cadenceSeconds, 1), maxRepresentableSeconds)
        intervalNanoseconds = UInt64(seconds) * Self.nanosecondsPerSecond
        nextDeadline = startingAt
    }

    /// Advances one scheduled deadline. If a build overran one or more
    /// deadlines, skip those missed slots instead of starting a catch-up
    /// storm.
    mutating func deadline(afterBuildAt now: UInt64) -> UInt64 {
        nextDeadline += intervalNanoseconds
        guard nextDeadline <= now else { return nextDeadline }

        let missedIntervals = (now - nextDeadline) / intervalNanoseconds
        nextDeadline += (missedIntervals + 1) * intervalNanoseconds
        return nextDeadline
    }
}

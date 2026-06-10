import Foundation

// MARK: - Usage Replace Gate
//
// Decides whether a usages replacement can skip the full apply (double
// sort + aggregate-cache rebuild + `usagesVersion` bump) because the
// incoming rows are content-identical to the rows already applied AND no
// time-window boundary has been crossed since the last apply.
//
// The periodic refresh pipeline reloads the full usage table every cadence
// tick (60s minimum while active) even when nothing changed: every tick
// used to re-sort the table twice (`DataStoreCoordinator.replaceUsages` +
// `DashboardUsageViewModel`), rebuild the whole aggregate cache on the
// main actor, and bump `usagesVersion` — invalidating every cached
// dashboard/popover compute.
//
// The boundary deadline exists because the every-tick bump was
// functionally LOAD-BEARING for time-windowed aggregates: it is what reset
// "Today" at midnight and decayed the rolling 7d/30d totals as rows aged
// out on an idle dashboard. A content fingerprint alone would freeze those
// numbers, so a content-identical replacement is only skippable until the
// next boundary event (next local midnight, or the first moment an
// in-window row exits the rolling 7d/30d windows).
//
// See docs/architecture/macos-performance.md §14.

/// Order-insensitive content identity for a usages replacement.
struct UsageContentFingerprint: Equatable, Sendable {
    let rowCount: Int
    let contentHash: Int

    init(rows: [TokenUsage]) {
        rowCount = rows.count
        var combined = 0
        for row in rows {
            // Overflow addition keeps the combine order-insensitive — the
            // two replace paths deliver rows in different orderings.
            combined = combined &+ row.hashValue
        }
        contentHash = combined
    }
}

enum UsageReplaceGate {
    /// Rolling windows the dashboard renders (`TimeRange.last7Days` /
    /// `.last30Days` are anchored at `now`, so rows exit continuously).
    static let rollingWindowLengths: [TimeInterval] = [7 * 86_400, 30 * 86_400]

    /// `TimeRange` windows are computed with calendar day arithmetic, which
    /// can differ from fixed-length seconds by up to an hour across DST
    /// transitions. Shifting each row's exit earlier by this margin means
    /// we only ever rebuild EARLY, never render a stale window.
    static let windowExitSafetyMargin: TimeInterval = 3_600

    /// The earliest future instant at which any rendered aggregate can
    /// change with unchanged content:
    ///   * the next local midnight ("Today", "This Month", daily summaries),
    ///   * or the first moment an in-window row exits a rolling window.
    ///
    /// Conservative on purpose: each row's earliest attribution time is
    /// used (consumers filter on `startTime` or on `[start, end]`
    /// intersection), and the DST margin pulls exits earlier. Returning
    /// `now` means "do not skip" — a row is inside its exit margin.
    static func nextWindowBoundary(
        rows: [TokenUsage],
        after now: Date,
        calendar: Calendar = .current
    ) -> Date {
        var boundary = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        for windowLength in rollingWindowLengths {
            for row in rows {
                let attribution = min(row.startTime, row.endTime)
                let exit = attribution.addingTimeInterval(windowLength)
                guard exit > now else { continue }
                let safeExit = max(exit.addingTimeInterval(-windowExitSafetyMargin), now)
                if safeExit < boundary {
                    boundary = safeExit
                }
            }
        }
        return boundary
    }
}

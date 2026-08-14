import Foundation
import OpenBurnBarCore

// MARK: - Charts Data Service
//
// Owns the Charts page's `ChartsSnapshot`. Rows are captured on the main
// actor from the data store's already-cached usage window (cheap array
// slices), then the heavy bucketing/ranking runs in a detached task so the
// page never blocks the UI — even against a 5 000-row warm-launch window.
//
// Invalidation follows the dashboard convention: observe the store's
// `usagesVersion` Int (one bump per content-changing refresh) rather than
// the `[TokenUsage]` array itself.

@MainActor
@Observable
final class ChartsDataService {

    private(set) var snapshot: ChartsSnapshot?
    private(set) var isBuilding = false

    /// Identity of the snapshot currently requested or displayed.
    private var currentKey: SnapshotKey?
    private var buildTask: Task<Void, Never>?

    struct SnapshotKey: Equatable {
        let usagesVersion: Int
        let timeRange: TimeRange
    }

    /// Rebuilds the snapshot when either the data version or the selected
    /// range moved. Safe to call redundantly — identical keys are no-ops, so
    /// callers can drive this straight from `.task(id:)`.
    func refresh(dataStore: DataStore, timeRange: TimeRange) {
        let key = SnapshotKey(usagesVersion: dataStore.usagesVersion, timeRange: timeRange)
        guard key != currentKey else { return }
        currentKey = key

        // One clock for the selected range and the 31-day heatmap window so
        // the two filters cannot drift across a midnight tick mid-refresh.
        let now = Date()
        let recentRange = Self.recentRange(now: now)
        let requestedRange = timeRange.dateRange(now: now)

        // Keep the bounded warm cache only as a failure fallback. Charts must
        // read the requested database window or long-running users would see
        // analytics silently truncated to the newest hydration rows.
        let fallbackCovering = requestedRange == nil
            ? dataStore.usages(in: nil)
            : dataStore.usages(in: recentRange)
        let fallbackWindows = Self.deriveWindows(
            coveringRows: fallbackCovering,
            requestedRange: requestedRange,
            recentRange: recentRange
        )

        buildTask?.cancel()
        isBuilding = snapshot == nil
        buildTask = Task { [weak self] in
            let fetchedRows: (selected: [TokenUsage], recent: [TokenUsage])
            do {
                // Bounded TimeRange cases (today / 7d / 30d / month) all sit
                // inside the last 31 days, so one intersection scan covers
                // both windows. All-time still materializes covering rows for
                // burn / cache / provenance; heatmap, outliers, and entropy
                // have a SQL twin (`UsageStore.fetchChartSessionAnalytics`)
                // that matches `ChartsSnapshot.build` without TokenUsage.
                let coveringRows: [TokenUsage]
                if requestedRange == nil {
                    coveringRows = try await dataStore.fetchAllUsage()
                } else {
                    coveringRows = try await dataStore.fetchUsage(in: recentRange, limit: Int.max)
                }
                fetchedRows = Self.deriveWindows(
                    coveringRows: coveringRows,
                    requestedRange: requestedRange,
                    recentRange: recentRange
                )
            } catch {
                fetchedRows = fallbackWindows
            }
            guard !Task.isCancelled else { return }
            let built = await Self.buildDetached(
                rows: fetchedRows.selected,
                recentRows: fetchedRows.recent,
                timeRange: timeRange,
                usagesVersion: key.usagesVersion,
                now: now
            )
            guard !Task.isCancelled else { return }
            guard let self, self.currentKey == key else { return }
            self.snapshot = built
            self.isBuilding = false
        }
    }

    /// Last 31 calendar days ending at `now` — the Charts heatmap / outlier window.
    nonisolated static func recentRange(now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let lower = calendar.date(byAdding: .day, value: -31, to: now) ?? now
        return lower...now
    }

    /// Splits one covering fetch into the selected range and the 31-day window
    /// using the same intersection predicate as `fetchUsage(in:)`.
    nonisolated static func deriveWindows(
        coveringRows: [TokenUsage],
        requestedRange: ClosedRange<Date>?,
        recentRange: ClosedRange<Date>
    ) -> (selected: [TokenUsage], recent: [TokenUsage]) {
        if let requestedRange {
            return (
                coveringRows.filter { $0.intersects(dateRange: requestedRange) },
                coveringRows
            )
        }
        return (
            coveringRows,
            coveringRows.filter { $0.intersects(dateRange: recentRange) }
        )
    }

    private nonisolated static func buildDetached(
        rows: [TokenUsage],
        recentRows: [TokenUsage],
        timeRange: TimeRange,
        usagesVersion: Int,
        now: Date
    ) async -> ChartsSnapshot {
        await Task.detached(priority: .userInitiated) {
            ChartsSnapshot.build(
                rows: rows,
                recentRows: recentRows,
                timeRange: timeRange,
                usagesVersion: usagesVersion,
                now: now
            )
        }.value
    }
}

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

        // Keep the bounded warm cache only as a failure fallback. Charts must
        // read the requested database window or long-running users would see
        // analytics silently truncated to the newest hydration rows.
        let fallbackRows = dataStore.usages(in: timeRange.dateRange())
        let now = Date()
        let recentLower = Calendar.current.date(byAdding: .day, value: -31, to: now) ?? now
        let fallbackRecentRows = dataStore.usages(in: recentLower...now)

        buildTask?.cancel()
        isBuilding = snapshot == nil
        buildTask = Task { [weak self] in
            let rows: [TokenUsage]
            let recentRows: [TokenUsage]
            do {
                if let requestedRange = timeRange.dateRange() {
                    rows = try await dataStore.fetchUsage(in: requestedRange, limit: Int.max)
                } else {
                    rows = try await dataStore.fetchAllUsage()
                }
                recentRows = try await dataStore.fetchUsage(in: recentLower...now, limit: Int.max)
            } catch {
                rows = fallbackRows
                recentRows = fallbackRecentRows
            }
            guard !Task.isCancelled else { return }
            let built = await Self.buildDetached(
                rows: rows,
                recentRows: recentRows,
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

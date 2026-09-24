import Foundation

// MARK: - Materialized Dashboard Rollups (Wave 2.8)

/// Freshness contract for the materialized dashboard rollups.
///
/// * Fresh: the ledger is unchanged since the payload was computed
///   (`writeMarker` matches) and no rendered time-window boundary passed.
///   The reload serves one health-row read + one covering newest-N scan.
/// * Stale: content changed, the boundary passed, the payload is missing or
///   fails validation, or the health row is unreadable. The stale path runs
///   the full snapshot once and persists the new parts.
enum DashboardRollupFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case stale
}

enum DashboardRollupServiceError: Error, Equatable {
    /// `refreshIfStale == false` and the persisted rollups are stale: the
    /// caller asked for a cheap read and there is no fresh payload to serve.
    case staleRollupsRefreshDisabled
}

struct MaterializedDashboardRollupPayload: Codable, Sendable {
    static let currentSchemaVersion = 1

    /// Payload contract version. A mismatch fails validation (stale).
    let schemaVersion: Int
    let computedAt: Date
    /// `UsageTableWriteMarker` value the aggregates were computed at.
    /// In-process only: a relaunch resets the marker, so a payload from a
    /// previous launch always reads stale and recomputes once. Safe by
    /// construction — never serves cross-launch numbers as fresh.
    let writeMarker: Int
    /// The `nextWindowBoundary` the caller passed at materialize time,
    /// recorded for audit. Freshness uses the LIVE boundary the caller
    /// passes on each read (same value as the coordinator gate).
    let windowBoundary: Date
    /// Per-window GROUP BY rows keyed by `TimeRange.rawValue`. Keyed by the
    /// raw string rather than the enum: JSON dictionaries cannot key on it.
    let aggregatesByRange: [String: [UsageAggregateRow]]
    /// Trailing cost series, offsets `0...7` (8 entries, 0 == today).
    let dayCosts: [Double]
    /// Trailing token series, offsets `0...7` (8 entries, 0 == today).
    let dayTokens: [Int]
    let dailySummaries: [DailyUsageSummary]
}

/// Serves dashboard snapshots from materialized per-window rollups,
/// following the `WorkflowInsightRollupService` pattern: the analytic core
/// (`DashboardRollupParts`) is persisted as JSON in the `dashboard_rollups`
/// retrieval-health row, freshness is a write-marker + window-boundary
/// comparison, and the health write is single and gated on content change.
///
/// The covering newest-N rows are NOT materialized: every read — fresh or
/// stale — pairs its parts with a live index-backed covering scan, so
/// session lists always reflect the current `loadedUsageLimit` window.
/// Totals stay SQL-accurate because the aggregates only serve while the
/// ledger is unchanged (marker match) inside the same window edges
/// (boundary match) — the exact contract the coordinator gate enforces.
@MainActor
final class DashboardRollupService {
    // `nonisolated` so the snapshot pipeline can run off the main actor:
    // `DataStore` is a `@MainActor` class (hence Sendable) and every store
    // accessor the pipeline touches hops internally.
    private nonisolated let dataStore: DataStore
    private nonisolated let nowProvider: @Sendable () -> Date

    init(dataStore: DataStore, nowProvider: @escaping @Sendable () -> Date = Date.init) {
        self.dataStore = dataStore
        self.nowProvider = nowProvider
    }

    /// Dashboard snapshot, served from the materialized rollups when fresh.
    ///
    /// Fresh path: 1 health-row read + 1 covering scan — constant queries at
    /// any ledger size. Stale path (`refreshIfStale`): one full snapshot
    /// fetch whose parts are persisted for later reads. Materialize failure
    /// records a failed health row (best effort) and rethrows: no numbers
    /// are fabricated, and the coordinator keeps its previous state.
    func snapshotAsync(
        loadedUsageLimit: Int,
        windowBoundary: Date,
        refreshIfStale: Bool = true
    ) async throws -> DashboardUsageSnapshot {
        try await buildSnapshotOffMainActor(
            loadedUsageLimit: loadedUsageLimit,
            windowBoundary: windowBoundary,
            refreshIfStale: refreshIfStale
        )
    }

    /// `nonisolated` async bridge so `snapshotAsync` leaves the main actor
    /// here (SE-0338); all GRDB work then runs off the main actor.
    private nonisolated func buildSnapshotOffMainActor(
        loadedUsageLimit: Int,
        windowBoundary: Date,
        refreshIfStale: Bool
    ) async throws -> DashboardUsageSnapshot {
        // Single health-row read feeds both the materialized payload and
        // the write-skip comparison in `upsertHealthIfChanged`. A failed
        // cache read fails open to recompute — it must never strand the
        // dashboard the way a failed analytic query would.
        let existingHealth = await loadHealthRecord()
        // In-memory marker read (no query). Sampled BEFORE the fetch: a
        // write racing the fetch may already be visible in the rows, and the
        // next read then recomputes once more. Never the reverse (stale
        // parts recorded under a newer marker).
        let marker = await dataStore.usageTableWriteMarker()
        let now = nowProvider()

        let payload = decodePayload(from: existingHealth)
        // Carry the stored JSON verbatim while the payload is unchanged so
        // the write-skip comparison never trips on encoder nondeterminism.
        var payloadJSON = payload != nil ? existingHealth?.detailsJSON : nil
        let freshness = freshness(for: payload, marker: marker, now: now, windowBoundary: windowBoundary)

        switch freshness {
        case .fresh:
            let parts = parts(from: payload)
            // Live covering scan: the one query the fresh path pays beyond
            // the health read. Index-backed newest-N — constant at any
            // ledger size, unlike the GROUP BY fan-out it replaces.
            let covering = try await dataStore.fetchRecentUsage(limit: loadedUsageLimit)
            let snapshot = UsageStore.makeDashboardSnapshot(
                coveringUsages: covering,
                parts: parts,
                now: now
            )
            await upsertHealthIfChanged(
                existing: existingHealth,
                payloadJSON: payloadJSON,
                status: .healthy,
                errorCode: nil,
                errorMessage: nil
            )
            return snapshot
        case .stale:
            guard refreshIfStale else {
                throw DashboardRollupServiceError.staleRollupsRefreshDisabled
            }
            do {
                let (snapshot, fetchedParts) = try await dataStore.fetchDashboardUsageSnapshotWithParts(
                    loadedUsageLimit: loadedUsageLimit,
                    now: now
                )
                let materialized = try materialize(
                    parts: fetchedParts,
                    marker: marker,
                    windowBoundary: windowBoundary,
                    now: now
                )
                payloadJSON = materialized.json
                await upsertHealthIfChanged(
                    existing: existingHealth,
                    payloadJSON: payloadJSON,
                    status: .healthy,
                    errorCode: nil,
                    errorMessage: nil
                )
                return snapshot
            } catch {
                let message = "Dashboard rollups could not refresh: \(error.localizedDescription)"
                await upsertHealthIfChanged(
                    existing: existingHealth,
                    payloadJSON: payloadJSON,
                    status: .failed,
                    errorCode: "DASHBOARD_ROLLUP_MATERIALIZE_FAILED",
                    errorMessage: message
                )
                throw error
            }
        }
    }

    private nonisolated func freshness(
        for payload: MaterializedDashboardRollupPayload?,
        marker: Int,
        now: Date,
        windowBoundary: Date
    ) -> DashboardRollupFreshness {
        guard let payload else {
            return .stale
        }
        guard payload.writeMarker == marker else {
            return .stale
        }
        guard now < windowBoundary else {
            return .stale
        }
        return .fresh
    }

    /// Builds a fresh payload without persisting it — the single gated
    /// health write in `buildSnapshotOffMainActor` persists the result, so
    /// the stale path never writes the health row twice per refresh.
    private nonisolated func materialize(
        parts: DashboardRollupParts,
        marker: Int,
        windowBoundary: Date,
        now: Date
    ) throws -> (payload: MaterializedDashboardRollupPayload, json: String?) {
        var aggregatesByRange: [String: [UsageAggregateRow]] = [:]
        aggregatesByRange.reserveCapacity(TimeRange.allCases.count)
        for range in TimeRange.allCases {
            aggregatesByRange[range.rawValue] = parts.aggregatesByRange[range] ?? []
        }
        let payload = MaterializedDashboardRollupPayload(
            schemaVersion: MaterializedDashboardRollupPayload.currentSchemaVersion,
            computedAt: now,
            writeMarker: marker,
            windowBoundary: windowBoundary,
            aggregatesByRange: aggregatesByRange,
            dayCosts: parts.dayCosts,
            dayTokens: parts.dayTokens,
            dailySummaries: parts.dailySummaries
        )
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8)
        return (payload, json)
    }

    private nonisolated func loadHealthRecord() async -> RetrievalHealthRecord? {
        guard let rows = try? await dataStore.fetchRetrievalHealth() else { return nil } // try?-ok(cache read recovered)
        return rows.first(where: { $0.subsystem == .dashboardRollups })
    }

    /// Decodes + validates the persisted payload. Any failure — missing row,
    /// corrupt JSON, schema mismatch, short day series, incomplete window
    /// coverage — reads as stale so the next refresh recomputes. Validation
    /// (not just decoding) matters: `makeDashboardSnapshot` indexes
    /// `dayCosts[0...7]` directly and a short series would trap.
    private nonisolated func decodePayload(
        from record: RetrievalHealthRecord?
    ) -> MaterializedDashboardRollupPayload? {
        guard let json = record?.detailsJSON?.data(using: .utf8),
              let payload = try? JSONDecoder().decode( // try?-ok(optional cache decode)
                  MaterializedDashboardRollupPayload.self,
                  from: json
              ),
              payload.schemaVersion == MaterializedDashboardRollupPayload.currentSchemaVersion,
              payload.dayCosts.count == 8,
              payload.dayTokens.count == 8,
              TimeRange.allCases.allSatisfy({ payload.aggregatesByRange[$0.rawValue] != nil })
        else {
            return nil
        }
        return payload
    }

    /// Rebuilds parts from a validated payload. Only called on the fresh
    /// path, where decode validation already guaranteed every window key.
    private nonisolated func parts(
        from payload: MaterializedDashboardRollupPayload?
    ) -> DashboardRollupParts {
        var aggregatesByRange: [TimeRange: [UsageAggregateRow]] = [:]
        for range in TimeRange.allCases {
            aggregatesByRange[range] = payload?.aggregatesByRange[range.rawValue] ?? []
        }
        return DashboardRollupParts(
            aggregatesByRange: aggregatesByRange,
            dayCosts: payload?.dayCosts ?? Array(repeating: 0, count: 8),
            dayTokens: payload?.dayTokens ?? Array(repeating: 0, count: 8),
            dailySummaries: payload?.dailySummaries ?? []
        )
    }

    /// Persists the dashboard-rollups health row only when its semantic
    /// content (status, payload JSON, error fields) actually changed. The
    /// fresh path used to be a full GROUP BY fan-out; it must not trade
    /// that for a pointless write on the DatabasePool single-writer queue
    /// on every reload.
    private nonisolated func upsertHealthIfChanged(
        existing: RetrievalHealthRecord?,
        payloadJSON: String?,
        status: RetrievalHealthStatus,
        errorCode: String?,
        errorMessage: String?
    ) async {
        if let existing,
           existing.status == status,
           existing.detailsJSON == payloadJSON,
           existing.errorCode == errorCode,
           existing.errorMessage == errorMessage {
            return
        }
        let now = nowProvider()
        do {
            try await dataStore.upsertRetrievalHealth(
                RetrievalHealthRecord(
                    subsystem: .dashboardRollups,
                    status: status,
                    errorCode: errorCode,
                    errorMessage: errorMessage,
                    detailsJSON: payloadJSON,
                    observedAt: now,
                    updatedAt: now
                )
            )
        } catch {
            AppLogger.dataStore.silentFailure("upsertHealth", error: error)
        }
    }
}

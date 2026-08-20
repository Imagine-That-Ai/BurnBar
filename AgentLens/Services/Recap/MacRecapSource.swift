import Foundation
import OpenBurnBarCore

/// Supplies the recap engine with real database rows.
///
/// Deliberately **not** `MacInsightDataSource`, which filters
/// `dataStore.usages` — the bounded warm in-memory cache. That is correct for a
/// seven-day verdict and silently wrong for a recap: a month older than the warm
/// window would come back truncated, and the deck would confidently report
/// records and totals computed from whatever happened to still be cached.
struct MacRecapSource: RecapSource {

    let dataStore: DataStore

    // MARK: - Single month

    func rows(for window: RecapWindow) async throws -> RecapRowBatch {
        let calendar = Calendar.current
        let interval = window.interval(calendar: calendar)
        let facts = try await dataStore.fetchChartFactRows(
            in: interval.start...interval.end
        )
        let sessions = try await fetchSessions(startingIn: interval)

        // `fetchChartFactRows` uses intersection semantics, so trim to rows that
        // actually *started* in the month — against the hoisted bounds, not a
        // per-row `contains`.
        return Self.batch(
            window: window,
            factRows: facts.filter { $0.startTime >= interval.start && $0.startTime < interval.end },
            sessions: sessions
        )
    }

    // MARK: - Many months, one scan

    /// One covering scan over the whole span, bucketed by month.
    ///
    /// `token_usage` is indexed on `startTime`, but `conversations` has no time
    /// index at all — so a per-month loop would be a full table scan of it per
    /// month, twelve times over during a history backfill. Scanning the span
    /// once and bucketing in memory is the same trick `ChartsDataService`
    /// already uses to serve two windows from one fetch.
    func rows(for windows: [RecapWindow]) async throws -> [RecapWindow: RecapRowBatch] {
        guard let earliest = windows.min(), let latest = windows.max() else { return [:] }
        let calendar = Calendar.current
        let lower = earliest.start(calendar: calendar)
        let upper = latest.end(calendar: calendar)

        let facts = try await dataStore.fetchChartFactRows(in: lower...upper)
        let sessions = try await fetchSessions(
            startingIn: DateInterval(start: lower, end: upper)
        )

        var factsByWindow: [RecapWindow: [ChartFactRow]] = [:]
        for row in facts {
            let window = RecapWindow(containing: row.startTime, calendar: calendar)
            factsByWindow[window, default: []].append(row)
        }
        var sessionsByWindow: [RecapWindow: [InsightSessionRow]] = [:]
        for row in sessions {
            let window = RecapWindow(containing: row.startTime, calendar: calendar)
            sessionsByWindow[window, default: []].append(row)
        }

        return windows.reduce(into: [:]) { result, window in
            result[window] = Self.batch(
                window: window,
                factRows: factsByWindow[window] ?? [],
                sessions: sessionsByWindow[window] ?? []
            )
        }
    }

    private func fetchSessions(startingIn interval: DateInterval) async throws -> [InsightSessionRow] {
        // Conversation data is a bonus, not a precondition: if the projection
        // fails or the table is empty the recap still has every usage-derived
        // insight, and the tool rules simply do not fire.
        // try?-ok(conversation data is a bonus, not a precondition — see the note above)
        (try? await dataStore.fetchRecapSessionRows(
            startingIn: interval.start..<interval.end
        )) ?? []
    }

    // MARK: - Conversion

    /// Rows are expected to already belong to `window` — both call sites filter
    /// or bucket first, and `contains` rebuilds the month's bounds per row.
    static func batch(
        window: RecapWindow,
        factRows: [ChartFactRow],
        sessions: [InsightSessionRow]
    ) -> RecapRowBatch {
        RecapRowBatch(
            window: window,
            usages: factRows.map(usageRow),
            sessions: sessions,
            isPartial: false,
            // A local database read always sees whole conversations, so tool
            // claims are available even when this month happens to have none.
            hasSessionData: true,
            exactShare: exactShare(of: factRows)
        )
    }

    /// `ChartFactRow` carries `totalTokens` but not `outputTokens`; output is
    /// recovered exactly, since `totalTokens` is defined as the sum of the five
    /// buckets.
    private static func usageRow(_ row: ChartFactRow) -> InsightUsageRow {
        let accounted = row.inputTokens + row.cacheCreationTokens
            + row.cacheReadTokens + row.reasoningTokens
        let output = max(0, row.totalTokens - accounted)
        return InsightUsageRow(
            sessionID: row.sessionId,
            provider: row.provider.rawValue,
            model: row.model,
            projectName: row.projectName.isEmpty ? nil : row.projectName,
            startTime: row.startTime,
            endTime: row.endTime,
            inputTokens: row.inputTokens,
            outputTokens: output,
            reasoningTokens: row.reasoningTokens,
            cacheReadTokens: row.cacheReadTokens,
            cacheCreationTokens: row.cacheCreationTokens,
            totalTokens: row.totalTokens,
            costUSD: row.cost
        )
    }

    /// Cost-weighted share of rows whose provenance is exact, which is what
    /// keeps the recap quieter about a month assembled largely from estimates.
    static func exactShare(of rows: [ChartFactRow]) -> Double {
        var total = 0.0
        var exact = 0.0
        for row in rows {
            let cost = max(0, row.cost)
            total += cost
            switch row.provenanceConfidence {
            case .exact, .derivedExact: exact += cost
            default: break
            }
        }
        guard total > 0 else { return rows.isEmpty ? 1 : 0 }
        return min(max(exact / total, 0), 1)
    }
}

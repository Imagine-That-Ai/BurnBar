import Foundation
import OpenBurnBarInsights
import OpenBurnBarRecap

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

        return Self.batches(
            for: Set(windows),
            factRows: facts,
            sessions: sessions,
            calendar: calendar
        )
    }

    // MARK: - Complete history, one scan

    func completeRows(through window: RecapWindow) async throws -> [RecapWindow: RecapRowBatch]? {
        let calendar = Calendar.current
        let upper = window.end(calendar: calendar)
        let facts = try await dataStore.fetchChartFactRows(in: nil)
            .filter { $0.startTime < upper }
        let sessions: [InsightSessionRow]
        do {
            sessions = try await dataStore.fetchRecapSessionRows(
                startingIn: Date.distantPast..<upper
            )
        } catch {
            // A usage-only scan can still build ordinary monthly comparisons,
            // but it cannot prove that a tool or project never appeared in an
            // older conversation. Decline the complete-history contract so the
            // composer suppresses lifetime and first-ever wording.
            return nil
        }

        let months = Set(facts.map { RecapWindow(containing: $0.startTime, calendar: calendar) })
            .union(sessions.map { RecapWindow(containing: $0.startTime, calendar: calendar) })
            .filter { $0 <= window }
            .union([window])
        return Self.batches(
            for: months,
            factRows: facts,
            sessions: sessions,
            calendar: calendar
        )
    }

    private func fetchSessions(startingIn interval: DateInterval) async throws -> [InsightSessionRow] {
        // Conversation data is a bonus, not a precondition: if the projection
        // fails or the table is empty the recap still has every usage-derived
        // insight, and the tool rules simply do not fire.
        // A failed read costs only the tool and task-title rules, which already
        // tolerate absence through their data floors. It must not fail the month.
        // try?-ok(conversation rows are additive to the recap)
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

    private static func batches(
        for windows: Set<RecapWindow>,
        factRows: [ChartFactRow],
        sessions: [InsightSessionRow],
        calendar: Calendar
    ) -> [RecapWindow: RecapRowBatch] {
        let factsByWindow = Dictionary(grouping: factRows) {
            RecapWindow(containing: $0.startTime, calendar: calendar)
        }
        let sessionsByWindow = Dictionary(grouping: sessions) {
            RecapWindow(containing: $0.startTime, calendar: calendar)
        }
        return windows.reduce(into: [:]) { result, window in
            result[window] = batch(
                window: window,
                factRows: factsByWindow[window] ?? [],
                sessions: sessionsByWindow[window] ?? []
            )
        }
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

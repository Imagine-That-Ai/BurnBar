import Foundation
import OpenBurnBarRecap
import FirebaseFirestore
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Reads a true calendar month out of Firestore for the recap engine.
///
/// Deliberately **not** `MobileInsightDataSource`. That type maps a window onto
/// a `RollupWindowKey` by *duration*, so any 28–31 day span becomes
/// `.thirtyDays` — a rolling rollup. "August 2026" would render as "the last 30
/// days", and every historical month would collide on the same key. There is no
/// monthly rollup to ask for, so the recap reads the underlying rows instead and
/// pages until the month is actually exhausted.
struct MobileRecapSource: RecapSource {

    /// Loads one month, reporting whether it managed to read all of it.
    typealias MonthLoader = @Sendable (
        _ interval: DateInterval,
        _ pageSize: Int,
        _ pageBudget: Int
    ) async -> (rows: [TokenUsage], isPartial: Bool)

    let pageSize: Int
    /// Ceiling on pages per month. A heavy month must not turn opening the
    /// recap into thousands of reads; when the ceiling is hit the month is
    /// marked partial and stops claiming totals rather than quietly reporting
    /// a truncated one.
    let pageBudget: Int
    private let loadMonth: MonthLoader

    init(
        pageSize: Int = 300,
        pageBudget: Int = 24,
        loadMonth: @escaping MonthLoader = MobileRecapSource.firestoreLoader
    ) {
        self.pageSize = pageSize
        self.pageBudget = pageBudget
        self.loadMonth = loadMonth
    }

    // MARK: - RecapSource

    func rows(for window: RecapWindow) async throws -> RecapRowBatch {
        let calendar = Calendar.current
        let interval = window.interval(calendar: calendar)
        let result = await loadMonth(interval, pageSize, pageBudget)

        // Compare against the bounds already computed above; `contains`
        // rebuilds the month per row, and a month can be thousands of rows.
        let inWindow = result.rows.filter {
            $0.startTime >= interval.start && $0.startTime < interval.end
        }
        return RecapRowBatch(
            window: window,
            usages: inWindow.map(MobileInsightDataSource.insightRow(from:)),
            // Conversations are not synced to Firestore, so tool and task-title
            // insights cannot fire here. Saying "no session data" rather than
            // "no sessions" is what stops a rule concluding the user used no
            // tools when the truth is this device cannot see them.
            sessions: [],
            isPartial: result.isPartial,
            hasSessionData: false,
            exactShare: Self.exactShare(of: inWindow)
        )
    }

    /// Months are independent, so a backfill loads them concurrently rather
    /// than serializing three paginated Firestore walks behind each other.
    func rows(for windows: [RecapWindow]) async throws -> [RecapWindow: RecapRowBatch] {
        try await withThrowingTaskGroup(of: (RecapWindow, RecapRowBatch).self) { group in
            for window in windows {
                group.addTask { (window, try await self.rows(for: window)) }
            }
            var result: [RecapWindow: RecapRowBatch] = [:]
            for try await (window, batch) in group {
                result[window] = batch
            }
            return result
        }
    }

    // MARK: - Firestore paging

    /// Walks `users/{uid}/usage` for the month, following the cursor until it
    /// runs out or the page budget does.
    ///
    /// Filters on `startTime` only, which needs nothing more than the default
    /// single-field index — no composite index and no rules change.
    @Sendable
    static func firestoreLoader(
        interval: DateInterval,
        pageSize: Int,
        pageBudget: Int
    ) async -> (rows: [TokenUsage], isPartial: Bool) {
        await paginate(pageSize: pageSize, pageBudget: pageBudget) { cursor in
            try await FirestoreRepository.shared.fetchUsagePage(
                pageSize: pageSize,
                after: cursor,
                provider: nil,
                model: nil,
                device: nil,
                startDate: interval.start,
                // Firestore's range filter is inclusive; the month's
                // exclusive upper bound sits a hair below it.
                endDate: interval.end.addingTimeInterval(-0.001)
            )
        }
    }

    /// Walks pages until the source runs out or the budget does, reporting
    /// whether what came back is the whole span.
    ///
    /// `fetchPage` is injected — and the cursor left generic — so the paging
    /// contract, above all what a *failed* read reports, can be exercised
    /// without Firestore. In production `Cursor` is `DocumentSnapshot`, a
    /// Firestore reference type, which is why the whole walk stays on the main
    /// actor and never crosses an isolation boundary.
    @MainActor
    static func paginate<Cursor>(
        pageSize: Int,
        pageBudget: Int,
        fetchPage: @MainActor @Sendable (Cursor?) async throws -> ([TokenUsage], Cursor?)
    ) async -> (rows: [TokenUsage], isPartial: Bool) {
        var collected: [TokenUsage] = []
        var cursor: Cursor?

        for _ in 0..<pageBudget {
            do {
                let (page, next) = try await fetchPage(cursor)
                collected.append(contentsOf: page)
                guard let next, page.count >= pageSize else {
                    return (collected, false)
                }
                cursor = next
            } catch {
                // A failed read leaves the rest of the month unread, and that is
                // true however many rows made it back first. Nothing collected
                // means "we could not read the month", never "the month was
                // empty" — reporting that as complete is what would let the
                // composer persist a zero-usage month as a real baseline,
                // dragging averages down and manufacturing records.
                return (collected, true)
            }
        }
        // Budget exhausted with the cursor still live: more month than we read.
        return (collected, true)
    }

    // MARK: - Conversion

    /// Cost-weighted share of rows whose provenance is exact.
    ///
    /// Read from `TokenUsage` before the projection to `InsightUsageRow`, which
    /// does not carry provenance — otherwise every cloud month would claim to
    /// be exact and the recap would sound equally sure about estimated ones.
    static func exactShare(of rows: [TokenUsage]) -> Double {
        let total = rows.reduce(0.0) { $0 + max(0, $1.cost) }
        guard total > 0 else { return rows.isEmpty ? 1 : 0 }
        let exact = rows.reduce(0.0) { partial, row in
            switch row.provenanceConfidence {
            case .exact, .derivedExact: return partial + max(0, row.cost)
            default: return partial
            }
        }
        return min(max(exact / total, 0), 1)
    }
}

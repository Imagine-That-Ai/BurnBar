import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Locks in the fail-closed behavior hardened in `BudgetForecast.forecast(forRule:)`.
///
/// The forecast feeds a BUDGET projection off the `token_usage` spend history. Two `try?`
/// sites used to collapse ANY read fault (missing/corrupt `token_usage`, locked SQLCipher
/// key, etc.) into `$0` spent — indistinguishable from genuinely-zero recent spend. A
/// failed read therefore painted a rule as fully under budget (0% used, full headroom,
/// will-not-exceed), the most dangerous possible misread for a spend guardrail.
///
/// These tests prove the two halves of the contract:
///   1. A genuine empty/zero-spend ledger still produces an AVAILABLE projection (0% used,
///      full headroom, will-not-exceed) — we did not over-correct into false alarms.
///   2. A real read fault (the `token_usage` table is absent) now FAILS CLOSED: the
///      projection is marked `dataUnavailable`, `willExceed == true`, `headroom == 0`,
///      `usedPercent == nil`, and the ETA helpers return nil. No consumer can mistake an
///      unreadable ledger for a safe rule.
final class BudgetForecastMattersTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRule(
        amountUSD: Double = 100,
        period: BudgetPeriod = .month
    ) -> BudgetRule {
        BudgetRule(
            id: "rule-\(UUID().uuidString)",
            scope: .global,
            amountUSD: amountUSD,
            period: period
        )
    }

    /// Builds an in-memory queue whose `token_usage` table exists with exactly the columns
    /// `BudgetForecast.sumCost` reads. Optionally seeds spend rows.
    private func makeQueueWithLedger(rows: [(cost: Double, startTime: Date)] = []) async throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: ":memory:")
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE token_usage (
                    id TEXT PRIMARY KEY,
                    projectName TEXT,
                    providerID TEXT,
                    providerAccountID TEXT,
                    cost DOUBLE NOT NULL,
                    startTime DATETIME NOT NULL
                )
                """)
            for (index, row) in rows.enumerated() {
                try db.execute(
                    sql: "INSERT INTO token_usage (id, projectName, cost, startTime) VALUES (?, ?, ?, ?)",
                    arguments: ["row-\(index)", "proj", row.cost, row.startTime]
                )
            }
        }
        return queue
    }

    /// Builds an in-memory queue that deliberately LACKS `token_usage`, so any read of the
    /// spend history throws ("no such table: token_usage") — our read-fault stand-in.
    private func makeQueueWithoutLedger() async throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: ":memory:")
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE placeholder (id TEXT PRIMARY KEY)")
        }
        return queue
    }

    // MARK: - 1. Genuine zero spend stays AVAILABLE (no false alarm)

    func test_emptyLedger_producesAvailableUnderBudgetProjection() async throws {
        let queue = try await makeQueueWithLedger() // table exists, no rows
        let forecast = BudgetForecast(dbQueue: queue)
        let rule = makeRule(amountUSD: 100, period: .month)

        let projection = await forecast.forecast(forRule: rule)

        XCTAssertFalse(projection.dataUnavailable, "an empty-but-readable ledger is available data, not a read fault")
        XCTAssertEqual(projection.currentSpend, 0, accuracy: 0.0001)
        XCTAssertEqual(projection.usedPercent, 0, "genuine zero spend reads as 0% used (not nil/unknown)")
        XCTAssertEqual(projection.headroom, 100, accuracy: 0.0001, "full headroom for a truly unspent rule")
        XCTAssertFalse(projection.willExceed, "a truly unspent rule must not be flagged as exceeding")
    }

    func test_seededLedger_computesRealSpendAndStaysAvailable() async throws {
        // Pin the reference to mid-month noon in the same calendar the forecast uses.
        // A bare `Date()` flaked here: a run in the first two hours of a month put the
        // seeded rows (1-2 hours earlier) in the PREVIOUS month, outside the monthly
        // window, so the summed spend read back as a legitimate 0.
        let reference = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))
        )
        let queue = try await makeQueueWithLedger(rows: [
            (cost: 30, startTime: reference.addingTimeInterval(-3_600)),
            (cost: 12, startTime: reference.addingTimeInterval(-7_200))
        ])
        let forecast = BudgetForecast(dbQueue: queue)
        let rule = makeRule(amountUSD: 100, period: .month)

        let projection = await forecast.forecast(forRule: rule, reference: reference)

        XCTAssertFalse(projection.dataUnavailable)
        XCTAssertEqual(projection.currentSpend, 42, accuracy: 0.0001, "spend is summed from the readable ledger")
        XCTAssertEqual(try XCTUnwrap(projection.usedPercent), 0.42, accuracy: 0.0001)
        XCTAssertEqual(projection.headroom, 58, accuracy: 0.0001)
    }

    // MARK: - 2. Read fault FAILS CLOSED (the security fix)

    func test_readFault_failsClosed_notSilentlyUnderBudget() async throws {
        let queue = try await makeQueueWithoutLedger() // SELECT ... FROM token_usage throws
        let forecast = BudgetForecast(dbQueue: queue)
        let rule = makeRule(amountUSD: 100, period: .month)

        let projection = await forecast.forecast(forRule: rule)

        // The whole point: a read fault must NOT look like a safe, unspent rule.
        XCTAssertTrue(projection.dataUnavailable, "an unreadable ledger must mark the projection unavailable")
        XCTAssertTrue(projection.willExceed, "unknown spend fails closed: treated as potentially over the limit")
        XCTAssertEqual(projection.headroom, 0, "no headroom is promised when spend is unknown")
        XCTAssertNil(projection.usedPercent, "unknown spend is nil (unknown), never a reassuring 0%")
        XCTAssertNil(projection.daysUntilLimit, "no ETA can be projected from unknown spend")
        XCTAssertNil(projection.projectedHitDate(), "no hit-date can be projected from unknown spend")
    }

    func test_readFault_preservesRuleIdentityForUI() async throws {
        let queue = try await makeQueueWithoutLedger()
        let forecast = BudgetForecast(dbQueue: queue)
        let rule = makeRule(amountUSD: 250, period: .week)

        let projection = await forecast.forecast(forRule: rule)

        // The UI still needs to key the "forecast unavailable" chip to the right rule/limit.
        XCTAssertEqual(projection.ruleID, rule.id)
        XCTAssertEqual(projection.limit, 250, accuracy: 0.0001)
    }

    func test_readFault_acrossPeriods_allFailClosed() async throws {
        let queue = try await makeQueueWithoutLedger()
        let forecast = BudgetForecast(dbQueue: queue)

        for period in BudgetPeriod.allCases {
            let rule = makeRule(amountUSD: 100, period: period)
            let projection = await forecast.forecast(forRule: rule)
            XCTAssertTrue(
                projection.dataUnavailable,
                "period \(period.rawValue) must fail closed on a read fault"
            )
            XCTAssertTrue(projection.willExceed, "period \(period.rawValue) must not read as under budget")
        }
    }
}

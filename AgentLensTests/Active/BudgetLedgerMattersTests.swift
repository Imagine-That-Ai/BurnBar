import XCTest
import GRDB
@testable import OpenBurnBar
import OpenBurnBarCore

/// Fail-closed behavior for `BudgetLedger.snapshot(forRules:)`.
///
/// `BudgetLedger` feeds `BudgetGate`, the per-request spend gate. The original fast-path
/// `snapshot` swallowed any DB read failure with `try? ... ?? 0`, reporting ZERO accumulated
/// spend on error — a fail-open: an over-limit request would slip through when the ledger
/// was unreadable. The fix removes the silent `?? 0` and instead OMITS a rule from the
/// result when its read fails, so callers can distinguish "definitely $0" (key present,
/// value `0`) from "unknown — read failed" (key absent) and fail closed on the latter.
@MainActor
final class BudgetLedgerMattersTests: XCTestCase {

    // MARK: - Helpers

    /// A migrated DB whose `token_usage` table exists (reads succeed; rows can be inserted).
    private func makeMigratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true)
        return queue
    }

    /// A bare DB with NO migrations: `token_usage` does not exist, so every spend read throws
    /// ("no such table: token_usage"). This injects a deterministic read fault without needing
    /// to corrupt or lock a file.
    private func makeUnmigratedQueue() throws -> DatabaseQueue {
        try DatabaseQueue()
    }

    private func globalRule(id: String, limit: Double = 100) -> BudgetRule {
        BudgetRule(
            id: id,
            scope: .global,
            label: "Test \(id)",
            amountUSD: limit,
            period: .month,
            behavior: .hardBlock
        )
    }

    private func insertGlobalUsage(into queue: DatabaseQueue, cost: Double, at startTime: Date) async throws {
        let store = UsageStore(dbQueue: queue)
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "ledger-test-\(UUID().uuidString)",
            projectName: "LedgerTest",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: cost,
            startTime: startTime,
            endTime: startTime
        )
        try await store.insert(usage)
    }

    // MARK: - Legit zero (read succeeds, no rows)

    /// A successful read against an empty ledger must report a present key with value `0` —
    /// the legitimate "no spend yet" signal, NOT an omission.
    func test_snapshot_emptyLedger_reportsPresentZero() async throws {
        let queue = try makeMigratedQueue()
        let ledger = BudgetLedger(dbQueue: queue)
        let rule = globalRule(id: "rule-empty")

        let result = await ledger.snapshot(forRules: [rule], reference: Date())

        XCTAssertTrue(result.keys.contains(rule.id), "Successful read of an empty ledger must keep the key present")
        XCTAssertEqual(result[rule.id], 0, "Empty ledger is a legitimate $0, not an omission")
    }

    /// A successful read with rows returns the real accumulated total.
    func test_snapshot_withSpend_reportsRealTotal() async throws {
        let queue = try makeMigratedQueue()
        let now = Date()
        try await insertGlobalUsage(into: queue, cost: 12.50, at: now)
        try await insertGlobalUsage(into: queue, cost: 7.25, at: now)

        let ledger = BudgetLedger(dbQueue: queue)
        let rule = globalRule(id: "rule-spend")

        let result = await ledger.snapshot(forRules: [rule], reference: now.addingTimeInterval(60))

        XCTAssertEqual(try XCTUnwrap(result[rule.id]), 19.75, accuracy: 0.0001)
    }

    // MARK: - Fail closed (read throws)

    /// When the underlying read throws, the rule's key must be ABSENT (fail-closed signal),
    /// never present-with-zero (which is the old fail-open behavior the fix removes).
    func test_snapshot_readFailure_omitsRuleInsteadOfReportingZero() async throws {
        let queue = try makeUnmigratedQueue() // no token_usage table -> reads throw
        let ledger = BudgetLedger(dbQueue: queue)
        let rule = globalRule(id: "rule-faulted")

        let result = await ledger.snapshot(forRules: [rule], reference: Date())

        XCTAssertFalse(
            result.keys.contains(rule.id),
            "A failed read must OMIT the rule so the gate fails closed, not report a fail-open 0"
        )
        XCTAssertNil(result[rule.id], "Missing key (unknown spend) must not collapse to 0")
    }

    /// The fail-closed contract `result[rule.id] ?? rule.amountUSD` treats an unreadable
    /// ledger as at-limit. The old `?? 0` would have treated it as fully available headroom.
    func test_snapshot_readFailure_failClosedLookupTreatsRuleAtLimit() async throws {
        let queue = try makeUnmigratedQueue()
        let ledger = BudgetLedger(dbQueue: queue)
        let rule = globalRule(id: "rule-atlimit", limit: 50)

        let result = await ledger.snapshot(forRules: [rule], reference: Date())

        let failClosedSpend = result[rule.id] ?? rule.amountUSD
        XCTAssertEqual(failClosedSpend, 50, "Unknown spend must read as at-limit, not as $0")

        let failOpenSpend = result[rule.id] ?? 0
        XCTAssertEqual(failOpenSpend, 0, "Demonstrates the fail-open the fix protects callers from")
        XCTAssertNotEqual(failClosedSpend, failOpenSpend, "Fail-closed and fail-open lookups must diverge on a read fault")
    }

    /// Mixed batch: readable rules stay present (success), faulted rules are omitted. Here we
    /// drive the same ledger with a faulted DB so every rule is omitted, then a healthy DB so
    /// every rule is present — proving omission is per-read, not a wholesale empty return.
    func test_snapshot_mixedBatch_presencePerRead() async throws {
        let rules = [globalRule(id: "a"), globalRule(id: "b"), globalRule(id: "c")]

        let faulted = BudgetLedger(dbQueue: try makeUnmigratedQueue())
        let faultedResult = await faulted.snapshot(forRules: rules, reference: Date())
        XCTAssertTrue(faultedResult.isEmpty, "All reads faulted -> all rules omitted (fail closed)")

        let healthy = BudgetLedger(dbQueue: try makeMigratedQueue())
        let healthyResult = await healthy.snapshot(forRules: rules, reference: Date())
        XCTAssertEqual(Set(healthyResult.keys), Set(rules.map(\.id)), "All reads succeeded -> all rules present")
        for rule in rules {
            XCTAssertEqual(healthyResult[rule.id], 0, "Healthy empty ledger reports legitimate present 0")
        }
    }
}

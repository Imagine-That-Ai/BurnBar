import XCTest
@testable import OpenBurnBar

/// Deterministic, thread-safe test clock for driving day/month rollovers.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }

    func set(_ newDate: Date) {
        lock.lock()
        date = newDate
        lock.unlock()
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return date
        }
    }
}

private func utcDate(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func textUsage(promptTokens: Int, outputTokens: Int, cachedTokens: Int = 0) -> UsageCurationTokenUsage {
    UsageCurationTokenUsage(
        promptTokens: promptTokens,
        outputTokens: outputTokens,
        cachedTokens: cachedTokens,
        lane: .text
    )
}

/// U5: client belt-and-braces daily USD cap for cloud curation.
///
/// Invariants under test:
///  - **Price math:** the static CoreWeave table prices text and multimodal
///    lanes independently (input vs output rates).
///  - **Cap boundary:** `cloudBudgetOK` is a strict `spend < cap` check; a
///    zero/negative cap fail-closes; the default cap is
///    `MemoryExtractionPolicy.defaultDailyCapUSD`.
///  - **Day rollover:** a UTC day change resets the ledger to $0.
///  - **Persistence:** spend survives re-instantiation within the same day.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
final class UsageMemoryBudgetLedgerTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
    }

    private func makeLedger(clock: TestClock) throws -> UsageMemoryBudgetLedger {
        UsageMemoryBudgetLedger(defaults: try makeDefaults(), now: clock.now)
    }

    // MARK: - Price math

    func testTextLanePriceMath() {
        // $0.14/M input + $0.28/M output.
        let cost = UsageMemoryBudgetLedger.PriceTable.estimatedCostUSD(
            promptTokens: 1_000_000,
            outputTokens: 1_000_000,
            lane: .text
        )
        XCTAssertEqual(cost, 0.42, accuracy: 0.000001)
    }

    func testMultimodalLanePriceMath() {
        // $0.23/M input + $0.96/M output.
        let cost = UsageMemoryBudgetLedger.PriceTable.estimatedCostUSD(
            promptTokens: 1_000_000,
            outputTokens: 500_000,
            lane: .multimodal
        )
        XCTAssertEqual(cost, 0.23 + 0.48, accuracy: 0.000001)
    }

    func testTypicalBatchCostsFractionsOfACent() {
        // A realistic curation batch (~4K prompt / 400 output, text lane) must
        // price far under a cent — sanity anchor for the daily $0.50 cap.
        let cost = UsageMemoryBudgetLedger.PriceTable.estimatedCostUSD(
            promptTokens: 4_000,
            outputTokens: 400,
            lane: .text
        )
        XCTAssertEqual(cost, 0.000672, accuracy: 0.000001)
        XCTAssertLessThan(cost, 0.01)
    }

    func testNegativeTokenCountsClampToZeroCost() {
        let cost = UsageMemoryBudgetLedger.PriceTable.estimatedCostUSD(
            promptTokens: -100,
            outputTokens: -100,
            lane: .text
        )
        XCTAssertEqual(cost, 0)
    }

    // MARK: - Recording + accumulation

    func testFreshLedgerHasZeroSpendAndBudgetOK() throws {
        let ledger = try makeLedger(clock: TestClock(utcDate(year: 2026, month: 8, day: 15)))
        XCTAssertEqual(ledger.todaysSpendUSD, 0)
        XCTAssertTrue(ledger.cloudBudgetOK())
    }

    func testRecordAccumulatesAcrossCallsAndLanes() throws {
        let ledger = try makeLedger(clock: TestClock(utcDate(year: 2026, month: 8, day: 15)))

        ledger.record(usage: textUsage(promptTokens: 1_000_000, outputTokens: 0), lane: .text)
        XCTAssertEqual(ledger.todaysSpendUSD, 0.14, accuracy: 0.000001)

        ledger.record(
            usage: UsageCurationTokenUsage(promptTokens: 1_000_000, outputTokens: 0, cachedTokens: 0, lane: .multimodal),
            lane: .multimodal
        )
        XCTAssertEqual(ledger.todaysSpendUSD, 0.14 + 0.23, accuracy: 0.000001)
    }

    // MARK: - Cap boundary

    func testCapIsAStrictLessThanBoundary() throws {
        let ledger = try makeLedger(clock: TestClock(utcDate(year: 2026, month: 8, day: 15)))
        ledger.record(usage: textUsage(promptTokens: 2_500_000, outputTokens: 0), lane: .text) // $0.35

        XCTAssertTrue(ledger.cloudBudgetOK(capUSD: 0.50), "$0.35 spent < $0.50 cap.")
        // Exactly at the cap: spend < spend is false, so the budget closes.
        XCTAssertFalse(ledger.cloudBudgetOK(capUSD: ledger.todaysSpendUSD))

        ledger.record(usage: textUsage(promptTokens: 2_500_000, outputTokens: 0), lane: .text) // $0.70 total
        XCTAssertFalse(ledger.cloudBudgetOK(capUSD: 0.50), "$0.70 spent >= $0.50 cap.")
    }

    func testDefaultCapIsThePolicyDailyCap() throws {
        XCTAssertEqual(MemoryExtractionPolicy.defaultDailyCapUSD, 0.50)
        let ledger = try makeLedger(clock: TestClock(utcDate(year: 2026, month: 8, day: 15)))
        // $0.42 < $0.50 default → OK; another $0.42 → $0.84 > $0.50 → closed.
        ledger.record(usage: textUsage(promptTokens: 1_000_000, outputTokens: 1_000_000), lane: .text)
        XCTAssertTrue(ledger.cloudBudgetOK())
        ledger.record(usage: textUsage(promptTokens: 1_000_000, outputTokens: 1_000_000), lane: .text)
        XCTAssertFalse(ledger.cloudBudgetOK())
    }

    func testZeroOrNegativeCapFailsClosed() throws {
        let ledger = try makeLedger(clock: TestClock(utcDate(year: 2026, month: 8, day: 15)))
        XCTAssertFalse(ledger.cloudBudgetOK(capUSD: 0))
        XCTAssertFalse(ledger.cloudBudgetOK(capUSD: -1))
    }

    // MARK: - Day rollover

    func testUTCDayRolloverResetsSpendAndReopensBudget() throws {
        let clock = TestClock(utcDate(year: 2026, month: 8, day: 15, hour: 23))
        let ledger = try makeLedger(clock: clock)
        ledger.record(usage: textUsage(promptTokens: 5_000_000, outputTokens: 0), lane: .text) // $0.70
        XCTAssertFalse(ledger.cloudBudgetOK())

        clock.advance(by: 2 * 60 * 60) // 23:00 Aug 15 → 01:00 Aug 16 UTC
        XCTAssertEqual(ledger.todaysSpendUSD, 0, "A new UTC day starts a fresh ledger.")
        XCTAssertTrue(ledger.cloudBudgetOK())
    }

    func testSameDayAdvanceDoesNotReset() throws {
        let clock = TestClock(utcDate(year: 2026, month: 8, day: 15, hour: 1))
        let ledger = try makeLedger(clock: clock)
        ledger.record(usage: textUsage(promptTokens: 1_000_000, outputTokens: 0), lane: .text)

        clock.advance(by: 12 * 60 * 60) // still Aug 15 UTC
        XCTAssertEqual(ledger.todaysSpendUSD, 0.14, accuracy: 0.000001)
    }

    func testRecordAfterRolloverStartsFromZeroNotYesterdaysTotal() throws {
        let clock = TestClock(utcDate(year: 2026, month: 8, day: 15))
        let ledger = try makeLedger(clock: clock)
        ledger.record(usage: textUsage(promptTokens: 1_000_000, outputTokens: 0), lane: .text) // $0.14

        clock.set(utcDate(year: 2026, month: 8, day: 16))
        ledger.record(usage: textUsage(promptTokens: 2_000_000, outputTokens: 0), lane: .text) // $0.28
        XCTAssertEqual(ledger.todaysSpendUSD, 0.28, accuracy: 0.000001)
    }

    // MARK: - Persistence

    func testSpendPersistsAcrossInstancesWithinTheSameDay() throws {
        let defaults = try makeDefaults()
        let clock = TestClock(utcDate(year: 2026, month: 8, day: 15))
        let first = UsageMemoryBudgetLedger(defaults: defaults, now: clock.now)
        first.record(usage: textUsage(promptTokens: 1_000_000, outputTokens: 0), lane: .text)

        let second = UsageMemoryBudgetLedger(defaults: defaults, now: clock.now)
        XCTAssertEqual(second.todaysSpendUSD, 0.14, accuracy: 0.000001)
    }

    // MARK: - Day key

    func testDayKeyIsUTC() {
        XCTAssertEqual(UsageMemoryBudgetLedger.dayKey(for: utcDate(year: 2026, month: 8, day: 15, hour: 0)), "2026-08-15")
        XCTAssertEqual(UsageMemoryBudgetLedger.dayKey(for: utcDate(year: 2026, month: 8, day: 15, hour: 23)), "2026-08-15")
        XCTAssertEqual(UsageMemoryBudgetLedger.dayKey(for: utcDate(year: 2026, month: 1, day: 2)), "2026-01-02")
    }
}

/// U5: monthly curation telemetry (numbers only, never plaintext).
final class UsageCurationTelemetryTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
    }

    func testCallTokensMapCachedTokensToCacheReadFields() {
        // Server promptTokens INCLUDES cached; the app's ModelUsage-style
        // inputTokens excludes cache reads.
        let tokens = UsageCurationTelemetry.callTokens(
            from: UsageCurationTokenUsage(promptTokens: 1200, outputTokens: 240, cachedTokens: 300, lane: .text)
        )
        XCTAssertEqual(tokens.inputTokens, 900)
        XCTAssertEqual(tokens.cacheReadTokens, 300)
        XCTAssertEqual(tokens.outputTokens, 240)
        XCTAssertEqual(tokens.totalTokens, 1440)
    }

    func testCallTokensClampCachedAbovePrompt() {
        let tokens = UsageCurationTelemetry.callTokens(
            from: UsageCurationTokenUsage(promptTokens: 100, outputTokens: 10, cachedTokens: 500, lane: .text)
        )
        XCTAssertEqual(tokens.inputTokens, 0, "Cached can never exceed prompt; input clamps at zero.")
        XCTAssertEqual(tokens.cacheReadTokens, 100)
    }

    func testRecordAccumulatesMonthlyAggregate() throws {
        let clock = TestClock(utcDate(year: 2026, month: 8, day: 15))
        let telemetry = UsageCurationTelemetry(defaults: try makeDefaults(), now: clock.now)

        telemetry.record(
            usage: UsageCurationTokenUsage(promptTokens: 1_000_000, outputTokens: 1_000_000, cachedTokens: 100, lane: .text)
        )
        telemetry.record(
            usage: UsageCurationTokenUsage(promptTokens: 500, outputTokens: 50, cachedTokens: 25, lane: .multimodal)
        )

        let aggregate = telemetry.currentMonth
        XCTAssertEqual(aggregate.monthKey, "2026-08")
        XCTAssertEqual(aggregate.promptTokens, 1_000_500)
        XCTAssertEqual(aggregate.outputTokens, 1_000_050)
        XCTAssertEqual(aggregate.cachedTokens, 125)
        XCTAssertEqual(aggregate.callCount, 2)
        // $0.42 (text 1M/1M) + the multimodal fraction.
        let multimodalCost = UsageMemoryBudgetLedger.PriceTable.estimatedCostUSD(
            promptTokens: 500,
            outputTokens: 50,
            lane: .multimodal
        )
        XCTAssertEqual(aggregate.estimatedUSD, 0.42 + multimodalCost, accuracy: 0.000001)
    }

    func testMonthRolloverStartsAFreshAggregate() throws {
        let clock = TestClock(utcDate(year: 2026, month: 8, day: 31, hour: 23))
        let telemetry = UsageCurationTelemetry(defaults: try makeDefaults(), now: clock.now)
        telemetry.record(
            usage: UsageCurationTokenUsage(promptTokens: 1000, outputTokens: 100, cachedTokens: 0, lane: .text)
        )
        XCTAssertEqual(telemetry.currentMonth.callCount, 1)

        clock.set(utcDate(year: 2026, month: 9, day: 1, hour: 1))
        XCTAssertEqual(telemetry.currentMonth, .empty(monthKey: "2026-09"))

        telemetry.record(
            usage: UsageCurationTokenUsage(promptTokens: 200, outputTokens: 20, cachedTokens: 0, lane: .text)
        )
        XCTAssertEqual(telemetry.currentMonth.promptTokens, 200, "September restarts from zero, not August's totals.")
        XCTAssertEqual(telemetry.currentMonth.callCount, 1)
    }

    func testAggregatePersistsAcrossInstances() throws {
        let defaults = try makeDefaults()
        let clock = TestClock(utcDate(year: 2026, month: 8, day: 15))
        let first = UsageCurationTelemetry(defaults: defaults, now: clock.now)
        first.record(
            usage: UsageCurationTokenUsage(promptTokens: 1000, outputTokens: 100, cachedTokens: 10, lane: .text)
        )

        let second = UsageCurationTelemetry(defaults: defaults, now: clock.now)
        XCTAssertEqual(second.currentMonth, first.currentMonth)
        XCTAssertEqual(second.currentMonth.callCount, 1)
    }

    func testPersistedAggregateContainsOnlyNumbersAndTheMonthKey() throws {
        // The privacy invariant, checked at the persistence boundary: the
        // stored JSON has exactly the six numeric/month fields — no room for
        // candidate text to leak in.
        let defaults = try makeDefaults()
        let telemetry = UsageCurationTelemetry(defaults: defaults, now: { utcDate(year: 2026, month: 8, day: 15) })
        telemetry.record(
            usage: UsageCurationTokenUsage(promptTokens: 1000, outputTokens: 100, cachedTokens: 10, lane: .text)
        )

        let data = try XCTUnwrap(defaults.data(forKey: "usageCurationTelemetryMonthly"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys),
            ["monthKey", "promptTokens", "outputTokens", "cachedTokens", "callCount", "estimatedUSD"]
        )
        XCTAssertEqual(json["monthKey"] as? String, "2026-08")
    }

    func testMonthKeyIsUTC() {
        XCTAssertEqual(UsageCurationTelemetry.monthKey(for: utcDate(year: 2026, month: 8, day: 15)), "2026-08")
        XCTAssertEqual(UsageCurationTelemetry.monthKey(for: utcDate(year: 2026, month: 12, day: 31, hour: 23)), "2026-12")
    }
}

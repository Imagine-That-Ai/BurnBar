import XCTest
@testable import OpenBurnBar

/// Pure-logic tests for `MemoryRecallBudget.forReply`.
///
/// No network, no disk, no MainActor — just math.
final class MemoryRecallBudgetTests: XCTestCase {

    // MARK: - Default mode (highRecall: false)

    func test_offMode_returnsDocumentedDefaults() {
        let budget = MemoryRecallBudget.forReply(arbiterBudget: 500, highRecall: false)
        XCTAssertEqual(budget.limit, MemoryRecallBudget.defaultLimit)
        XCTAssertEqual(budget.tokenBudget, 500)
    }

    func test_offMode_limitMatchesMemoryRecallRequestDefault() {
        // Verify defaultLimit stays in sync with MemoryRecallRequest's default parameter (8).
        XCTAssertEqual(MemoryRecallBudget.defaultLimit, 8)
    }

    // MARK: - High-recall mode (highRecall: true)

    func test_onMode_limitIsLargerThanOff() {
        let off = MemoryRecallBudget.forReply(arbiterBudget: 500, highRecall: false)
        let on = MemoryRecallBudget.forReply(arbiterBudget: 500, highRecall: true)
        XCTAssertGreaterThan(on.limit, off.limit)
    }

    func test_onMode_tokenBudgetIsLargerThanOff() {
        let off = MemoryRecallBudget.forReply(arbiterBudget: 500, highRecall: false)
        let on = MemoryRecallBudget.forReply(arbiterBudget: 500, highRecall: true)
        XCTAssertGreaterThan(on.tokenBudget, off.tokenBudget)
    }

    func test_onMode_limitEqualsHighRecallConstant() {
        let on = MemoryRecallBudget.forReply(arbiterBudget: 1000, highRecall: true)
        XCTAssertEqual(on.limit, MemoryRecallBudget.highRecallLimit)
    }

    func test_onMode_tokenBudgetIsApproximatelyDoubled() {
        let arbiter = 800
        let on = MemoryRecallBudget.forReply(arbiterBudget: arbiter, highRecall: true)
        XCTAssertEqual(on.tokenBudget, 1600)
    }

    // MARK: - Both modes: positive values

    func test_bothValues_arePositive_whenOffAndArbiterIsPositive() {
        let budget = MemoryRecallBudget.forReply(arbiterBudget: 1, highRecall: false)
        XCTAssertGreaterThan(budget.limit, 0)
        XCTAssertGreaterThan(budget.tokenBudget, 0)
    }

    func test_bothValues_arePositive_whenOnAndArbiterIsPositive() {
        let budget = MemoryRecallBudget.forReply(arbiterBudget: 1, highRecall: true)
        XCTAssertGreaterThan(budget.limit, 0)
        XCTAssertGreaterThan(budget.tokenBudget, 0)
    }

    // MARK: - Determinism

    func test_sameInputProducesSameOutput() {
        let a = MemoryRecallBudget.forReply(arbiterBudget: 300, highRecall: true)
        let b = MemoryRecallBudget.forReply(arbiterBudget: 300, highRecall: true)
        XCTAssertEqual(a.limit, b.limit)
        XCTAssertEqual(a.tokenBudget, b.tokenBudget)
    }
}

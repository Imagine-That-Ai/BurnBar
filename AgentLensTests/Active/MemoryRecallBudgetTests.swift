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

    func test_onMode_tokenBudgetTracksArbiterCap_notDoubled() {
        // High-recall raises the LIMIT, not the token budget: the arbiter caps the wrapped
        // .memory section at its own memoryBudget regardless, so a doubled ask only forced
        // overflow + truncation (M2). The token budget tracks the arbiter allocation.
        let off = MemoryRecallBudget.forReply(arbiterBudget: 500, highRecall: false)
        let on = MemoryRecallBudget.forReply(arbiterBudget: 500, highRecall: true)
        XCTAssertEqual(on.tokenBudget, off.tokenBudget)
        XCTAssertEqual(on.tokenBudget, 500)
    }

    func test_onMode_limitEqualsHighRecallConstant() {
        let on = MemoryRecallBudget.forReply(arbiterBudget: 1000, highRecall: true)
        XCTAssertEqual(on.limit, MemoryRecallBudget.highRecallLimit)
    }

    func test_tokenBudgetEqualsArbiterAllocationInBothModes() {
        let arbiter = 800
        XCTAssertEqual(MemoryRecallBudget.forReply(arbiterBudget: arbiter, highRecall: true).tokenBudget, arbiter)
        XCTAssertEqual(MemoryRecallBudget.forReply(arbiterBudget: arbiter, highRecall: false).tokenBudget, arbiter)
    }

    // MARK: - Wrapper envelope overhead (M2)

    func test_wrapperTokenOverhead_isAccountedAndReasonable() {
        // The wrapper envelope (tags + provenance + CRITICAL RULE) is non-trivial; the
        // recall packer must charge it so the wrapped section fits the arbiter cap. Sanity
        // bounds: at least 100 tokens (the rule alone is ~150 words) and under 400.
        XCTAssertGreaterThan(MemoryRecallBudget.wrapperTokenOverhead, 100)
        XCTAssertLessThan(MemoryRecallBudget.wrapperTokenOverhead, 400)
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

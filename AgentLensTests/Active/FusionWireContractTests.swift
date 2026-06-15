import XCTest
@testable import OpenBurnBarCore

/// Locks the daemon→iOS wire contract for the fusion-spend SSE frame
/// (`openburnbar_fusion_spend`). Runs in the app test target because the
/// OpenBurnBarCore SPM test target's swift-testing dependency is unresolvable in
/// an isolated worktree; the same assertions also live in
/// `FusionSessionSpendTests` for CI.
final class FusionWireContractTests: XCTestCase {

    private func session() -> FusionSessionSpend {
        let rows = [
            FusionUsageRow(parentRequestID: "elderwand-WIRE", stageLabel: "panel[0]", modelID: "claude-opus",
                           inputTokens: 1000, outputTokens: 500, cost: 0.10, confidence: .exact, recordedAt: Date(timeIntervalSince1970: 10)),
            FusionUsageRow(parentRequestID: "elderwand-WIRE", stageLabel: "judge", modelID: "gpt-5",
                           inputTokens: 2000, outputTokens: 300, cost: 0.05, confidence: .exact, recordedAt: Date(timeIntervalSince1970: 11)),
            FusionUsageRow(parentRequestID: "elderwand-WIRE", stageLabel: "synthesis", modelID: "claude-opus",
                           inputTokens: 1500, outputTokens: 800, cost: 0.04, confidence: .highConfidenceEstimate, recordedAt: Date(timeIntervalSince1970: 12))
        ]
        return FusionSpendAggregator.newestSession(from: rows)!
    }

    func test_sessionSurvivesWireRoundTrip() throws {
        let original = session()
        // Encode exactly as the daemon does: { wireKey: session }.
        let frame = try JSONEncoder().encode([FusionSessionSpend.wireKey: original])

        // Decode exactly as iOS does: JSONSerialization to find the key, then
        // JSONDecoder on the value.
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        let spendValue = try XCTUnwrap(object[FusionSessionSpend.wireKey])
        let spendData = try JSONSerialization.data(withJSONObject: spendValue)
        let decoded = try JSONDecoder().decode(FusionSessionSpend.self, from: spendData)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.totalCost, original.totalCost, accuracy: 1e-9)
        XCTAssertEqual(decoded.lineItems.map(\.stage), [.panel(index: 0), .judge, .synthesis])
        XCTAssertEqual(decoded.costMultiplier, original.costMultiplier)
        XCTAssertEqual(decoded.aggregateConfidence, .highConfidenceEstimate, "Weakest confidence must survive the wire.")
        XCTAssertFalse(decoded.aggregateConfidence.isExact)
    }

    func test_wireKeyMatchesContract() {
        XCTAssertEqual(FusionSessionSpend.wireKey, "openburnbar_fusion_spend")
    }

    // MARK: - Period partition confidence (impact-screen honesty)

    func test_partitionConfidence_estimatedWhenAnyContributingRowEstimated() {
        let rows = [
            FusionUsageRow(parentRequestID: "elderwand-A", stageLabel: "panel[0]", modelID: "m",
                           inputTokens: 100, outputTokens: 100, cost: 0.10, confidence: .exact, recordedAt: Date()),
            FusionUsageRow(parentRequestID: nil, stageLabel: nil, modelID: "n",
                           inputTokens: 100, outputTokens: 100, cost: 0.20, confidence: .lowConfidenceEstimate, recordedAt: Date())
        ]
        let totals = FusionSpendAggregator.partition(rows)
        XCTAssertTrue(totals.isEstimated, "Any estimated contributing row makes the period total an estimate.")
        XCTAssertEqual(totals.aggregateConfidence, .lowConfidenceEstimate)
    }

    func test_partitionConfidence_exactWhenAllExactOrZeroCost() {
        let rows = [
            FusionUsageRow(parentRequestID: "elderwand-A", stageLabel: "panel[0]", modelID: "m",
                           inputTokens: 100, outputTokens: 100, cost: 0.10, confidence: .exact, recordedAt: Date()),
            // A zero-cost estimated row must NOT taint a non-zero exact total.
            FusionUsageRow(parentRequestID: nil, stageLabel: nil, modelID: "n",
                           inputTokens: 0, outputTokens: 0, cost: 0.0, confidence: .unknown, recordedAt: Date())
        ]
        let totals = FusionSpendAggregator.partition(rows)
        XCTAssertFalse(totals.isEstimated)
        XCTAssertEqual(totals.aggregateConfidence, .exact)
    }
}

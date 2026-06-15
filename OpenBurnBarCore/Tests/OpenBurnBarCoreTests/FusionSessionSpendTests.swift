import XCTest
@testable import OpenBurnBarCore

final class FusionSessionSpendTests: XCTestCase {

    // MARK: - Fixtures

    private func row(
        parent: String?,
        stage: String?,
        model: String,
        input: Int = 0,
        output: Int = 0,
        cost: Double,
        confidence: BurnBarUsageConfidence = .exact,
        at seconds: TimeInterval = 0
    ) -> FusionUsageRow {
        FusionUsageRow(
            parentRequestID: parent,
            stageLabel: stage,
            modelID: model,
            inputTokens: input,
            outputTokens: output,
            cost: cost,
            confidence: confidence,
            recordedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    /// A canonical 3-panel + judge + synthesis run.
    private func canonicalRun(parent: String = "elderwand-AAA") -> [FusionUsageRow] {
        [
            row(parent: parent, stage: "panel[0]", model: "claude-opus", input: 1000, output: 500, cost: 0.10, at: 10),
            row(parent: parent, stage: "panel[1]", model: "gpt-5",       input: 1000, output: 500, cost: 0.08, at: 11),
            row(parent: parent, stage: "panel[2]", model: "gemini-pro",  input: 1000, output: 500, cost: 0.06, at: 12),
            row(parent: parent, stage: "judge",     model: "claude-opus", input: 2000, output: 300, cost: 0.05, at: 13),
            row(parent: parent, stage: "synthesis", model: "gpt-5",       input: 1500, output: 800, cost: 0.04, at: 14),
        ]
    }

    // MARK: - Sum-of-parts reconciliation (the hard invariant)

    func test_sessionTotal_equalsSumOfRecordedCosts() throws {
        let rows = canonicalRun()
        let session = try XCTUnwrap(FusionSpendAggregator.newestSession(from: rows))
        let ledgerSum = rows.reduce(0) { $0 + $1.cost }
        XCTAssertEqual(session.totalCost, ledgerSum, accuracy: 1e-9,
                       "Session total must equal the sum of the recorded cost rows — no repricing.")
        XCTAssertEqual(session.totalCost, 0.33, accuracy: 1e-9)
    }

    func test_sessionTotals_sumTokens() throws {
        let session = try! XCTUnwrap(FusionSpendAggregator.newestSession(from: canonicalRun()))
        XCTAssertEqual(session.totalInputTokens, 6500)
        XCTAssertEqual(session.totalOutputTokens, 2600)
        XCTAssertEqual(session.totalTokens, 9100)
    }

    // MARK: - Itemization + stage ordering

    func test_lineItems_orderedPanelsThenJudgeThenSynthesis() throws {
        let session = try! XCTUnwrap(FusionSpendAggregator.newestSession(from: canonicalRun()))
        XCTAssertEqual(session.lineItems.count, 5)
        XCTAssertEqual(session.lineItems[0].stage, .panel(index: 0))
        XCTAssertEqual(session.lineItems[1].stage, .panel(index: 1))
        XCTAssertEqual(session.lineItems[2].stage, .panel(index: 2))
        XCTAssertEqual(session.lineItems[3].stage, .judge)
        XCTAssertEqual(session.lineItems[4].stage, .synthesis)
        XCTAssertEqual(session.panelCount, 3)
        XCTAssertEqual(session.judgeItem?.modelID, "claude-opus")
        XCTAssertEqual(session.synthesisItem?.modelID, "gpt-5")
    }

    func test_stageParsing_handlesBareAndIndexedAndUnknown() throws {
        XCTAssertEqual(FusionStage.parse("panel"), .panel(index: 0))
        XCTAssertEqual(FusionStage.parse("panel[2]"), .panel(index: 2))
        XCTAssertEqual(FusionStage.parse("PANEL[7]"), .panel(index: 7))
        XCTAssertEqual(FusionStage.parse("judge"), .judge)
        XCTAssertEqual(FusionStage.parse("synthesis"), .synthesis)
        XCTAssertEqual(FusionStage.parse(nil), .unknown)
        XCTAssertEqual(FusionStage.parse(""), .unknown)
        XCTAssertEqual(FusionStage.parse("garbage"), .unknown)
    }

    // MARK: - Multiplier ("cost of certainty")

    func test_multiplier_isTotalOverSynthesisBaseline() throws {
        let session = try! XCTUnwrap(FusionSpendAggregator.newestSession(from: canonicalRun()))
        // synthesis baseline = 0.04, total = 0.33 → 8.25×
        XCTAssertEqual(session.soloBaselineCost, 0.04, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(session.costMultiplier), 8.25, accuracy: 1e-9)
    }

    func test_multiplier_fallsBackToJudge_whenNoSynthesis() throws {
        // Degraded run: synthesis failed, so no synthesis row. Baseline → judge.
        var rows = canonicalRun(parent: "elderwand-BBB")
        rows.removeLast() // drop synthesis
        let session = try! XCTUnwrap(FusionSpendAggregator.newestSession(from: rows))
        XCTAssertNil(session.synthesisItem)
        XCTAssertEqual(session.soloBaselineCost, 0.05, accuracy: 1e-9) // judge cost
        XCTAssertEqual(try XCTUnwrap(session.costMultiplier), 0.29 / 0.05, accuracy: 1e-9)
    }

    func test_multiplier_nilWhenNoPositiveBaseline() throws {
        let rows = [
            row(parent: "elderwand-CCC", stage: "panel[0]", model: "m", cost: 0.0),
            row(parent: "elderwand-CCC", stage: "judge", model: "m", cost: 0.0),
        ]
        let session = try! XCTUnwrap(FusionSpendAggregator.newestSession(from: rows))
        XCTAssertNil(session.costMultiplier, "No positive baseline → no multiplier (never divide by zero).")
    }

    // MARK: - Confidence rollup (honesty)

    func test_aggregateConfidence_collapsesToWeakest() throws {
        var rows = canonicalRun(parent: "elderwand-DDD")
        // One sub-call is a low-confidence estimate → whole session is an estimate.
        rows[2] = row(parent: "elderwand-DDD", stage: "panel[2]", model: "gemini-pro",
                      cost: 0.06, confidence: .lowConfidenceEstimate, at: 12)
        let session = try! XCTUnwrap(FusionSpendAggregator.newestSession(from: rows))
        XCTAssertEqual(session.aggregateConfidence, .lowConfidenceEstimate)
        XCTAssertFalse(session.aggregateConfidence.isExact)
    }

    func test_aggregateConfidence_exactWhenAllExact() throws {
        let session = try! XCTUnwrap(FusionSpendAggregator.newestSession(from: canonicalRun()))
        XCTAssertEqual(session.aggregateConfidence, .exact)
        XCTAssertTrue(session.aggregateConfidence.isExact)
    }

    // MARK: - newest / multi-run selection

    func test_newestSession_picksMostRecentRun() throws {
        let older = canonicalRun(parent: "elderwand-OLD") // ends at t=14
        let newer = [
            row(parent: "elderwand-NEW", stage: "panel[0]", model: "m", cost: 0.2, at: 100),
            row(parent: "elderwand-NEW", stage: "synthesis", model: "m", cost: 0.1, at: 101),
        ]
        let session = try! XCTUnwrap(FusionSpendAggregator.newestSession(from: older + newer))
        XCTAssertEqual(session.parentRequestID, "elderwand-NEW")
        XCTAssertEqual(session.totalCost, 0.30, accuracy: 1e-9)
    }

    func test_session_byExplicitParentID() throws {
        let rows = canonicalRun(parent: "elderwand-OLD") + [
            row(parent: "elderwand-NEW", stage: "synthesis", model: "m", cost: 0.1, at: 100),
        ]
        let session = FusionSpendAggregator.session(parentRequestID: "elderwand-OLD", from: rows)
        XCTAssertEqual(session?.parentRequestID, "elderwand-OLD")
        XCTAssertEqual(session?.lineItems.count, 5)
    }

    func test_newestSession_nilWhenNoFusionRows() throws {
        let rows = [
            row(parent: nil, stage: nil, model: "m", cost: 0.5),
            row(parent: "session-123", stage: nil, model: "m", cost: 0.3), // not elderwand- prefix
        ]
        XCTAssertNil(FusionSpendAggregator.newestSession(from: rows))
    }

    // MARK: - Fusion vs normal partition (the screen)

    func test_partition_separatesFusionFromNormalByPrefix() throws {
        let rows =
            canonicalRun(parent: "elderwand-R1") +              // fusion: 0.33
            canonicalRun(parent: "elderwand-R2") +              // fusion: 0.33
            [
                row(parent: nil, stage: nil, model: "claude", input: 100, output: 100, cost: 0.50),       // normal
                row(parent: "session-xyz", stage: nil, model: "gpt", input: 50, output: 50, cost: 0.20),  // normal (no prefix)
            ]
        let totals = FusionSpendAggregator.partition(rows)
        XCTAssertEqual(totals.fusionCost, 0.66, accuracy: 1e-9)
        XCTAssertEqual(totals.normalCost, 0.70, accuracy: 1e-9)
        XCTAssertEqual(totals.fusionRuns, 2, "Two distinct elderwand- parents = two runs.")
        XCTAssertEqual(totals.totalCost, 1.36, accuracy: 1e-9)
    }

    func test_partition_fusionShareAndAverage() throws {
        let rows = canonicalRun(parent: "elderwand-R1") + [
            row(parent: nil, stage: nil, model: "m", cost: 0.67),
        ]
        let totals = FusionSpendAggregator.partition(rows)
        // fusion 0.33 of total 1.00 = 0.33 share; 1 run → avg 0.33
        XCTAssertEqual(totals.fusionShareFraction, 0.33, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.averageCostPerFusionRun), 0.33, accuracy: 1e-9)
    }

    func test_partition_perModelContribution() throws {
        let totals = FusionSpendAggregator.partition(canonicalRun(parent: "elderwand-R1"))
        // claude-opus = panel[0] 0.10 + judge 0.05 = 0.15; gpt-5 = panel[1] 0.08 + synthesis 0.04 = 0.12
        XCTAssertEqual(totals.fusionCostByModel["claude-opus"] ?? 0, 0.15, accuracy: 1e-9)
        XCTAssertEqual(totals.fusionCostByModel["gpt-5"] ?? 0, 0.12, accuracy: 1e-9)
        XCTAssertEqual(totals.fusionCostByModel["gemini-pro"] ?? 0, 0.06, accuracy: 1e-9)
    }

    func test_partition_empty() throws {
        let totals = FusionSpendAggregator.partition([])
        XCTAssertEqual(totals.fusionCost, 0)
        XCTAssertEqual(totals.normalCost, 0)
        XCTAssertEqual(totals.fusionRuns, 0)
        XCTAssertEqual(totals.fusionShareFraction, 0, "No spend → zero share, not NaN.")
        XCTAssertNil(totals.averageCostPerFusionRun)
    }

    // MARK: - Single-panel + event projection

    func test_singlePanelRun() throws {
        let rows = [
            row(parent: "elderwand-SOLO", stage: "panel[0]", model: "m", cost: 0.10, at: 1),
            row(parent: "elderwand-SOLO", stage: "synthesis", model: "m", cost: 0.05, at: 2),
        ]
        let session = try! XCTUnwrap(FusionSpendAggregator.newestSession(from: rows))
        XCTAssertEqual(session.panelCount, 1)
        XCTAssertEqual(session.totalCost, 0.15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(session.costMultiplier), 3.0, accuracy: 1e-9) // 0.15 / 0.05
    }

    // MARK: - Wire contract (Codable round-trip, daemon → iOS over SSE)

    func test_session_codableRoundTrip_preservesEverything() throws {
        let original = try XCTUnwrap(FusionSpendAggregator.newestSession(from: canonicalRun()))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FusionSessionSpend.self, from: data)
        XCTAssertEqual(decoded, original, "Session must survive the daemon→iOS wire intact.")
        XCTAssertEqual(decoded.totalCost, original.totalCost, accuracy: 1e-9)
        XCTAssertEqual(decoded.lineItems.map(\.stage), original.lineItems.map(\.stage))
        XCTAssertEqual(decoded.costMultiplier, original.costMultiplier)
    }

    func test_stage_codableRoundTrip_panelIndexSurvives() throws {
        for stage: FusionStage in [.panel(index: 0), .panel(index: 7), .judge, .synthesis, .unknown] {
            let data = try JSONEncoder().encode(stage)
            XCTAssertEqual(try JSONDecoder().decode(FusionStage.self, from: data), stage)
        }
    }

    func test_wireKey_isStable() {
        XCTAssertEqual(FusionSessionSpend.wireKey, "openburnbar_fusion_spend")
    }

    func test_rowFromUsageEvent_carriesParentAndCost() throws {
        let event = BurnBarUsageEvent(
            runID: nil,
            providerID: "anthropic",
            modelID: "claude-opus",
            inputTokens: 100,
            outputTokens: 200,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            cost: 0.42,
            recordedAt: Date(timeIntervalSince1970: 5),
            sessionID: "s",
            projectName: nil,
            confidence: .exact,
            parentRequestID: "elderwand-EVT"
        )
        let projected = FusionUsageRow(event: event, stageLabel: "judge")
        XCTAssertTrue(projected.isFusion)
        XCTAssertEqual(projected.cost, 0.42, accuracy: 1e-9)
        XCTAssertEqual(projected.modelID, "claude-opus")
        XCTAssertEqual(FusionStage.parse(projected.stageLabel), .judge)
    }
}

import Foundation
import OpenBurnBarKernel
import XCTest

/// Behavioral contracts of the AI Inbox wire types.
///
/// These helpers drive real product decisions on every platform that renders
/// the inbox: `isAlert` decides which icon and section an item gets, `isOpen`
/// decides which list a row files under, and the egress mode helpers decide
/// whether a prompt is ever constructed. Pinning them here means a change is a
/// deliberate cross-platform decision instead of a silent drift.
final class AIInboxContractsBehaviorTests: XCTestCase {
    // MARK: - Kind classification

    func test_alertClassificationSeparatesNarrativeFromActionableKinds() {
        let narrativeKinds: Set<BurnBarInboxItemKind> = [.brief, .system]
        for kind in BurnBarInboxItemKind.allCases {
            XCTAssertEqual(
                kind.isAlert,
                narrativeKinds.contains(kind) == false,
                "\(kind.rawValue) is misclassified"
            )
        }
    }

    // MARK: - State lifecycle

    func test_openStatesAreExactlyNewAndUpdated() {
        XCTAssertTrue(BurnBarInboxItemState.new.isOpen)
        XCTAssertTrue(BurnBarInboxItemState.updated.isOpen)
        XCTAssertFalse(BurnBarInboxItemState.resolved.isOpen)
        XCTAssertFalse(BurnBarInboxItemState.expired.isOpen)
        XCTAssertEqual(BurnBarInboxItemState.openStates, [.new, .updated])
    }

    // MARK: - Synthesis presets

    func test_synthesisPresetsMapOntoFlashLunaAndPro() {
        XCTAssertEqual(BurnBarInboxSynthesisPreset.balanced.analystModel, "deepseek-v4-flash")
        XCTAssertEqual(BurnBarInboxSynthesisPreset.balanced.verifierModel, "gpt-5.6-luna")
        XCTAssertEqual(BurnBarInboxSynthesisPreset.balanced.maxVerifierCallsPerTick, 3)

        XCTAssertEqual(BurnBarInboxSynthesisPreset.fast.maxVerifierCallsPerTick, 0)
        XCTAssertEqual(BurnBarInboxSynthesisPreset.thorough.analystModel, "deepseek-v4-pro")
        XCTAssertEqual(BurnBarInboxSynthesisPreset.thorough.maxVerifierCallsPerTick, 6)

        let defaults = BurnBarInboxConfig()
        XCTAssertEqual(BurnBarInboxSynthesisPreset.matching(config: defaults), .balanced)

        let thorough = BurnBarInboxSynthesisPreset.thorough.applied(to: defaults)
        XCTAssertEqual(thorough.analystModel, "deepseek-v4-pro")
        XCTAssertEqual(thorough.maxVerifierCallsPerTick, 6)
        XCTAssertEqual(BurnBarInboxSynthesisPreset.matching(config: thorough), .thorough)

        let custom = BurnBarInboxConfig(maxVerifierCallsPerTick: 3, analystModel: "glm-5-turbo")
        XCTAssertNil(BurnBarInboxSynthesisPreset.matching(config: custom))
    }

    // MARK: - Egress modes

    func test_egressModesGateModelCallsAndCloudTravelIndependently() {
        XCTAssertFalse(BurnBarInboxEgressMode.off.allowsModelCalls)
        XCTAssertFalse(BurnBarInboxEgressMode.off.allowsCloudEgress)

        XCTAssertTrue(BurnBarInboxEgressMode.local.allowsModelCalls)
        XCTAssertFalse(
            BurnBarInboxEgressMode.local.allowsCloudEgress,
            "Local mode permits inference but never cloud travel"
        )

        XCTAssertTrue(BurnBarInboxEgressMode.cloud.allowsModelCalls)
        XCTAssertTrue(BurnBarInboxEgressMode.cloud.allowsCloudEgress)
    }

    // MARK: - Item detail

    func test_itemDetailIdentityComesFromItsSummary() {
        let detail = BurnBarInboxItemDetail(
            summary: Self.makeSummary(id: "inb_42"),
            summaryMarkdown: "**body**",
            payload: BurnBarInboxItemPayload(),
            tickID: "tick_9"
        )
        XCTAssertEqual(detail.id, "inb_42")
        XCTAssertEqual(detail.summaryMarkdown, "**body**")
        XCTAssertEqual(detail.tickID, "tick_9")
    }

    // MARK: - Get request / response

    func test_getRequestAndResponseRoundTripOverTheWire() throws {
        let request = BurnBarInboxGetRequest(id: "inb_7")
        XCTAssertEqual(request.id, "inb_7")
        let decodedRequest = try JSONDecoder().decode(
            BurnBarInboxGetRequest.self,
            from: try JSONEncoder().encode(request)
        )
        XCTAssertEqual(decodedRequest.id, "inb_7")

        let empty = BurnBarInboxGetResponse(item: nil)
        XCTAssertNil(empty.item)
        let populated = BurnBarInboxGetResponse(
            item: BurnBarInboxItemDetail(
                summary: Self.makeSummary(id: "inb_7"),
                summaryMarkdown: "body",
                payload: BurnBarInboxItemPayload(),
                tickID: "t"
            )
        )
        XCTAssertEqual(populated.item?.id, "inb_7")
    }

    // MARK: - Run telemetry

    func test_runTelemetryCarriesEveryCounterAndIdentifiesByTick() {
        let started = Date(timeIntervalSince1970: 1_754_300_000)
        let telemetry = BurnBarInboxRunTelemetry(
            tickID: "tick_full",
            startedAt: started,
            finishedAt: started.addingTimeInterval(3),
            gateResult: .remotePhase,
            egressMode: .cloud,
            llmCalls: 2,
            inputTokens: 1_000,
            outputTokens: 200,
            costUSD: 0.03,
            itemsNew: 1,
            itemsUpdated: 2,
            itemsResolved: 3,
            error: "partial"
        )

        XCTAssertEqual(telemetry.id, "tick_full", "Telemetry identity is the tick, so runs join to items")
        XCTAssertEqual(telemetry.gateResult, .remotePhase)
        XCTAssertEqual(telemetry.egressMode, .cloud)
        XCTAssertEqual(telemetry.llmCalls, 2)
        XCTAssertEqual(telemetry.inputTokens, 1_000)
        XCTAssertEqual(telemetry.outputTokens, 200)
        XCTAssertEqual(telemetry.costUSD, 0.03, accuracy: 0.000_1)
        XCTAssertEqual(telemetry.itemsNew, 1)
        XCTAssertEqual(telemetry.itemsUpdated, 2)
        XCTAssertEqual(telemetry.itemsResolved, 3)
        XCTAssertEqual(telemetry.error, "partial")
    }

    func test_runTelemetryDefaultsDescribeAnUntouchedTick() {
        let telemetry = BurnBarInboxRunTelemetry(
            tickID: "tick_skip",
            startedAt: Date(),
            gateResult: .skippedUnchanged,
            egressMode: .off
        )
        XCTAssertNil(telemetry.finishedAt)
        XCTAssertEqual(telemetry.llmCalls, 0)
        XCTAssertEqual(telemetry.costUSD, 0)
        XCTAssertEqual(telemetry.itemsNew, 0)
        XCTAssertNil(telemetry.error)
    }

    // MARK: - Runs response

    func test_runsResponseDefaultsToAZeroBudgetView() {
        let empty = BurnBarInboxRunsResponse(runs: [])
        XCTAssertTrue(empty.runs.isEmpty)
        XCTAssertEqual(empty.todaySpendUSD, 0)
        XCTAssertEqual(empty.dailyBudgetUSD, 0)

        let telemetry = BurnBarInboxRunTelemetry(
            tickID: "t", startedAt: Date(), gateResult: .forced, egressMode: .cloud
        )
        let populated = BurnBarInboxRunsResponse(runs: [telemetry], todaySpendUSD: 0.42, dailyBudgetUSD: 1.5)
        XCTAssertEqual(populated.runs.count, 1)
        XCTAssertEqual(populated.todaySpendUSD, 0.42, accuracy: 0.000_1)
        XCTAssertEqual(populated.dailyBudgetUSD, 1.5, accuracy: 0.000_1)
    }

    // MARK: - Run-now request / response

    func test_runNowRequestDefaultsToRespectingTheGate() {
        XCTAssertFalse(BurnBarInboxRunNowRequest().force, "Only the explicit button bypasses the gate")
        XCTAssertTrue(BurnBarInboxRunNowRequest(force: true).force)
    }

    func test_runNowResponseCarriesTheRefusalReason() {
        let accepted = BurnBarInboxRunNowResponse(tickID: "tick_1", accepted: true)
        XCTAssertEqual(accepted.tickID, "tick_1")
        XCTAssertTrue(accepted.accepted)
        XCTAssertNil(accepted.reason)

        let refused = BurnBarInboxRunNowResponse(tickID: nil, accepted: false, reason: "The inbox is disabled.")
        XCTAssertNil(refused.tickID)
        XCTAssertFalse(refused.accepted)
        XCTAssertEqual(refused.reason, "The inbox is disabled.")
    }

    // MARK: - Fixtures

    private static func makeSummary(id: String) -> BurnBarInboxItemSummary {
        BurnBarInboxItemSummary(
            id: id,
            fingerprint: "ci_waste:test",
            kind: .ciWaste,
            priority: .p2,
            state: .new,
            title: "title",
            firstSeenAt: Date(timeIntervalSince1970: 1_754_300_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_754_303_600)
        )
    }
}

import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Regression coverage for the mobile verdict session-trace pipeline:
/// `InsightsMobileVerdictModel.buildTraceFor` was an empty stub, so iOS/iPad
/// verdicts never carried the `sessionTrace` strip that the shared
/// `VerdictHeroView` already renders (Mac parity gap). These tests drive the
/// real composer pipeline with an in-memory cache and a fake data source.
@MainActor
final class InsightsMobileVerdictModelTests: XCTestCase {

    private struct FakeDataSource: InsightDataSource {
        var sessions: [InsightSessionRow]
        var usages: [InsightUsageRow]

        func snapshot(window: DateInterval) async throws -> InsightDataSnapshot {
            InsightDataSnapshot(window: window, usages: usages, sessions: sessions)
        }
    }

    private func makeSession(now: Date) -> InsightSessionRow {
        InsightSessionRow(
            sessionID: "session-1",
            provider: "claude",
            projectName: "BurnBar",
            startTime: now.addingTimeInterval(-1_800),
            endTime: now.addingTimeInterval(-60),
            messageCount: 12,
            inferredTaskTitle: "Fix the popover",
            keyTools: ["Edit"],
            keyCommands: ["swift build"],
            keyFiles: []
        )
    }

    private func makeUsage(now: Date) -> InsightUsageRow {
        InsightUsageRow(
            sessionID: "session-1",
            provider: "claude",
            model: "claude-sonnet",
            projectName: "BurnBar",
            startTime: now.addingTimeInterval(-1_800),
            endTime: now.addingTimeInterval(-60),
            inputTokens: 1_000,
            outputTokens: 500,
            totalTokens: 1_500,
            costUSD: 1.25
        )
    }

    private func makeModel(dataSource: FakeDataSource) -> InsightsMobileVerdictModel {
        InsightsMobileVerdictModel(
            deviceID: "test-device",
            window: .today,
            dataSource: dataSource,
            digestBuilder: InsightDigestBuilder(),
            cache: VerdictCache(storage: .memoryOnly)
        )
    }

    private func waitForUpgradedVerdict(
        _ model: InsightsMobileVerdictModel,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let verdict = model.verdict, !model.isDemo, verdict.isRuleBased {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for a rule-based verdict upgrade")
    }

    func testRuleBasedUpgrade_attachesSessionTrace() async throws {
        let now = Date()
        let model = makeModel(
            dataSource: FakeDataSource(sessions: [makeSession(now: now)], usages: [makeUsage(now: now)])
        )

        model.refresh()
        try await waitForUpgradedVerdict(model)

        // `buildTraceFor` attaches the strip asynchronously after the
        // upgrade event lands.
        let deadline = Date().addingTimeInterval(10)
        while model.verdict?.sessionTrace == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let trace = try XCTUnwrap(model.verdict?.sessionTrace, "Upgraded mobile verdicts must carry the session-trace strip (Mac parity)")
        XCTAssertEqual(trace.sessionID, "session-1")
        XCTAssertEqual(trace.summary, "Fix the popover")
        XCTAssertEqual(trace.costUSD, 1.25, accuracy: 0.0001)
    }

    func testRuleBasedUpgrade_withoutSessions_leavesVerdictWithoutTrace() async throws {
        let model = makeModel(dataSource: FakeDataSource(sessions: [], usages: []))

        model.refresh()
        try await waitForUpgradedVerdict(model)

        // Give the async trace task a moment; with no sessions the builder
        // returns nil and the verdict must stay strip-free (not crash or
        // clobber the verdict).
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(model.verdict?.sessionTrace)
        XCTAssertNotNil(model.verdict)
    }
}

import XCTest
@testable import OpenBurnBarCore

final class CastleStatusTests: XCTestCase {
    func testPythonNoOpStatusDecodesWithoutGreenwashing() throws {
        let json = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-06-16T03:12:09Z",
          "runtime": "gemini",
          "house": "House Gemini",
          "modelArg": "gemini-3.1-pro-preview",
          "phase": "no_op",
          "landsCommit": false,
          "baseSHA": "1111111",
          "headSHA": "1111111",
          "resultPath": "/tmp/result.json",
          "donePath": "/tmp/result.done",
          "honesty": ["quota_unknown", "no_op"]
        }
        """

        let worker = try JSONDecoder().decode(CastleWorkerStatus.self, from: Data(json.utf8))

        XCTAssertEqual(worker.runtime, "gemini")
        XCTAssertEqual(worker.phase, .noOp)
        XCTAssertFalse(worker.landsCommit)
        XCTAssertEqual(worker.houseModel.provider, .geminiCLI)
        XCTAssertEqual(worker.honesty, [.quotaUnknown, .noOp])
        XCTAssertNotNil(worker.updatedAt)
    }

    func testLandedCommitForcesLandedPhaseFromCompletedWrapperState() throws {
        let json = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-06-16T03:12:09.123Z",
          "runtime": "claude",
          "modelArg": "claude-opus-4-8",
          "phase": "completed",
          "landsCommit": true,
          "baseSHA": "1111111",
          "headSHA": "2222222",
          "honesty": ["quota_unknown"]
        }
        """

        let worker = try JSONDecoder().decode(CastleWorkerStatus.self, from: Data(json.utf8))

        XCTAssertEqual(worker.phase, .landed)
        XCTAssertTrue(worker.landsCommit)
        XCTAssertEqual(worker.houseModel.provider, .claudeCode)
    }

    func testSnapshotCountsOnlyRealLandedCommits() {
        let snapshot = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .completed, landsCommit: true),
            CastleWorkerStatus(runtime: "gemini", modelArg: "gemini-3.1-pro-preview", phase: .noOp, landsCommit: false, honesty: [.noOp]),
            CastleWorkerStatus(runtime: "cursor-agent", modelArg: "cursor-fast", phase: .failed, landsCommit: false, honesty: [.failed])
        ])

        XCTAssertEqual(snapshot.totalCount, 3)
        XCTAssertEqual(snapshot.landedCount, 1)
        XCTAssertEqual(snapshot.noOpCount, 1)
        XCTAssertEqual(snapshot.failedCount, 1)
        XCTAssertEqual(snapshot.headline, "1 of 3 banners raised")
    }

    func testSwitcherRegistryIncludesCastleRuntimeProfiles() {
        XCTAssertTrue(SwitcherCLIProfileType.allCases.contains(.gemini))
        XCTAssertTrue(SwitcherCLIProfileType.allCases.contains(.kimi))
        XCTAssertTrue(SwitcherCLIProfileType.allCases.contains(.pi))
        XCTAssertEqual(SwitcherCLIProfileType.gemini.canonicalAgentProvider, .geminiCLI)
        XCTAssertEqual(SwitcherCLIProfileType.kimi.canonicalAgentProvider, .kimi)
        XCTAssertEqual(SwitcherCLIProfileType.pi.canonicalAgentProvider, .piAgent)
    }
}

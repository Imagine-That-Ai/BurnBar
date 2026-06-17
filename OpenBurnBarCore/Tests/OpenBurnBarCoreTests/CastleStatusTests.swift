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

    // MARK: - Wand label tests

    func testWandLabelsUsePlainLanguage() {
        XCTAssertEqual(CastleWorkerPhase.landed.wandLabel, "Work landed")
        XCTAssertEqual(CastleWorkerPhase.noOp.wandLabel, "No work landed")
        XCTAssertEqual(CastleWorkerPhase.failed.wandLabel, "Failed")
        XCTAssertEqual(CastleWorkerPhase.running.wandLabel, "Running")
    }

    // MARK: - No-op worker is never counted as landed

    func testNoOpWorkerNeverCountsAsLanded() {
        let noOpOnly = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "gemini", modelArg: "gemini-3.1", phase: .noOp, landsCommit: false, honesty: [.noOp])
        ])
        XCTAssertEqual(noOpOnly.totalCount, 1)
        XCTAssertEqual(noOpOnly.landedCount, 0)
        XCTAssertEqual(noOpOnly.noOpCount, 1)

        // Even if a no-op worker somehow had landsCommit true (defensive),
        // the phase init guard forces .landed, so landedCount tracks it.
        let defensiveNoOp = CastleWorkerStatus(
            runtime: "gemini",
            modelArg: "gemini-3.1",
            phase: .noOp,
            landsCommit: true
        )
        XCTAssertEqual(defensiveNoOp.phase, .landed)
        XCTAssertTrue(defensiveNoOp.landsCommit)
    }

    func testAllFailedSnapshotHasZeroLanded() {
        let snapshot = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .failed, landsCommit: false, honesty: [.failed]),
            CastleWorkerStatus(runtime: "claude", modelArg: "claude-4", phase: .failed, landsCommit: false, honesty: [.failed])
        ])
        XCTAssertEqual(snapshot.totalCount, 2)
        XCTAssertEqual(snapshot.landedCount, 0)
        XCTAssertEqual(snapshot.failedCount, 2)
    }

    // MARK: - Wand fan-out cap ladder

    func testWandFanOutCapLadder() {
        XCTAssertEqual(WandFanOut.maxParallel(for: .none), 1)
        XCTAssertEqual(WandFanOut.maxParallel(for: .cloud), 3)
        XCTAssertEqual(WandFanOut.maxParallel(for: .pro), 8)
        XCTAssertEqual(WandFanOut.maxParallel(for: .ultra), 16)
    }

    func testWandFanOutMinimumTierForWidth() {
        XCTAssertEqual(WandFanOut.minimumTier(forParallel: 1), .none)
        XCTAssertEqual(WandFanOut.minimumTier(forParallel: 2), .cloud)
        XCTAssertEqual(WandFanOut.minimumTier(forParallel: 3), .cloud)
        XCTAssertEqual(WandFanOut.minimumTier(forParallel: 4), .pro)
        XCTAssertEqual(WandFanOut.minimumTier(forParallel: 8), .pro)
        XCTAssertEqual(WandFanOut.minimumTier(forParallel: 9), .ultra)
        XCTAssertEqual(WandFanOut.minimumTier(forParallel: 16), .ultra)
    }

    // MARK: - Partial success, all-failed, and provider-unavailable state tests

    func testPartialSuccessDetection() {
        let partial = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .landed, landsCommit: true, headSHA: "abc123"),
            CastleWorkerStatus(runtime: "claude", modelArg: "claude-4", phase: .failed, landsCommit: false, honesty: [.failed]),
            CastleWorkerStatus(runtime: "gemini", modelArg: "gemini-3.1", phase: .noOp, landsCommit: false, honesty: [.noOp])
        ])
        XCTAssertTrue(partial.isPartialSuccess)
        XCTAssertFalse(partial.isAllFailed)
        XCTAssertEqual(partial.landedCount, 1)
        XCTAssertEqual(partial.failedCount, 1)
        XCTAssertEqual(partial.noOpCount, 1)
    }

    func testAllFailedDetection() {
        let allFailed = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .failed, landsCommit: false, honesty: [.failed]),
            CastleWorkerStatus(runtime: "claude", modelArg: "claude-4", phase: .failed, landsCommit: false, honesty: [.failed])
        ])
        XCTAssertTrue(allFailed.isAllFailed)
        XCTAssertFalse(allFailed.isPartialSuccess)
        XCTAssertEqual(allFailed.landedCount, 0)
        XCTAssertEqual(allFailed.failedCount, 2)
    }

    func testFullSuccessIsNotPartial() {
        let full = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .landed, landsCommit: true, headSHA: "abc123"),
            CastleWorkerStatus(runtime: "claude", modelArg: "claude-4", phase: .landed, landsCommit: true, headSHA: "def456")
        ])
        XCTAssertFalse(full.isPartialSuccess)
        XCTAssertFalse(full.isAllFailed)
        XCTAssertEqual(full.landedCount, 2)
    }

    func testQuotaUncertaintyDetection() {
        let withUnknown = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .completed, landsCommit: false, honesty: [.quotaUnknown])
        ])
        XCTAssertTrue(withUnknown.hasQuotaUncertainty)

        let withPressure = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .running, landsCommit: false, honesty: [.quotaPressure])
        ])
        XCTAssertTrue(withPressure.hasQuotaUncertainty)

        let clean = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .landed, landsCommit: true, headSHA: "abc123")
        ])
        XCTAssertFalse(clean.hasQuotaUncertainty)
    }

    func testProviderUnavailableDetection() {
        let withDemoted = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .demoted, landsCommit: false, honesty: [.routeDemoted])
        ])
        XCTAssertTrue(withDemoted.hasProviderUnavailable)

        let clean = CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .landed, landsCommit: true, headSHA: "abc123")
        ])
        XCTAssertFalse(clean.hasProviderUnavailable)
    }

    // MARK: - CastleHonestyFlag wand labels

    func testHonestyFlagDisplayLabelsAreUserFriendly() {
        XCTAssertEqual(CastleHonestyFlag.quotaUnknown.displayLabel, "Quota unknown")
        XCTAssertEqual(CastleHonestyFlag.routeDemoted.displayLabel, "Route demoted")
        XCTAssertEqual(CastleHonestyFlag.noOp.displayLabel, "No commit landed")
        XCTAssertEqual(CastleHonestyFlag.quotaPressure.displayLabel, "Quota pressure")
        XCTAssertEqual(CastleHonestyFlag.failed.displayLabel, "Failed")
    }

    // MARK: - CloudTier displayName tests

    func testCloudTierDisplayNames() {
        XCTAssertEqual(CloudTier.none.displayName, "")
        XCTAssertEqual(CloudTier.cloud.displayName, "Cloud")
        XCTAssertEqual(CloudTier.pro.displayName, "Cloud Pro")
        XCTAssertEqual(CloudTier.ultra.displayName, "Cloud Ultra")
    }

    func testCloudTierSatisfies() {
        XCTAssertTrue(CloudTier.ultra.satisfies(.cloud))
        XCTAssertTrue(CloudTier.ultra.satisfies(.pro))
        XCTAssertTrue(CloudTier.ultra.satisfies(.ultra))
        XCTAssertTrue(CloudTier.pro.satisfies(.cloud))
        XCTAssertFalse(CloudTier.cloud.satisfies(.pro))
        XCTAssertFalse(CloudTier.none.satisfies(.cloud))
    }
}

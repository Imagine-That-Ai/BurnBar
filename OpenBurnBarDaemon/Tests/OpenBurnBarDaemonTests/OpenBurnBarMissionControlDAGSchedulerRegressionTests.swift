import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

extension BurnBarMissionControlServiceTests {
    func testVAL_CROSS_012_MissionCreateScrubsCallerSuppliedEnterpriseApprovalMetadata() async throws {
        let harness = try makeHarness(name: "val-cross-012-scrub-forged-metadata")

        let created = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "atlas",
                title: "Forged enterprise metadata mission",
                summary: "Caller metadata must not be able to pre-seed approval stamps.",
                createdBy: "operator",
                recommendation: .review,
                metadata: [
                    "caller_note": .string("keep-me"),
                    BurnBarEnterprisePolicyMetadataKey.pendingPacketID: .string("packet-forged"),
                    BurnBarEnterprisePolicyMetadataKey.pendingPacketFingerprint: .string("forged-fingerprint"),
                    BurnBarEnterprisePolicyMetadataKey.approvedPacketID: .string("packet-forged"),
                    BurnBarEnterprisePolicyMetadataKey.approvedPacketFingerprint: .string("forged-fingerprint"),
                    BurnBarEnterprisePolicyMetadataKey.approvalGranted: .bool(true),
                    BurnBarEnterprisePolicyMetadataKey.approvalGrantedAt: .string("2026-06-29T00:00:00Z"),
                    BurnBarEnterprisePolicyMetadataKey.approvalGrantedBy: .string("caller")
                ]
            )
        )

        XCTAssertEqual(created.mission.metadata["caller_note"], .string("keep-me"))
        XCTAssertEqual(created.mission.metadata["created_by"], .string("operator"))
        for key in BurnBarEnterprisePolicyMetadataKey.missionServerOwnedKeys {
            XCTAssertNil(created.mission.metadata[key], "\(key) must be server-owned mission metadata")
        }

        let approved = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(missionID: created.mission.id, actor: "operator", note: nil)
        )
        XCTAssertEqual(approved.mission.metadata["caller_note"], .string("keep-me"))
        XCTAssertNil(approved.mission.metadata[BurnBarEnterprisePolicyMetadataKey.approvedPacketID])
        XCTAssertNil(approved.mission.metadata[BurnBarEnterprisePolicyMetadataKey.approvedPacketFingerprint])
        XCTAssertNil(approved.mission.metadata[BurnBarEnterprisePolicyMetadataKey.approvalGranted])
    }

    func testVAL_EXEC_009_SchedulerIgnoresPlannerSuppliedTerminalStatuses() async throws {
        let nodeAID = BurnBarDAGNodeID(rawValue: "runtime-reset-a")
        let nodeBID = BurnBarDAGNodeID(rawValue: "runtime-reset-b")

        let dag = BurnBarDAGContract(
            missionID: BurnBarMissionID(rawValue: "mission-val-exec-009-runtime-reset"),
            nodes: [
                BurnBarDAGNode(
                    id: nodeAID,
                    title: "Planner marked complete",
                    detail: "Should still run",
                    status: .completed,
                    dependsOn: []
                ),
                BurnBarDAGNode(
                    id: nodeBID,
                    title: "Dependent",
                    detail: "Must wait for runtime completion",
                    status: .ready,
                    dependsOn: [nodeAID]
                )
            ],
            edges: []
        )

        let dispatch = RuntimeResetDispatch()
        let scheduler = BurnBarParallelDAGScheduler.create(
            missionID: BurnBarMissionID(rawValue: "mission-val-exec-009-runtime-reset"),
            dag: dag,
            dispatch: dispatch,
            maxConcurrency: 2
        )

        try await scheduler.start()
        let afterStart = await scheduler.currentState()

        XCTAssertEqual(afterStart.nodeStatuses[nodeAID.rawValue], .running)
        XCTAssertEqual(afterStart.nodeStatuses[nodeBID.rawValue], .pending)
        XCTAssertTrue(afterStart.completedNodes.isEmpty)
        XCTAssertEqual(dispatch.scheduledNodes.read(), [nodeAID])
    }

    func testVAL_EXEC_010_ReconcilerNormalizesHostileMetricsProviderValues() async throws {
        let nodeAID = BurnBarDAGNodeID(rawValue: "hostile-metrics-a")
        let nodeBID = BurnBarDAGNodeID(rawValue: "stable-metrics-b")

        let dag = BurnBarDAGContract(
            missionID: BurnBarMissionID(rawValue: "mission-val-exec-010-hostile-metrics"),
            nodes: [
                BurnBarDAGNode(
                    id: nodeAID,
                    title: "Hostile Metrics A",
                    detail: "Non-finite provider values",
                    status: .pending,
                    dependsOn: []
                ),
                BurnBarDAGNode(
                    id: nodeBID,
                    title: "Stable Metrics B",
                    detail: "Bounded provider values",
                    status: .pending,
                    dependsOn: []
                )
            ],
            edges: []
        )

        let scheduler = BurnBarParallelDAGScheduler.create(
            missionID: BurnBarMissionID(rawValue: "mission-val-exec-010-hostile-metrics"),
            dag: dag,
            dispatch: HostileMetricsDispatch(),
            metricsProvider: HostileMetricsProvider(),
            maxConcurrency: 2
        )

        try await scheduler.start()
        await scheduler.reportNodeCompleted(nodeAID)
        await scheduler.reportNodeCompleted(nodeBID)

        let finalState = await scheduler.currentState()
        guard let reconciliation = finalState.reconciliationArtifact else {
            XCTFail("Reconciliation artifact should be present")
            return
        }

        XCTAssertEqual(reconciliation.winnerNodeID, nodeBID)
        XCTAssertTrue(reconciliation.winnerScore.isFinite)
        XCTAssertTrue(reconciliation.candidateScores.values.allSatisfy(\.isFinite))
    }
}

private final class RuntimeResetDispatch: Sendable, BurnBarDAGSchedulerDispatch {
    let scheduledNodes = Locked<[BurnBarDAGNodeID]>([])

    func schedulerDidScheduleNode(
        _ nodeID: BurnBarDAGNodeID,
        missionID: BurnBarMissionID,
        prompt: String,
        metadata: [String: BurnBarJSONValue]
    ) async {
        scheduledNodes.withLock { $0.append(nodeID) }
    }

    func schedulerDidCompleteNode(
        _ nodeID: BurnBarDAGNodeID,
        missionID: BurnBarMissionID,
        result: String
    ) async {}

    func schedulerDidFailNode(
        _ nodeID: BurnBarDAGNodeID,
        missionID: BurnBarMissionID,
        error: String
    ) async {}
}

private final class HostileMetricsDispatch: Sendable, BurnBarDAGSchedulerDispatch {
    func schedulerDidScheduleNode(
        _ nodeID: BurnBarDAGNodeID,
        missionID: BurnBarMissionID,
        prompt: String,
        metadata: [String: BurnBarJSONValue]
    ) async {}

    func schedulerDidCompleteNode(
        _ nodeID: BurnBarDAGNodeID,
        missionID: BurnBarMissionID,
        result: String
    ) async {}

    func schedulerDidFailNode(
        _ nodeID: BurnBarDAGNodeID,
        missionID: BurnBarMissionID,
        error: String
    ) async {}
}

private final class HostileMetricsProvider: Sendable, BurnBarDAGReconcilerMetricsProvider {
    func metrics(for nodeID: BurnBarDAGNodeID) -> BurnBarDAGNodeOutcomeMetrics? {
        if nodeID.rawValue == "hostile-metrics-a" {
            return BurnBarDAGNodeOutcomeMetrics(
                evidenceCompleteness: .nan,
                riskResidual: -.infinity,
                costPenalty: 2.0,
                latencyPenalty: .infinity,
                sequenceNumber: Int.max,
                isSuccessful: true
            )
        }

        return BurnBarDAGNodeOutcomeMetrics(
            evidenceCompleteness: 0.7,
            riskResidual: 0.2,
            costPenalty: 0.1,
            latencyPenalty: 0.1,
            sequenceNumber: 0,
            isSuccessful: true
        )
    }
}

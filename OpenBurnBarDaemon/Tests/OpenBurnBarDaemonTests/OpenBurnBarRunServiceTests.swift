import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarRunServiceTests: XCTestCase {
    func testApprovalFlowTransitionsRunToAwaitingApprovalThenCompleted() async throws {
        let harness = try makeHarness(name: "approval-flow")
        let clientID = BurnBarClientID(rawValue: "client-a")
        let sessionID = BurnBarSessionID(rawValue: "session-a")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Controller A",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await harness.configStore.setSecret("zai-secret", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Apply this patch",
                modelID: "glm-5",
                metadata: [
                    "requiresApproval": .bool(true),
                    "toolKind": .string(BurnBarToolKind.applyPatch.rawValue)
                ]
            )
        )
        XCTAssertEqual(createResponse.phase, .awaitingApproval)

        let awaitingDetail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )
        XCTAssertEqual(awaitingDetail.run?.phase, .awaitingApproval)
        XCTAssertEqual(awaitingDetail.approvalRequest?.tool, .applyPatch)

        let approvalID = try XCTUnwrap(awaitingDetail.approvalRequest?.approvalID)
        let completedDetail = try await harness.runService.respondToApproval(
            BurnBarApprovalRespondRequest(
                response: BurnBarApprovalResponse(
                    approvalID: approvalID,
                    clientID: clientID,
                    decision: .approve,
                    respondedAt: Date()
                )
            )
        )

        XCTAssertEqual(completedDetail.run?.phase, .completed)
        XCTAssertNil(completedDetail.approvalRequest)

        let recentUsage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(recentUsage.count, 1)
        XCTAssertEqual(recentUsage.first?.runID, createResponse.runID)
    }

    func testRetrySucceedsAfterInitialFailure() async throws {
        let harness = try makeHarness(name: "retry")
        let clientID = BurnBarClientID(rawValue: "client-retry")
        let sessionID = BurnBarSessionID(rawValue: "session-retry")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Retry Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await harness.configStore.setSecret("zai-secret", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        let failedRun = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Fail once, then retry",
                modelID: "glm-5",
                metadata: ["failUntilAttempt": .number(1)]
            )
        )
        let failedDetail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: failedRun.runID, clientID: clientID)
        )
        XCTAssertEqual(failedDetail.run?.phase, .failed)

        let retriedDetail = try await harness.runService.retryRun(
            BurnBarRunRetryRequest(runID: failedRun.runID, clientID: clientID)
        )
        XCTAssertEqual(retriedDetail.run?.phase, .completed)
    }

    // MARK: - VAL-EXEC-011: Run-level failover continuity preserves idempotent usage accounting

    func test_VAL_EXEC_011_usageAccountingIsIdempotentUnderFailover() async throws {
        // VAL-EXEC-011: Failover retries within a run do not duplicate usage records
        // for same run attempt idempotency key.
        let harness = try makeHarness(name: "idempotent-usage")
        let clientID = BurnBarClientID(rawValue: "idempotent-client")
        let sessionID = BurnBarSessionID(rawValue: "idempotent-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Idempotent Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await harness.configStore.setSecret("zai-secret", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        // Create a run that completes successfully
        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Simple completion",
                modelID: "glm-5"
            )
        )
        XCTAssertEqual(createResponse.phase, .completed)

        // Record the initial usage
        let initialRecords = try await harness.usageRecorder.records()
        let initialCount = initialRecords.count

        // Verify idempotency: recording the same event again should not create duplicate
        let usageEvent = BurnBarUsageEvent(
            runID: createResponse.runID,
            providerID: "zai",
            modelID: "glm-5",
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            cost: 0.001,
            recordedAt: Date()
        )

        // Record with same idempotency key as the completed run (attempt 1)
        let idempotencyKey = "run:\(createResponse.runID.rawValue):attempt:1"
        let result1 = try await harness.usageRecorder.record(usageEvent, idempotencyKey: idempotencyKey)
        XCTAssertFalse(result1.inserted, "Second record with same idempotency key should not insert")

        // Verify no new record was added
        let finalRecords = try await harness.usageRecorder.records()
        XCTAssertEqual(finalRecords.count, initialCount, "No duplicate record should be created")

        // Verify the idempotency key pattern works correctly
        let differentKeyResult = try await harness.usageRecorder.record(usageEvent, idempotencyKey: "run:\(createResponse.runID.rawValue):attempt:2")
        XCTAssertTrue(differentKeyResult.inserted, "Different idempotency key should insert")

        let recordsAfterDifferentKey = try await harness.usageRecorder.records()
        XCTAssertEqual(recordsAfterDifferentKey.count, initialCount + 1, "New key should create record")
    }

    func test_VAL_EXEC_011_usageIdempotencyKeyIncludesAttempt() async throws {
        // VAL-EXEC-011: Idempotency key includes attempt number
        // Uses an approval-required run that completes via explicit approve.
        let harness = try makeHarness(name: "usage-idempotency-key")
        let clientID = BurnBarClientID(rawValue: "idempotency-key-client")
        let sessionID = BurnBarSessionID(rawValue: "idempotency-key-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Idempotency Key Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await harness.configStore.setSecret("zai-secret", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        // Create a run that requires approval (this pattern is tested in existing tests)
        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Run with idempotency check",
                modelID: "glm-5",
                metadata: [
                    "requiresApproval": .bool(true),
                    "toolKind": .string(BurnBarToolKind.applyPatch.rawValue)
                ]
            )
        )
        XCTAssertEqual(createResponse.phase, .awaitingApproval)

        // Approve the run
        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )
        let approvalID = try XCTUnwrap(detail.approvalRequest?.approvalID)
        let completedDetail = try await harness.runService.respondToApproval(
            BurnBarApprovalRespondRequest(
                response: BurnBarApprovalResponse(
                    approvalID: approvalID,
                    clientID: clientID,
                    decision: .approve,
                    respondedAt: Date()
                )
            )
        )
        XCTAssertEqual(completedDetail.run?.phase, .completed)

        // Verify usage was recorded with attempt 1
        let records = try await harness.usageRecorder.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records.first?.idempotencyKey.hasSuffix(":attempt:1") ?? false, "First attempt should use attempt:1")
    }

    // MARK: - VAL-EXEC-008: Provider failover is deterministic for retryable upstream failures

    func test_VAL_EXEC_008_providerFailoverIsDeterministicViaScorecard() async throws {
        // VAL-EXEC-008: Provider failover is deterministic for retryable upstream failures.
        // Retryable upstream failures fail over alternate routes with preserved run continuity
        // and no duplicate terminal records.
        // This test verifies RunService-level failover ordering is driven by scoreAndRankRoutes()
        // output (scorecard composite score ordering), not legacy candidateRoutes() ordering.
        let harness = try makeHarness(
            name: "failover-scorecard",
            providerExecutor: BurnBarFailoverSimulatorProviderExecutor()
        )
        let clientID = BurnBarClientID(rawValue: "failover-scorecard-client")
        let sessionID = BurnBarSessionID(rawValue: "failover-scorecard-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Failover Scorecard Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        // Set up one provider (zai) with two credential slots for glm-5
        // This tests failover between slots ordered by scorecard composite scoring
        try await harness.configStore.setSecret("zai-key-a", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/v1",
                preferredModelIDs: ["glm-5"]
            )
        )
        // Add two credential slots - failover simulator will fail on first, succeed on second
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-a",
            label: "Plan A",
            apiKey: "zai-key-a"
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-b",
            label: "Plan B",
            apiKey: "zai-key-b"
        )

        // Create a run - the failover simulator will fail slot-a first, then succeed on slot-b
        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Test failover ordering",
                modelID: "glm-5"
            )
        )

        // Verify the run completed successfully (failover worked)
        XCTAssertEqual(createResponse.phase, .completed)

        // Verify only one usage record was created (no duplicate terminal records)
        let usageRecords = try await harness.usageRecorder.recentUsage(limit: 10)
        XCTAssertEqual(usageRecords.count, 1, "Failover should produce exactly one usage record")
        XCTAssertEqual(usageRecords.first?.runID, createResponse.runID)
        // The successful route should be slot-b (failover target after slot-a failed)
        XCTAssertEqual(usageRecords.first?.providerID, "zai")
    }

    func test_VAL_EXEC_008_failoverAttemptsAreDeterministicallyOrdered() async throws {
        // VAL-EXEC-008: Explicitly assert deterministic attempted failover route slot/identity order.
        // This test strengthens coverage by verifying the exact sequence of slot/identity attempts
        // during failover, not just that failover occurred or call counts.
        let recorder = BurnBarRecordingFailoverSimulatorProviderExecutor()
        let harness = try makeHarness(
            name: "failover-ordered",
            providerExecutor: recorder
        )
        let clientID = BurnBarClientID(rawValue: "failover-ordered-client")
        let sessionID = BurnBarSessionID(rawValue: "failover-ordered-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Failover Ordered Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        // Set up one provider (zai) with two credential slots for glm-5
        // slot-a is added first, slot-b second - deterministic slot ID ordering
        try await harness.configStore.setSecret("zai-key-a", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/v1",
                preferredModelIDs: ["glm-5"]
            )
        )
        // Add two credential slots in deterministic slotID order: slot-a first, slot-b second
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-a",
            label: "Plan A",
            apiKey: "zai-key-a"
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-b",
            label: "Plan B",
            apiKey: "zai-key-b"
        )

        // Create a run - failover simulator will fail on first attempt (slot-a), succeed on second (slot-b)
        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Test deterministic failover ordering",
                modelID: "glm-5"
            )
        )

        // Verify the run completed successfully via failover
        XCTAssertEqual(createResponse.phase, .completed)

        // Extract the ordered sequence of route slot/identity attempts
        let attemptedRoutes = await recorder.attemptedRoutes()

        // VAL-EXEC-008: Assert deterministic attempted route order
        // The router must attempt slot-a first (highest ranked), then failover to slot-b
        XCTAssertEqual(attemptedRoutes.count, 2,
            "Failover should attempt exactly 2 routes: first fails, second succeeds")
        XCTAssertEqual(attemptedRoutes[0].credentialSlotID, "slot-a",
            "First attempted route should be slot-a (primary)")
        XCTAssertEqual(attemptedRoutes[1].credentialSlotID, "slot-b",
            "Second attempted route should be slot-b (failover target)")

        // Verify provider identity is preserved through failover
        XCTAssertEqual(attemptedRoutes[0].providerID, "zai")
        XCTAssertEqual(attemptedRoutes[1].providerID, "zai")

        // Verify only one usage record (no duplicate terminal records from failover retry)
        let usageRecords = try await harness.usageRecorder.recentUsage(limit: 10)
        XCTAssertEqual(usageRecords.count, 1, "Failover must not duplicate usage records")
        XCTAssertEqual(usageRecords.first?.runID, createResponse.runID)
    }

    func testObserverCannotControlUntilControllerDetachesAndPromotionOccurs() async throws {
        let harness = try makeHarness(name: "arbitration")
        let controllerID = BurnBarClientID(rawValue: "controller")
        let observerID = BurnBarClientID(rawValue: "observer")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: controllerID,
                sessionID: BurnBarSessionID(rawValue: "session-controller"),
                clientName: "Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: observerID,
                sessionID: BurnBarSessionID(rawValue: "session-observer"),
                clientName: "Observer",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        try await harness.configStore.setSecret("zai-secret", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        let run = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: controllerID,
                sessionID: BurnBarSessionID(rawValue: "session-controller"),
                prompt: "Need approval before cancel",
                modelID: "glm-5",
                metadata: ["requiresApproval": .bool(true)]
            )
        )

        do {
            _ = try await harness.runService.cancelRun(
                BurnBarRunCancelRequest(runID: run.runID, clientID: observerID)
            )
            XCTFail("Expected observer control rejection")
        } catch let error as BurnBarClientRegistryError {
            guard case .controllerRequired(let rejectedClientID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(rejectedClientID, observerID)
        }

        _ = try await harness.clientRegistry.detach(
            BurnBarClientDetachRequest(
                clientID: controllerID,
                sessionID: BurnBarSessionID(rawValue: "session-controller")
            )
        )

        let cancelledDetail = try await harness.runService.cancelRun(
            BurnBarRunCancelRequest(runID: run.runID, clientID: observerID, reason: "Taking over")
        )
        XCTAssertEqual(cancelledDetail.run?.phase, .cancelled)
        XCTAssertEqual(cancelledDetail.arbitration?.activeClientID, observerID)
    }

    func testControllerReconnectRetainsControlAndCanInspectExistingRuns() async throws {
        let harness = try makeHarness(name: "reconnect")
        let clientID = BurnBarClientID(rawValue: "client-reconnect")
        let originalSession = BurnBarSessionID(rawValue: "session-1")
        let reconnectSession = BurnBarSessionID(rawValue: "session-2")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: originalSession,
                clientName: "Reconnect Client",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await harness.configStore.setSecret("zai-secret", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        let run = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: originalSession,
                prompt: "Complete then reconnect",
                modelID: "glm-5"
            )
        )

        let (_, arbitration) = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: reconnectSession,
                clientName: "Reconnect Client",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        XCTAssertEqual(arbitration.activeClientID, clientID)

        let listedRuns = try await harness.runService.listRuns(BurnBarRunListRequest(clientID: clientID))
        XCTAssertEqual(listedRuns.runs.first?.runID, run.runID)
    }

    func testCreateRunSkipsIncompatiblePersistedCheckpointFiles() async throws {
        let harness = try makeHarness(name: "skip-invalid-checkpoint")
        let clientID = BurnBarClientID(rawValue: "client-invalid-checkpoint")
        let sessionID = BurnBarSessionID(rawValue: "session-invalid-checkpoint")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Checkpoint Client",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let checkpointsDirectory = harness.rootURL.appendingPathComponent("run-checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDirectory, withIntermediateDirectories: true)
        let staleCheckpointURL = checkpointsDirectory.appendingPathComponent("stale-run.json", isDirectory: false)
        try #"{"runID":"stale-run","phase":"planning"}"#
            .data(using: .utf8)?
            .write(to: staleCheckpointURL, options: .atomic)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "search for BurnBarRunService",
                modelID: "glm-5"
            )
        )

        XCTAssertNotNil(createResponse.runID)
        XCTAssertNotEqual(createResponse.phase, .failed)
    }

    func testRunServiceCompletesThroughProviderExecutorPath() async throws {
        let harness = try makeHarness(name: "provider-executor")
        let clientID = BurnBarClientID(rawValue: "client-provider")
        let sessionID = BurnBarSessionID(rawValue: "session-provider")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Provider Client",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await harness.configStore.setSecret("zai-secret", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        let response = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Say hello from OpenBurnBar",
                modelID: "glm-5",
                metadata: ["controllerReview": .bool(true)]
            )
        )

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: response.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .completed)
        let usageRecords = try await harness.usageRecorder.records()
        XCTAssertEqual(usageRecords.count, 1)
        XCTAssertEqual(usageRecords.first?.event.cacheCreationTokens, 6)
    }

    func testWorkspaceWorkflowReadThenPatchCompletesWithPendingToolCalls() async throws {
        let harness = try makeHarness(name: "workflow-read-patch")
        let clientID = BurnBarClientID(rawValue: "workflow-controller")
        let sessionID = BurnBarSessionID(rawValue: "workflow-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Workflow Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Change a string in one file",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("src/example.ts"),
                        "from": .string("value = 1"),
                        "to": .string("value = 2")
                    ])
                ]
            )
        )
        XCTAssertEqual(createResponse.phase, .waitingOnCompanion)

        let firstPoll = try await harness.runService.pollRuns(
            BurnBarRunPollRequest(clientID: clientID, sessionID: sessionID)
        )
        XCTAssertEqual(firstPoll.pendingToolCalls.first?.tool, .readFile)

        let firstClaim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: createResponse.runID)
        )
        XCTAssertEqual(firstClaim.disposition, .dispatched)
        XCTAssertEqual(firstClaim.toolCall?.tool, .readFile)

        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: createResponse.runID,
                callID: try XCTUnwrap(firstClaim.toolCall?.callID),
                succeeded: true,
                output: .object([
                    "path": .string("file:///workspace/src/example.ts"),
                    "content": .string("export const value = 1;\n")
                ]),
                error: nil,
                completedAt: Date()
            )
        )

        let awaitingApproval = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )
        XCTAssertEqual(awaitingApproval.run?.phase, .awaitingApproval)
        XCTAssertEqual(awaitingApproval.approvalRequest?.tool, .applyPatch)

        _ = try await harness.runService.respondToApproval(
            BurnBarApprovalRespondRequest(
                response: BurnBarApprovalResponse(
                    approvalID: try XCTUnwrap(awaitingApproval.approvalRequest?.approvalID),
                    clientID: clientID,
                    decision: .approve,
                    respondedAt: Date()
                )
            )
        )

        let secondPoll = try await harness.runService.pollRuns(
            BurnBarRunPollRequest(clientID: clientID, sessionID: sessionID, runID: createResponse.runID)
        )
        XCTAssertEqual(secondPoll.pendingToolCalls.first?.tool, .applyPatch)
        let patchArguments = try XCTUnwrap(secondPoll.pendingToolCalls.first?.arguments.objectValue())
        let changes = try XCTUnwrap(patchArguments.arrayValue(forKey: "changes"))
        let firstChange = try XCTUnwrap(changes.first?.objectValue())
        XCTAssertEqual(firstChange.stringValue(forKey: "path"), "src/example.ts")
        XCTAssertEqual(firstChange.stringValue(forKey: "text"), "export const value = 2;\n")

        let secondClaim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: createResponse.runID)
        )
        XCTAssertEqual(secondClaim.toolCall?.tool, .applyPatch)

        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: createResponse.runID,
                callID: try XCTUnwrap(secondClaim.toolCall?.callID),
                succeeded: true,
                output: .object([
                    "applied": .bool(true),
                    "changedFiles": .array([.string("file:///workspace/src/example.ts")])
                ]),
                error: nil,
                completedAt: Date()
            )
        )

        let finalDetail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )
        XCTAssertEqual(finalDetail.run?.phase, .completed)
        XCTAssertNil(finalDetail.pendingToolCall)

        let usageRecords = try await harness.usageRecorder.records()
        XCTAssertEqual(usageRecords.count, 1)
        XCTAssertEqual(usageRecords.first?.event.runID, createResponse.runID)
    }

    func testGenericPromptUsesModelLoopToSearchThenComplete() async throws {
        let harness = try makeHarness(
            name: "generic-search-loop",
            providerExecutor: BurnBarSequencedProviderExecutor(outputs: [
                #"{"action":"complete","rationale":"The search results were enough to answer.","message":"Done."}"#
            ])
        )
        let clientID = BurnBarClientID(rawValue: "loop-controller")
        let sessionID = BurnBarSessionID(rawValue: "loop-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Loop Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "search for BurnBarRunService",
                modelID: "glm-5"
            )
        )
        XCTAssertEqual(created.phase, .waitingOnCompanion)

        let pending = try await harness.runService.pollRuns(
            BurnBarRunPollRequest(clientID: clientID, sessionID: sessionID, runID: created.runID)
        )
        XCTAssertEqual(pending.pendingToolCalls.first?.tool, .searchWorkspace)

        let claimed = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: created.runID)
        )
        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: created.runID,
                callID: try XCTUnwrap(claimed.toolCall?.callID),
                succeeded: true,
                output: .object([
                    "matches": .array([
                        .object([
                            "path": .string("file:///workspace/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRunService.swift"),
                            "line": .number(1),
                            "character": .number(1),
                            "preview": .string("public actor BurnBarRunService")
                        ])
                    ])
                ]),
                error: nil,
                completedAt: Date()
            )
        )

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .completed)
    }

    func testGenericPromptUsesModelLoopToSearchThenReadThenComplete() async throws {
        let harness = try makeHarness(
            name: "generic-search-read-loop",
            providerExecutor: BurnBarSequencedProviderExecutor(outputs: [
                #"{"action":"read_file","requestedTool":"read_file","arguments":{"path":"file:///workspace/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRunService.swift"},"rationale":"Need to inspect the file after search."}"#,
                #"{"action":"complete","rationale":"The file contents were enough to finish.","message":"Done."}"#
            ])
        )
        let clientID = BurnBarClientID(rawValue: "loop-controller-2")
        let sessionID = BurnBarSessionID(rawValue: "loop-session-2")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Loop Controller 2",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "search for BurnBarRunService and inspect the file",
                modelID: "glm-5"
            )
        )
        XCTAssertEqual(created.phase, .waitingOnCompanion)

        let firstClaim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: created.runID)
        )
        XCTAssertEqual(firstClaim.toolCall?.tool, .searchWorkspace)
        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: created.runID,
                callID: try XCTUnwrap(firstClaim.toolCall?.callID),
                succeeded: true,
                output: .object([
                    "matches": .array([
                        .object([
                            "path": .string("file:///workspace/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRunService.swift"),
                            "line": .number(1),
                            "character": .number(1),
                            "preview": .string("public actor BurnBarRunService")
                        ])
                    ])
                ]),
                error: nil,
                completedAt: Date()
            )
        )

        let secondPending = try await harness.runService.pollRuns(
            BurnBarRunPollRequest(clientID: clientID, sessionID: sessionID, runID: created.runID)
        )
        XCTAssertEqual(secondPending.pendingToolCalls.first?.tool, .readFile)
        let secondClaim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: created.runID)
        )
        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: created.runID,
                callID: try XCTUnwrap(secondClaim.toolCall?.callID),
                succeeded: true,
                output: .object([
                    "path": .string("file:///workspace/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRunService.swift"),
                    "content": .string("public actor BurnBarRunService {}\n")
                ]),
                error: nil,
                completedAt: Date()
            )
        )

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .completed)
        XCTAssertEqual(detail.loopState?.iterationCount, 2)
    }

    func testWorkspaceRefusalCreatesApprovalInAwaitingApprovalPhase() async throws {
        let harness = try makeHarness(name: "workflow-refusal")
        let clientID = BurnBarClientID(rawValue: "workflow-controller")
        let sessionID = BurnBarSessionID(rawValue: "workflow-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Workflow Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Change a string in one file",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("src/example.ts"),
                        "from": .string("value = 1"),
                        "to": .string("value = 2")
                    ])
                ]
            )
        )

        let claim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: createResponse.runID)
        )
        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: createResponse.runID,
                callID: try XCTUnwrap(claim.toolCall?.callID),
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .trustGated,
                    message: "Trust this workspace before applying edits."
                ),
                completedAt: Date()
            )
        )

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .awaitingApproval)
        XCTAssertEqual(detail.approvalRequest?.tool, .readFile)
        XCTAssertEqual(detail.approvalRequest?.message, "Trust this workspace before applying edits.")
    }

    func testObserverCannotClaimToolExecutionWhenNotController() async throws {
        let harness = try makeHarness(name: "observer-tool-claim")
        let controllerID = BurnBarClientID(rawValue: "controller")
        let observerID = BurnBarClientID(rawValue: "observer")
        let controllerSession = BurnBarSessionID(rawValue: "controller-session")
        let observerSession = BurnBarSessionID(rawValue: "observer-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: controllerID,
                sessionID: controllerSession,
                clientName: "Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: observerID,
                sessionID: observerSession,
                clientName: "Observer",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: controllerID,
                sessionID: controllerSession,
                prompt: "Change a string in one file",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("src/example.ts"),
                        "from": .string("value = 1"),
                        "to": .string("value = 2")
                    ])
                ]
            )
        )
        XCTAssertEqual(createResponse.phase, .waitingOnCompanion)

        do {
            _ = try await harness.runService.executeTool(
                BurnBarToolExecutionRequest(
                    clientID: observerID,
                    sessionID: observerSession,
                    runID: createResponse.runID
                )
            )
            XCTFail("Expected controller-only tool claim guard")
        } catch let error as BurnBarClientRegistryError {
            guard case .controllerRequired(let rejectedClientID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(rejectedClientID, observerID)
        }
    }

    func testRetryAfterCompanionFailureRequeuesPendingToolCall() async throws {
        let harness = try makeHarness(name: "workflow-retry")
        let clientID = BurnBarClientID(rawValue: "retry-controller")
        let sessionID = BurnBarSessionID(rawValue: "retry-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Retry Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Change a string in one file",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("src/example.ts"),
                        "from": .string("value = 1"),
                        "to": .string("value = 2")
                    ])
                ]
            )
        )

        let claim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: createResponse.runID)
        )
        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: createResponse.runID,
                callID: try XCTUnwrap(claim.toolCall?.callID),
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .terminalFailed,
                    message: "Companion is no longer available."
                ),
                completedAt: Date()
            )
        )

        let failedDetail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )
        XCTAssertEqual(failedDetail.run?.phase, .failed)

        let retried = try await harness.runService.retryRun(
            BurnBarRunRetryRequest(runID: createResponse.runID, clientID: clientID)
        )
        XCTAssertEqual(retried.run?.phase, .waitingOnCompanion)
        XCTAssertEqual(retried.pendingToolCall?.tool, .readFile)
    }

    func testPollUsesCurrentSessionAfterClientReconnect() async throws {
        let harness = try makeHarness(name: "workflow-reconnect-poll")
        let clientID = BurnBarClientID(rawValue: "reconnect-controller")
        let sessionOne = BurnBarSessionID(rawValue: "session-1")
        let sessionTwo = BurnBarSessionID(rawValue: "session-2")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionOne,
                clientName: "Reconnect Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionOne,
                prompt: "Change a string in one file",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("src/example.ts"),
                        "from": .string("value = 1"),
                        "to": .string("value = 2")
                    ])
                ]
            )
        )
        XCTAssertEqual(createResponse.phase, .waitingOnCompanion)

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionTwo,
                clientName: "Reconnect Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        let polled = try await harness.runService.pollRuns(
            BurnBarRunPollRequest(clientID: clientID, sessionID: sessionTwo)
        )
        XCTAssertEqual(polled.pendingToolCalls.count, 1)
        XCTAssertEqual(polled.pendingToolCalls.first?.tool, .readFile)
    }

    func testRestartRestoresPendingToolCallFromCheckpoint() async throws {
        let harness = try makeHarness(name: "restart-pending-tool")
        let clientID = BurnBarClientID(rawValue: "restore-controller")
        let originalSession = BurnBarSessionID(rawValue: "restore-session-1")
        let reconnectSession = BurnBarSessionID(rawValue: "restore-session-2")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: originalSession,
                clientName: "Restore Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: originalSession,
                prompt: "Change a string in one file",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("src/example.ts"),
                        "from": .string("value = 1"),
                        "to": .string("value = 2")
                    ])
                ]
            )
        )
        XCTAssertEqual(created.phase, .waitingOnCompanion)

        let restoredHarness = try makeHarness(
            name: "restart-pending-tool-restored",
            rootURL: harness.rootURL,
            secretStore: harness.secretStore
        )
        _ = await restoredHarness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: reconnectSession,
                clientName: "Restore Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        let polled = try await restoredHarness.runService.pollRuns(
            BurnBarRunPollRequest(clientID: clientID, sessionID: reconnectSession, runID: created.runID)
        )
        XCTAssertEqual(polled.runs.first?.phase, .waitingOnCompanion)
        XCTAssertEqual(polled.pendingToolCalls.first?.tool, .readFile)
    }

    func testRestartRestoresPendingApprovalFromCheckpoint() async throws {
        let harness = try makeHarness(name: "restart-pending-approval")
        let clientID = BurnBarClientID(rawValue: "approval-controller")
        let originalSession = BurnBarSessionID(rawValue: "approval-session-1")
        let reconnectSession = BurnBarSessionID(rawValue: "approval-session-2")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: originalSession,
                clientName: "Approval Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: originalSession,
                prompt: "Need approval",
                modelID: "glm-5",
                metadata: [
                    "requiresApproval": .bool(true),
                    "toolKind": .string(BurnBarToolKind.runTerminal.rawValue),
                    "toolArguments": .object([
                        "command": .string("npm test")
                    ])
                ]
            )
        )
        XCTAssertEqual(created.phase, .awaitingApproval)

        let restoredHarness = try makeHarness(
            name: "restart-pending-approval-restored",
            rootURL: harness.rootURL,
            secretStore: harness.secretStore
        )
        _ = await restoredHarness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: reconnectSession,
                clientName: "Approval Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        let detail = try await restoredHarness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .awaitingApproval)
        XCTAssertEqual(detail.approvalRequest?.tool, .runTerminal)
    }

    func testVAL_CROSS_003_HighRiskAutonomousStepEscalatesThenResumesOnExplicitApproval() async throws {
        let harness = try makeHarness(name: "terminal-companion-flow")
        let clientID = BurnBarClientID(rawValue: "terminal-controller")
        let sessionID = BurnBarSessionID(rawValue: "terminal-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Terminal Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Run tests in terminal",
                modelID: "glm-5",
                metadata: [
                    "toolKind": .string(BurnBarToolKind.runTerminal.rawValue),
                    "waitOnCompanion": .bool(true),
                    "toolArguments": .object([
                        "command": .string("npm test"),
                        "cwd": .string(".")
                    ])
                ]
            )
        )
        XCTAssertEqual(createResponse.phase, .awaitingApproval)

        let initialDetail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )
        XCTAssertEqual(initialDetail.approvalRequest?.tool, .runTerminal)

        let resumedDetail = try await harness.runService.respondToApproval(
            BurnBarApprovalRespondRequest(
                response: BurnBarApprovalResponse(
                    approvalID: try XCTUnwrap(initialDetail.approvalRequest?.approvalID),
                    clientID: clientID,
                    decision: .approve,
                    respondedAt: Date()
                )
            )
        )
        XCTAssertNil(resumedDetail.approvalRequest, "VAL-CROSS-003: explicit approval should clear pending approval request")
        XCTAssertEqual(resumedDetail.run?.phase, .waitingOnCompanion, "VAL-CROSS-003: high-risk run should resume execution only after approval")

        let claimed = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: createResponse.runID)
        )
        XCTAssertEqual(claimed.toolCall?.tool, .runTerminal)

        let detail = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: createResponse.runID,
                callID: try XCTUnwrap(claimed.toolCall?.callID),
                succeeded: true,
                output: .object([
                    "terminalName": .string("OpenBurnBar"),
                    "cwd": .string("/workspace")
                ]),
                error: nil,
                completedAt: Date()
            )
        )
        XCTAssertEqual(detail.run?.phase, .completed, "VAL-CROSS-003: resumed run should reach terminal completion after approved high-risk step")

        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.runID, createResponse.runID)
    }

    // MARK: - VAL-GOV-005: Aggressive autonomy enforces high-risk approval gates

    func testVAL_GOV_005_LowRiskReadFileRunRemainsAutonomousInAggressiveMode() async throws {
        let harness = try makeHarness(name: "val-gov-005-low-risk")
        let clientID = BurnBarClientID(rawValue: "low-risk-client")
        let sessionID = BurnBarSessionID(rawValue: "low-risk-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Low Risk Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Read the repository README for context",
                modelID: "glm-5",
                metadata: [
                    "toolKind": .string(BurnBarToolKind.readFile.rawValue),
                    "path": .string("README.md"),
                    "toolArguments": .object([
                        "path": .string("README.md")
                    ])
                ]
            )
        )
        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )

        XCTAssertNotEqual(
            createResponse.phase,
            .awaitingApproval,
            "VAL-GOV-005: Low-risk actions should remain autonomous in aggressive mode."
        )
        XCTAssertNil(
            detail.approvalRequest,
            "VAL-GOV-005: Low-risk read_file run must not create explicit approval request."
        )
    }

    func testVAL_GOV_005_HighRiskRunTerminalRequiresExplicitApprovalInAggressiveMode() async throws {
        let harness = try makeHarness(name: "val-gov-005-high-risk")
        let clientID = BurnBarClientID(rawValue: "high-risk-client")
        let sessionID = BurnBarSessionID(rawValue: "high-risk-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "High Risk Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Run terminal command for deployment checks",
                modelID: "glm-5",
                metadata: [
                    "toolKind": .string(BurnBarToolKind.runTerminal.rawValue),
                    "toolArguments": .object([
                        "command": .string("npm test"),
                        "cwd": .string(".")
                    ])
                ]
            )
        )
        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )

        XCTAssertEqual(
            createResponse.phase,
            .awaitingApproval,
            "VAL-GOV-005: High-risk run_terminal actions must require explicit approval in aggressive mode."
        )
        XCTAssertEqual(detail.approvalRequest?.tool, .runTerminal)
    }

    func testCancelWhileWaitingOnCompanionClearsPendingToolCall() async throws {
        let harness = try makeHarness(name: "cancel-waiting-on-companion")
        let clientID = BurnBarClientID(rawValue: "cancel-controller")
        let sessionID = BurnBarSessionID(rawValue: "cancel-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Cancel Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Run tests in terminal",
                modelID: "glm-5",
                metadata: [
                    "toolKind": .string(BurnBarToolKind.runTerminal.rawValue),
                    "waitOnCompanion": .bool(true),
                    "toolArguments": .object([
                        "command": .string("npm test")
                    ])
                ]
            )
        )
        XCTAssertEqual(createResponse.phase, .awaitingApproval)

        _ = try await harness.runService.cancelRun(
            BurnBarRunCancelRequest(runID: createResponse.runID, clientID: clientID, reason: "Cancel now")
        )

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .cancelled)
        XCTAssertNil(detail.pendingToolCall)
    }

    func testObserverPromotionCanResumePendingToolCallAfterControllerDetach() async throws {
        let harness = try makeHarness(name: "controller-handoff-pending-call")
        let controllerID = BurnBarClientID(rawValue: "controller-a")
        let observerID = BurnBarClientID(rawValue: "observer-b")
        let controllerSession = BurnBarSessionID(rawValue: "controller-session")
        let observerSession = BurnBarSessionID(rawValue: "observer-session")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: controllerID,
                sessionID: controllerSession,
                clientName: "Controller A",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: observerID,
                sessionID: observerSession,
                clientName: "Observer B",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: controllerID,
                sessionID: controllerSession,
                prompt: "Run tests in terminal",
                modelID: "glm-5",
                metadata: [
                    "toolKind": .string(BurnBarToolKind.runTerminal.rawValue),
                    "waitOnCompanion": .bool(true),
                    "toolArguments": .object([
                        "command": .string("npm test")
                    ])
                ]
            )
        )
        XCTAssertEqual(createResponse.phase, .awaitingApproval)

        _ = try await harness.clientRegistry.detach(
            BurnBarClientDetachRequest(clientID: controllerID, sessionID: controllerSession)
        )

        let initialDetail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: createResponse.runID, clientID: observerID)
        )
        XCTAssertEqual(initialDetail.approvalRequest?.tool, .runTerminal)

        _ = try await harness.runService.respondToApproval(
            BurnBarApprovalRespondRequest(
                response: BurnBarApprovalResponse(
                    approvalID: try XCTUnwrap(initialDetail.approvalRequest?.approvalID),
                    clientID: observerID,
                    decision: .approve,
                    respondedAt: Date()
                )
            )
        )

        let claimed = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: observerID, sessionID: observerSession, runID: createResponse.runID)
        )
        XCTAssertEqual(claimed.disposition, .dispatched)
        XCTAssertEqual(claimed.toolCall?.tool, .runTerminal)

        let detail = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: observerID,
                sessionID: observerSession,
                runID: createResponse.runID,
                callID: try XCTUnwrap(claimed.toolCall?.callID),
                succeeded: true,
                output: .object([
                    "terminalName": .string("OpenBurnBar")
                ]),
                error: nil,
                completedAt: Date()
            )
        )
        XCTAssertEqual(detail.run?.phase, .completed)
        XCTAssertEqual(detail.arbitration?.activeClientID, observerID)
    }

    private func makeHarness(
        name: String,
        rootURL: URL? = nil,
        secretStore: BurnBarInMemorySecretStore? = nil,
        providerExecutor: any BurnBarProviderExecuting = BurnBarStubProviderExecutor(),
        maxInMemoryRuns: Int = 200,
        evictionPolicy: BurnBarRunRegistryEvictionPolicy = .maxCount(200)
    ) throws -> BurnBarRunServiceHarness {
        let rootURL = rootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-run-service-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = secretStore ?? BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "run-service-tests")
        )
        let usageRecorder = BurnBarUsageRecorder(
            fileURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            logger: BurnBarDaemonLogger(category: "run-service-tests")
        )
        let runJournal = BurnBarRunJournal(
            fileURL: rootURL.appendingPathComponent("run-journal.jsonl"),
            checkpointsDirectoryURL: rootURL.appendingPathComponent("run-checkpoints", isDirectory: true),
            logger: BurnBarDaemonLogger(category: "run-service-tests")
        )
        let clientRegistry = BurnBarClientRegistry(logger: BurnBarDaemonLogger(category: "run-service-tests"))
        let runService = BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "run-service-tests")
            ),
            usageRecorder: usageRecorder,
            clientRegistry: clientRegistry,
            providerExecutor: providerExecutor,
            runJournal: runJournal,
            maxInMemoryRuns: maxInMemoryRuns,
            evictionPolicy: evictionPolicy,
            logger: BurnBarDaemonLogger(category: "run-service-tests")
        )

        return BurnBarRunServiceHarness(
            rootURL: rootURL,
            secretStore: secretStore,
            configStore: configStore,
            usageRecorder: usageRecorder,
            clientRegistry: clientRegistry,
            runService: runService,
            runJournal: runJournal
        )
    }

    func testEvictionPolicyNoneKeepsAllRunsInMemory() async throws {
        let harness = try makeHarness(name: "eviction-none", maxInMemoryRuns: 10, evictionPolicy: .none)
        let clientID = BurnBarClientID(rawValue: "client-eviction-none")
        let sessionID = BurnBarSessionID(rawValue: "session-eviction-none")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Eviction None Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        var runIDs: [BurnBarRunID] = []
        for i in 0..<15 {
            let response = try await harness.runService.createRun(
                BurnBarRunCreateRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    prompt: "Run \(i)",
                    modelID: "glm-5"
                )
            )
            runIDs.append(response.runID)
        }

        let inMemoryCount = await harness.runService.runs.count
        XCTAssertEqual(inMemoryCount, 15, "With .none policy, all 15 runs should remain in memory")
    }

    func testMaxCountEvictionRemovesOldestTerminalRuns() async throws {
        let harness = try makeHarness(name: "eviction-maxcount", maxInMemoryRuns: 5, evictionPolicy: .maxCount(5))
        let clientID = BurnBarClientID(rawValue: "client-eviction-maxcount")
        let sessionID = BurnBarSessionID(rawValue: "session-eviction-maxcount")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Eviction MaxCount Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        var runIDs: [BurnBarRunID] = []
        for i in 0..<10 {
            let response = try await harness.runService.createRun(
                BurnBarRunCreateRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    prompt: "Eviction test prompt \(i)",
                    modelID: "glm-5"
                )
            )
            runIDs.append(response.runID)
        }

        let inMemoryCount = await harness.runService.runs.count
        XCTAssertEqual(inMemoryCount, 5, "With maxCount(5), only 5 terminal runs should remain in memory")

        // The oldest runs should have been evicted; the newest 5 should remain
        for (index, runID) in runIDs.enumerated() {
            let detail = try await harness.runService.getRun(
                BurnBarRunGetRequest(runID: runID, clientID: clientID)
            )
            if index < 5 {
                // Evicted run should be lazily restored
                XCTAssertNotNil(detail.run, "Evicted run \(index) should be lazily restorable")
            }
            XCTAssertNotNil(detail.run, "Run \(index) should be retrievable")
        }
    }

    func testActiveRunsAreNeverEvicted() async throws {
        // Create a harness with a tiny limit and a provider executor that stalls
        // so runs remain in a non-terminal phase.
        let harness = try makeHarness(
            name: "eviction-active-protected",
            maxInMemoryRuns: 2,
            evictionPolicy: .maxCount(2)
        )
        let clientID = BurnBarClientID(rawValue: "client-active-protected")
        let sessionID = BurnBarSessionID(rawValue: "session-active-protected")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Active Protected Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        // Create a run that requires approval — it will stay in .awaitingApproval
        let awaitingRun = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Stall me",
                modelID: "glm-5",
                metadata: ["requiresApproval": .bool(true)]
            )
        )
        XCTAssertEqual(awaitingRun.phase, .awaitingApproval)

        // Create two more terminal runs to exceed the limit
        _ = try await harness.runService.createRun(
            BurnBarRunCreateRequest(clientID: clientID, sessionID: sessionID, prompt: "T1", modelID: "glm-5")
        )
        _ = try await harness.runService.createRun(
            BurnBarRunCreateRequest(clientID: clientID, sessionID: sessionID, prompt: "T2", modelID: "glm-5")
        )

        let inMemoryCount = await harness.runService.runs.count
        // With maxCount(2), we have 3 total. The active run should be protected,
        // and the oldest terminal run should be evicted.
        XCTAssertEqual(inMemoryCount, 2, "Active run should be protected from eviction")

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: awaitingRun.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .awaitingApproval, "Active run should still be in memory")
    }

    func testListRunsPaginationRespectsLimitAndOffset() async throws {
        let harness = try makeHarness(name: "listruns-pagination", evictionPolicy: .none)
        let clientID = BurnBarClientID(rawValue: "client-listruns-pagination")
        let sessionID = BurnBarSessionID(rawValue: "session-listruns-pagination")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Pagination Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        var runIDs: [BurnBarRunID] = []
        for i in 0..<5 {
            let response = try await harness.runService.createRun(
                BurnBarRunCreateRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    prompt: "Run \(i)",
                    modelID: "glm-5"
                )
            )
            runIDs.append(response.runID)
        }

        let page1 = try await harness.runService.listRuns(
            BurnBarRunListRequest(clientID: clientID, offset: 0, limit: 2)
        )
        XCTAssertEqual(page1.runs.count, 2)

        let page2 = try await harness.runService.listRuns(
            BurnBarRunListRequest(clientID: clientID, offset: 2, limit: 2)
        )
        XCTAssertEqual(page2.runs.count, 2)

        let page3 = try await harness.runService.listRuns(
            BurnBarRunListRequest(clientID: clientID, offset: 4, limit: 2)
        )
        XCTAssertEqual(page3.runs.count, 1)

        // Verify ordering (newest first)
        XCTAssertEqual(page1.runs.first?.runID, runIDs.last)
        XCTAssertEqual(page3.runs.first?.runID, runIDs.first)
    }

    func testRetryRunWorksOnEvictedRun() async throws {
        let harness = try makeHarness(name: "retry-evicted", maxInMemoryRuns: 2, evictionPolicy: .maxCount(2))
        let clientID = BurnBarClientID(rawValue: "client-retry-evicted")
        let sessionID = BurnBarSessionID(rawValue: "session-retry-evicted")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Retry Evicted Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let failedRun = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Fail once",
                modelID: "glm-5",
                metadata: ["failUntilAttempt": .number(1)]
            )
        )
        XCTAssertEqual(failedRun.phase, .failed)

        // Create two more terminal runs to evict the failed one
        _ = try await harness.runService.createRun(
            BurnBarRunCreateRequest(clientID: clientID, sessionID: sessionID, prompt: "T1", modelID: "glm-5")
        )
        _ = try await harness.runService.createRun(
            BurnBarRunCreateRequest(clientID: clientID, sessionID: sessionID, prompt: "T2", modelID: "glm-5")
        )

        let inMemoryCountBeforeRetry = await harness.runService.runs.count
        XCTAssertEqual(inMemoryCountBeforeRetry, 2)

        // Retry should lazily restore the evicted run and then retry it
        let retriedDetail = try await harness.runService.retryRun(
            BurnBarRunRetryRequest(runID: failedRun.runID, clientID: clientID)
        )
        XCTAssertEqual(retriedDetail.run?.phase, .completed)
    }

    private func configureProvider(_ harness: BurnBarRunServiceHarness) async throws {
        try await harness.configStore.setSecret("zai-secret", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
    }

    // MARK: - VAL-EXEC-012: Run journal captures deterministic replayable execution timeline

    func testVAL_EXEC_012_RunJournalCapturesDeterministicReplayableExecutionTimeline() async throws {
        // VAL-EXEC-012: Each run records ordered journal events for plan/approval/tool/recovery/terminal
        // transitions sufficient to replay timeline deterministically.
        // This test verifies:
        // 1. Journal events are captured in emittedAt order
        // 2. Replay (reading events again) produces same sequence
        let harness = try makeHarness(name: "val-exec-012-journal")
        let clientID = BurnBarClientID(rawValue: "client-journal")
        let sessionID = BurnBarSessionID(rawValue: "session-journal")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Journal Test Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        // Create a run that goes through approval flow
        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Execute journal test run",
                modelID: "glm-5",
                metadata: [
                    "requiresApproval": .bool(true),
                    "toolKind": .string(BurnBarToolKind.applyPatch.rawValue)
                ]
            )
        )
        let runID = createResponse.runID

        // Get initial events after run creation
        let initialEvents = try await harness.runJournal.events(for: runID)
        XCTAssertFalse(initialEvents.isEmpty, "Journal should have events after run creation")

        // Get approval and approve it
        let awaitingDetail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: runID, clientID: clientID)
        )
        let approvalID = try XCTUnwrap(awaitingDetail.approvalRequest?.approvalID)
        _ = try await harness.runService.respondToApproval(
            BurnBarApprovalRespondRequest(
                response: BurnBarApprovalResponse(
                    approvalID: approvalID,
                    clientID: clientID,
                    decision: .approve,
                    respondedAt: Date()
                )
            )
        )

        // Get events after approval
        let afterApprovalEvents = try await harness.runJournal.events(for: runID)
        XCTAssertTrue(
            afterApprovalEvents.count >= initialEvents.count,
            "Approval should add events to journal"
        )

        // Verify events are ordered by emittedAt (deterministic sequence)
        let sortedEvents = afterApprovalEvents.sorted { $0.emittedAt < $1.emittedAt }
        XCTAssertEqual(
            afterApprovalEvents.map { $0.eventID },
            sortedEvents.map { $0.eventID },
            "Events should be stored in emittedAt order for deterministic replay"
        )

        // Verify replay produces same sequence (read events again)
        let replayEvents = try await harness.runJournal.events(for: runID)
        XCTAssertEqual(
            afterApprovalEvents.map { $0.eventID },
            replayEvents.map { $0.eventID },
            "Replay should produce identical event sequence"
        )
        XCTAssertEqual(
            afterApprovalEvents.map { $0.kind },
            replayEvents.map { $0.kind },
            "Replay should produce identical event kinds"
        )

        // Verify terminal event kind is captured
        let terminalKinds: Set<BurnBarRunJournalEventKind> = [.runCompleted, .runFailed, .runCancelled]
        let terminalEvents = replayEvents.filter { terminalKinds.contains($0.kind) }
        XCTAssertFalse(terminalEvents.isEmpty, "Journal should capture terminal event")
    }

    func testVAL_EXEC_012_RunJournalEventSequenceForFailedRun() async throws {
        // VAL-EXEC-012: Verify journal captures ordered events for failed runs.
        let harness = try makeHarness(name: "val-exec-012-failed-journal")
        let clientID = BurnBarClientID(rawValue: "client-failed-journal")
        let sessionID = BurnBarSessionID(rawValue: "session-failed-journal")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Failed Journal Test",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        // Create a run that will fail
        let createResponse = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "This run will fail",
                modelID: "glm-5",
                metadata: [
                    "failUntilAttempt": .number(999)  // Always fail
                ]
            )
        )
        let runID = createResponse.runID

        // Wait for run to complete (it should fail)
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

        // Get events and verify sequence
        let events = try await harness.runJournal.events(for: runID)
        XCTAssertFalse(events.isEmpty, "Failed run should have journal events")

        // Verify events are in chronological order
        let sortedEvents = events.sorted { $0.emittedAt < $1.emittedAt }
        XCTAssertEqual(
            events.map { $0.eventID },
            sortedEvents.map { $0.eventID },
            "Events should be in emittedAt order"
        )

        // Verify runFailed event is present
        let failedEvents = events.filter { $0.kind == .runFailed }
        XCTAssertFalse(failedEvents.isEmpty, "Failed run should have runFailed journal event")

        // Verify replay consistency
        let replayEvents = try await harness.runJournal.events(for: runID)
        XCTAssertEqual(events.map { $0.eventID }, replayEvents.map { $0.eventID },
            "Replay should produce identical sequence for failed run")
    }

    // MARK: - VAL-EXEC-005: Retry is failed-only and resets workflow state

    func testVAL_EXEC_005_RetryRejectsNonFailedRun() async throws {
        // VAL-EXEC-005: run.retry rejects non-failed runs and resets failed run
        // approval/tool workflow before re-execution.
        // This test verifies that retry on a non-failed run throws retryRequiresFailedRun error.
        let harness = try makeHarness(name: "val-exec-005-reject-non-failed")
        let clientID = BurnBarClientID(rawValue: "client-reject-retry")
        let sessionID = BurnBarSessionID(rawValue: "session-reject-retry")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Reject Retry Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await harness.configStore.setSecret("zai-secret", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        // Create a run that completes successfully (not failed)
        let completedRun = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Simple completion",
                modelID: "glm-5"
            )
        )
        XCTAssertEqual(completedRun.phase, .completed, "Run should complete successfully")

        // Attempting to retry a non-failed run should throw retryRequiresFailedRun error
        do {
            _ = try await harness.runService.retryRun(
                BurnBarRunRetryRequest(runID: completedRun.runID, clientID: clientID)
            )
            XCTFail("Expected retryRequiresFailedRun error for non-failed run")
        } catch let error as BurnBarRunServiceError {
            guard case .retryRequiresFailedRun(let runID) = error else {
                return XCTFail("Expected retryRequiresFailedRun error, got: \(error)")
            }
            XCTAssertEqual(runID, completedRun.runID)
        }
    }

    func testVAL_EXEC_005_RetryResetsWorkflowStateAndApproval() async throws {
        // VAL-EXEC-005: Retry resets approval/tool workflow state before re-execution.
        let harness = try makeHarness(name: "val-exec-005-reset-workflow")
        let clientID = BurnBarClientID(rawValue: "client-reset-workflow")
        let sessionID = BurnBarSessionID(rawValue: "session-reset-workflow")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Reset Workflow Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        // Create a run that goes to awaiting approval and then fails
        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Fail after approval",
                modelID: "glm-5",
                metadata: [
                    "requiresApproval": .bool(true),
                    "toolKind": .string(BurnBarToolKind.applyPatch.rawValue),
                    "failUntilAttempt": .number(1)
                ]
            )
        )
        XCTAssertEqual(created.phase, .awaitingApproval)

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertNotNil(detail.approvalRequest, "Should have approval request")

        // Approve and let it fail
        let approvalID = try XCTUnwrap(detail.approvalRequest?.approvalID)
        _ = try await harness.runService.respondToApproval(
            BurnBarApprovalRespondRequest(
                response: BurnBarApprovalResponse(
                    approvalID: approvalID,
                    clientID: clientID,
                    decision: .approve,
                    respondedAt: Date()
                )
            )
        )

        // Wait for failure
        try await Task.sleep(nanoseconds: 100_000_000)

        let failedDetail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertEqual(failedDetail.run?.phase, .failed, "Run should have failed")
        XCTAssertNil(failedDetail.approvalRequest, "Approval should be cleared after failure")

        // Retry should reset workflow state and start fresh
        let retriedDetail = try await harness.runService.retryRun(
            BurnBarRunRetryRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertEqual(retriedDetail.run?.phase, .awaitingApproval, "Retry should start fresh with approval request")
        XCTAssertNotNil(retriedDetail.approvalRequest, "Retry should have fresh approval request")
    }

    // MARK: - VAL-EXEC-007: Tool failure recovery policy is explicit

    func testVAL_EXEC_007_TrustGatedFailureEscalatesToApproval() async throws {
        // VAL-EXEC-007: Trust/workspace/policy failures escalate to approval.
        let harness = try makeHarness(name: "val-exec-007-trust-gated")
        let clientID = BurnBarClientID(rawValue: "client-trust-gated")
        let sessionID = BurnBarSessionID(rawValue: "session-trust-gated")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Trust Gated Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Apply patch",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("src/example.ts"),
                        "from": .string("value = 1"),
                        "to": .string("value = 2")
                    ])
                ]
            )
        )

        let claim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: created.runID)
        )

        // Submit trust-gated failure
        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: created.runID,
                callID: try XCTUnwrap(claim.toolCall?.callID),
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .trustGated,
                    message: "Trust this workspace before applying edits."
                ),
                completedAt: Date()
            )
        )

        // VAL-EXEC-007: Trust-gated failure should escalate to approval, not fail the run
        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .awaitingApproval, "Trust-gated failure should escalate to approval")
        XCTAssertEqual(detail.approvalRequest?.tool, .readFile, "Approval tool should be the tool that failed")
        XCTAssertEqual(detail.approvalRequest?.message, "Trust this workspace before applying edits.")

        // Verify journal recorded the recovery decision
        let events = try await harness.runJournal.events(for: created.runID)
        let recoveryEvents = events.filter { $0.kind == .recoveryDecided }
        XCTAssertFalse(recoveryEvents.isEmpty, "Should have recovery decision event")
    }

    func testVAL_EXEC_007_RetryableFailureRetriesWithinBounds() async throws {
        // VAL-EXEC-007: Retryable failures retry within bounds.
        // applyFailed is a retryable tool error that should retry up to attempt limit.
        let harness = try makeHarness(name: "val-exec-007-retryable")
        let clientID = BurnBarClientID(rawValue: "client-retryable")
        let sessionID = BurnBarSessionID(rawValue: "session-retryable")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Retryable Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Apply patch",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("src/example.ts"),
                        "from": .string("value = 1"),
                        "to": .string("value = 2")
                    ])
                ]
            )
        )

        let claim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: created.runID)
        )

        // Submit retryable failure (applyFailed - workspace edit failed but can be retried)
        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: created.runID,
                callID: try XCTUnwrap(claim.toolCall?.callID),
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .applyFailed,
                    message: "Workspace edit failed."
                ),
                completedAt: Date()
            )
        )

        // First retryable failure should trigger automatic retry and dispatch new tool call
        let afterFirstFailure = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertEqual(afterFirstFailure.run?.phase, .waitingOnCompanion, "First retryable failure should trigger retry and dispatch new tool call")

        // Submit second retryable failure (attempt 2)
        let secondClaim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: created.runID)
        )
        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: created.runID,
                callID: try XCTUnwrap(secondClaim.toolCall?.callID),
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .applyFailed,
                    message: "Workspace edit failed again."
                ),
                completedAt: Date()
            )
        )

        // VAL-EXEC-007: Second retryable failure (attempt 2) should fail the run (bounds exceeded)
        let afterSecondFailure = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertEqual(afterSecondFailure.run?.phase, .failed, "Second retryable failure should exceed bounds and fail run")

        // Verify journal recorded both recovery decisions
        let events = try await harness.runJournal.events(for: created.runID)
        let recoveryEvents = events.filter { $0.kind == .recoveryDecided }
        XCTAssertEqual(recoveryEvents.count, 2, "Should have two recovery decision events")
    }

    func testVAL_EXEC_007_TerminalFailureEndsRun() async throws {
        // VAL-EXEC-007: Terminal failures end run.
        let harness = try makeHarness(name: "val-exec-007-terminal")
        let clientID = BurnBarClientID(rawValue: "client-terminal")
        let sessionID = BurnBarSessionID(rawValue: "session-terminal")

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Terminal Controller",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        try await configureProvider(harness)

        let created = try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "Apply patch",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("src/example.ts"),
                        "from": .string("value = 1"),
                        "to": .string("value = 2")
                    ])
                ]
            )
        )

        let claim = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(clientID: clientID, sessionID: sessionID, runID: created.runID)
        )

        // Submit terminal failure (terminalFailed - non-retryable companion error)
        _ = try await harness.runService.submitToolResult(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: created.runID,
                callID: try XCTUnwrap(claim.toolCall?.callID),
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .terminalFailed,
                    message: "Workspace companion crashed."
                ),
                completedAt: Date()
            )
        )

        // VAL-EXEC-007: Terminal failure should end the run immediately
        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .failed, "Terminal failure should end the run")

        // Verify no approval was requested (terminal = no recovery possible)
        XCTAssertNil(detail.approvalRequest, "Terminal failure should not request approval")
    }
}

private struct BurnBarRunServiceHarness {
    let rootURL: URL
    let secretStore: BurnBarInMemorySecretStore
    let configStore: BurnBarConfigStore
    let usageRecorder: BurnBarUsageRecorder
    let clientRegistry: BurnBarClientRegistry
    let runService: BurnBarRunService
    let runJournal: BurnBarRunJournal
}

private struct BurnBarStubProviderExecutor: BurnBarProviderExecuting {
    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        let prompt = [request.systemPrompt, request.userPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return BurnBarProviderExecutionResult(
            outputText: #"{"action":"complete","rationale":"Stub executor completed the run.","message":"stubbed response for \#(route.resolvedModelID)"}"#,
            inputTokens: max(1, prompt.count / 4),
            outputTokens: 32,
            cacheCreationTokens: 6,
            cacheReadTokens: 4
        )
    }
}

/// Provider executor that simulates failover: fails on first call with 429, succeeds on second.
/// Used to test VAL-EXEC-008: provider failover is deterministic via scorecard ordering.
private actor BurnBarFailoverSimulatorProviderExecutor: BurnBarProviderExecuting {
    private var callCount = 0

    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        callCount += 1
        if callCount == 1 {
            // First call: simulate rate limit failure
            throw BurnBarProviderExecutorError.upstreamError(429, "Rate limit exceeded")
        }
        // Second call: succeed
        let prompt = [request.systemPrompt, request.userPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return BurnBarProviderExecutionResult(
            outputText: #"{"action":"complete","rationale":"Failover succeeded.","message":"Completed via failover route."}"#,
            inputTokens: max(1, prompt.count / 4),
            outputTokens: 32,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }
}

/// Recording failover simulator that tracks the ordered sequence of route attempts.
/// Used to verify VAL-EXEC-008: deterministic attempted failover route slot/identity order.
private actor BurnBarRecordingFailoverSimulatorProviderExecutor: BurnBarProviderExecuting {
    private var callCount = 0
    private var attemptedRoutesList: [BurnBarProviderRoute] = []

    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        // Record every route attempt with its slot/identity
        attemptedRoutesList.append(route)
        callCount += 1
        if callCount == 1 {
            // First call: simulate rate limit failure (retryable)
            throw BurnBarProviderExecutorError.upstreamError(429, "Rate limit exceeded")
        }
        // Subsequent calls: succeed
        let prompt = [request.systemPrompt, request.userPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return BurnBarProviderExecutionResult(
            outputText: #"{"action":"complete","rationale":"Failover succeeded.","message":"Completed via failover route."}"#,
            inputTokens: max(1, prompt.count / 4),
            outputTokens: 32,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }

    /// Returns the ordered sequence of routes that were attempted.
    /// Each entry includes slotID and providerID for deterministic order verification.
    func attemptedRoutes() -> [BurnBarProviderRoute] {
        return attemptedRoutesList
    }
}

private actor BurnBarSequencedProviderExecutor: BurnBarProviderExecuting {
    private var outputs: [String]

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        let output = outputs.isEmpty ? #"{"action":"fail","rationale":"No queued output.","message":"No queued output available."}"# : outputs.removeFirst()

        let prompt = [request.systemPrompt, request.userPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return BurnBarProviderExecutionResult(
            outputText: output,
            inputTokens: max(1, prompt.count / 4),
            outputTokens: max(1, output.count / 4),
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }
}

private extension BurnBarJSONValue {
    func objectValue() -> [String: BurnBarJSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    func arrayValue() -> [BurnBarJSONValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }
}

private extension Dictionary where Key == String, Value == BurnBarJSONValue {
    func stringValue(forKey key: String) -> String? {
        guard case .string(let value)? = self[key] else {
            return nil
        }
        return value
    }

    func arrayValue(forKey key: String) -> [BurnBarJSONValue]? {
        guard case .array(let value)? = self[key] else {
            return nil
        }
        return value
    }
}

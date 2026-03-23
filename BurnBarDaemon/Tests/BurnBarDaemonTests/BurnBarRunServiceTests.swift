import BurnBarCore
@testable import BurnBarDaemon
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
                prompt: "Say hello from BurnBar",
                modelID: "glm-5"
            )
        )

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: response.runID, clientID: clientID)
        )
        XCTAssertEqual(detail.run?.phase, .completed)
        let usageRecords = try await harness.usageRecorder.records()
        XCTAssertEqual(usageRecords.count, 1)
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
                    code: .applyFailed,
                    message: "Workspace edit failed."
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

    func testRunTerminalCompanionFlowCompletesAfterToolResultSubmission() async throws {
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
        XCTAssertEqual(createResponse.phase, .waitingOnCompanion)

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
                    "terminalName": .string("BurnBar"),
                    "cwd": .string("/workspace")
                ]),
                error: nil,
                completedAt: Date()
            )
        )
        XCTAssertEqual(detail.run?.phase, .completed)

        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.runID, createResponse.runID)
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
        XCTAssertEqual(createResponse.phase, .waitingOnCompanion)

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
        XCTAssertEqual(createResponse.phase, .waitingOnCompanion)

        _ = try await harness.clientRegistry.detach(
            BurnBarClientDetachRequest(clientID: controllerID, sessionID: controllerSession)
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
                    "terminalName": .string("BurnBar")
                ]),
                error: nil,
                completedAt: Date()
            )
        )
        XCTAssertEqual(detail.run?.phase, .completed)
        XCTAssertEqual(detail.arbitration?.activeClientID, observerID)
    }

    private func makeHarness(name: String) throws -> BurnBarRunServiceHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-run-service-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
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
        let clientRegistry = BurnBarClientRegistry(logger: BurnBarDaemonLogger(category: "run-service-tests"))
        let runService = BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "run-service-tests")
            ),
            usageRecorder: usageRecorder,
            clientRegistry: clientRegistry,
            providerExecutor: BurnBarStubProviderExecutor(),
            logger: BurnBarDaemonLogger(category: "run-service-tests")
        )

        return BurnBarRunServiceHarness(
            rootURL: rootURL,
            configStore: configStore,
            usageRecorder: usageRecorder,
            clientRegistry: clientRegistry,
            runService: runService
        )
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
}

private struct BurnBarRunServiceHarness {
    let rootURL: URL
    let configStore: BurnBarConfigStore
    let usageRecorder: BurnBarUsageRecorder
    let clientRegistry: BurnBarClientRegistry
    let runService: BurnBarRunService
}

private struct BurnBarStubProviderExecutor: BurnBarProviderExecuting {
    func complete(prompt: String, route: BurnBarProviderRoute) async throws -> BurnBarProviderExecutionResult {
        BurnBarProviderExecutionResult(
            outputText: "stubbed response for \(route.resolvedModelID)",
            inputTokens: max(1, prompt.count / 4),
            outputTokens: 32,
            cacheReadTokens: 4
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

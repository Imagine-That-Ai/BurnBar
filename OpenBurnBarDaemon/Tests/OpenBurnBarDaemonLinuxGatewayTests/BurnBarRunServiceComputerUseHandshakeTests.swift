import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

private actor ComputerUseHandshakeGate {
    private var allowed: Bool

    init(allowed: Bool = false) {
        self.allowed = allowed
    }

    func setAllowed(_ allowed: Bool) {
        self.allowed = allowed
    }

    func permits(_ runID: BurnBarRunID) -> Bool {
        _ = runID
        return allowed
    }
}

private actor ComputerUseHandshakeDispatchRecorder {
    enum Behavior: Equatable {
        case succeed
        case failWithoutResultOnce
        case deny
        case succeedThenBreakJournal(URL)
        case suspendOnSecond
    }

    private let behavior: Behavior
    private var invocations: [BurnBarToolInvocation] = []
    private var suspendedDispatchContinuation: CheckedContinuation<Void, Never>?

    init(behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    func dispatch(_ invocation: BurnBarToolInvocation) async -> BurnBarComputerUseBrowserDispatchResult {
        invocations.append(invocation)
        if behavior == .suspendOnSecond, invocations.count == 2 {
            await withCheckedContinuation { continuation in
                suspendedDispatchContinuation = continuation
            }
        }
        let response: ComputerUseInvokeResponse
        if behavior == .deny {
            response = ComputerUseInvokeResponse(
                sessionId: "computer-use-session",
                callID: invocation.callID,
                status: .denied,
                denyReason: ComputerUseDenyReason.userRejected.rawValue
            )
        } else if behavior == .failWithoutResultOnce, invocations.count == 1 {
            response = ComputerUseInvokeResponse(
                sessionId: "computer-use-session",
                callID: invocation.callID,
                status: .executed
            )
        } else {
            response = ComputerUseInvokeResponse(
                sessionId: "computer-use-session",
                callID: invocation.callID,
                status: .executed,
                result: BurnBarToolResult(
                    callID: invocation.callID,
                    runID: invocation.runID,
                    succeeded: true,
                    output: .object(["text": .string("browser result")]),
                    completedAt: Date()
                )
            )
        }
        if case .succeedThenBreakJournal(let journalURL) = behavior {
            try? FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        }
        return BurnBarComputerUseBrowserDispatchResult(
            expectedSessionID: ComputerUseSessionID("computer-use-session"),
            response: response
        )
    }

    func recordedInvocations() -> [BurnBarToolInvocation] {
        invocations
    }

    func waitUntilInvocationCount(_ expectedCount: Int) async {
        while invocations.count < expectedCount {
            await Task.yield()
        }
    }

    func releaseSuspendedDispatch() {
        suspendedDispatchContinuation?.resume()
        suspendedDispatchContinuation = nil
    }
}

private actor ComputerUseHandshakeRevocationRecorder {
    private let suspendOnRecord: Bool
    private var runIDs: [BurnBarRunID] = []
    private var generations: [UInt64] = []
    private var recordStarted = false
    private var didSuspend = false
    private var recordContinuation: CheckedContinuation<Void, Never>?

    init(suspendOnRecord: Bool = false) {
        self.suspendOnRecord = suspendOnRecord
    }

    func record(_ runID: BurnBarRunID, generation: UInt64) async {
        runIDs.append(runID)
        generations.append(generation)
        recordStarted = true
        if suspendOnRecord, didSuspend == false {
            didSuspend = true
            await withCheckedContinuation { continuation in
                recordContinuation = continuation
            }
        }
    }

    func waitUntilRecordStarts() async {
        while !recordStarted {
            await Task.yield()
        }
    }

    func release() {
        recordContinuation?.resume()
        recordContinuation = nil
    }

    func recordedRunIDs() -> [BurnBarRunID] {
        runIDs
    }

    func recordedGenerations() -> [UInt64] {
        generations
    }
}

final class BurnBarRunServiceComputerUseHandshakeTests: XCTestCase {
    private enum RestoreMode {
        case eager
        case lazy
    }

    private enum NormalizationFailureStage {
        case journalAppend
        case checkpointWrite
    }

    func testCreateReturnsStableRunIDAndExactComputerUseRequirement() async throws {
        let harness = try await makeHarness(name: "stable-requirement")

        let created = try await createBrowserRun(using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let requirement = try XCTUnwrap(pendingRequirement)
        let listed = await harness.runService.listComputerUseRequirements()

        XCTAssertEqual(created.phase, .awaitingComputerUseSession)
        XCTAssertEqual(requirement.runID, created.runID)
        XCTAssertEqual(requirement.invocation.runID, created.runID)
        XCTAssertEqual(requirement.invocation.requestedBy, harness.clientID)
        XCTAssertEqual(requirement.invocation.tool, .browserExtract)
        XCTAssertEqual(requirement.generation, 1)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.runID, created.runID)
        XCTAssertEqual(listed.first?.callID, requirement.invocation.callID)
        XCTAssertEqual(listed.first?.generation, requirement.generation)

        let persistedCheckpoint = try await harness.runJournal.checkpoint(for: created.runID)
        let checkpoint = try XCTUnwrap(persistedCheckpoint)
        XCTAssertEqual(checkpoint.phase, .awaitingComputerUseSession)
        XCTAssertEqual(checkpoint.pendingComputerUseInvocation, requirement.invocation)
        XCTAssertEqual(checkpoint.computerUseGeneration, requirement.generation)
    }

    func testResumeRejectsWrongCallAndGenerationWithoutConsumingRequirement() async throws {
        let harness = try await makeHarness(name: "exact-resume")
        let created = try await createBrowserRun(using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let requirement = try XCTUnwrap(pendingRequirement)
        await harness.bindingGate.setAllowed(true)

        let wrongCall = try await harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: "stale-call",
            expectedGeneration: requirement.generation
        )
        let wrongGeneration = try await harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation &+ 1
        )
        let stillPending = await harness.runService.computerUseRequirement(for: created.runID)

        XCTAssertFalse(wrongCall)
        XCTAssertFalse(wrongGeneration)
        XCTAssertEqual(stillPending, requirement)
        let invocationsBeforeResume = await harness.dispatchRecorder.recordedInvocations()
        XCTAssertTrue(invocationsBeforeResume.isEmpty)

        let resumed = try await harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation
        )

        XCTAssertTrue(resumed)
        let completedSnapshot = await harness.runService.snapshot(for: created.runID)
        let consumedRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let dispatchedInvocations = await harness.dispatchRecorder.recordedInvocations()
        XCTAssertEqual(completedSnapshot?.phase, .completed)
        XCTAssertNil(consumedRequirement)
        XCTAssertEqual(dispatchedInvocations, [requirement.invocation])
    }

    func testConcurrentExactResumesClaimInvocationOnce() async throws {
        let harness = try await makeHarness(name: "concurrent-resume")
        let created = try await createBrowserRun(using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let requirement = try XCTUnwrap(pendingRequirement)
        await harness.bindingGate.setAllowed(true)

        async let first = harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation
        )
        async let second = harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation
        )
        let results = try await [first, second]

        let dispatchedInvocations = await harness.dispatchRecorder.recordedInvocations()
        let completedSnapshot = await harness.runService.snapshot(for: created.runID)
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(dispatchedInvocations, [requirement.invocation])
        XCTAssertEqual(completedSnapshot?.phase, .completed)
    }

    func testComputerUseDenialFailsRunWithoutOpeningSecondApproval() async throws {
        let dispatcher = ComputerUseHandshakeDispatchRecorder(behavior: .deny)
        let harness = try await makeHarness(name: "operator-denial", dispatcher: dispatcher)
        let created = try await createBrowserRun(using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let requirement = try XCTUnwrap(pendingRequirement)
        await harness.bindingGate.setAllowed(true)

        let resumed = try await harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation
        )
        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: harness.clientID)
        )
        let invocations = await dispatcher.recordedInvocations()

        XCTAssertTrue(resumed)
        XCTAssertEqual(detail.run?.phase, .failed)
        XCTAssertEqual(detail.run?.errorMessage, ComputerUseDenyReason.userRejected.rawValue)
        XCTAssertNil(detail.approvalRequest)
        XCTAssertEqual(invocations, [requirement.invocation])
        let requirementAfterDenial = await harness.runService.computerUseRequirement(for: created.runID)
        XCTAssertNil(requirementAfterDenial)
    }

    func testCancellationInvalidatesBeforeRevocationAwaitAndPreventsStaleResume() async throws {
        let revocations = ComputerUseHandshakeRevocationRecorder(suspendOnRecord: true)
        let harness = try await makeHarness(name: "cancel-stale", revocations: revocations)
        let created = try await createBrowserRun(using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let requirement = try XCTUnwrap(pendingRequirement)
        await harness.bindingGate.setAllowed(true)

        let cancellation = Task {
            try await harness.runService.cancelRun(
                BurnBarRunCancelRequest(
                    runID: created.runID,
                    clientID: harness.clientID,
                    reason: "cancel pending Computer Use"
                )
            )
        }
        await revocations.waitUntilRecordStarts()
        let staleResume = try await harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation
        )
        await revocations.release()
        let cancelled = try await cancellation.value

        XCTAssertEqual(cancelled.run?.phase, .cancelled)
        XCTAssertFalse(staleResume)
        let cancelledRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let revokedRunIDs = await revocations.recordedRunIDs()
        let dispatchedInvocations = await harness.dispatchRecorder.recordedInvocations()
        XCTAssertNil(cancelledRequirement)
        XCTAssertEqual(revokedRunIDs, [created.runID])
        XCTAssertTrue(dispatchedInvocations.isEmpty)
    }

    func testRetryAllocatesNewGenerationAndRejectsPreRetryResumeToken() async throws {
        let dispatcher = ComputerUseHandshakeDispatchRecorder(behavior: .failWithoutResultOnce)
        let harness = try await makeHarness(name: "retry-stale", dispatcher: dispatcher)
        let created = try await createBrowserRun(using: harness)
        let originalRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let original = try XCTUnwrap(originalRequirement)
        await harness.bindingGate.setAllowed(true)

        let terminalResume = try await harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: original.invocation.callID,
            expectedGeneration: original.generation
        )
        XCTAssertTrue(terminalResume)
        let failedSnapshot = await harness.runService.snapshot(for: created.runID)
        XCTAssertEqual(failedSnapshot?.phase, .failed)

        await harness.bindingGate.setAllowed(false)
        let retried = try await harness.runService.retryRun(
            BurnBarRunRetryRequest(runID: created.runID, clientID: harness.clientID)
        )
        let replacementRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let replacement = try XCTUnwrap(replacementRequirement)

        XCTAssertEqual(retried.run?.phase, .awaitingComputerUseSession)
        XCTAssertNotEqual(replacement.invocation.callID, original.invocation.callID)
        XCTAssertGreaterThan(replacement.generation, original.generation)

        await harness.bindingGate.setAllowed(true)
        let staleResume = try await harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: original.invocation.callID,
            expectedGeneration: original.generation
        )
        XCTAssertFalse(staleResume)
        let requirementAfterStaleResume = await harness.runService.computerUseRequirement(for: created.runID)
        XCTAssertEqual(requirementAfterStaleResume, replacement)

        let replacementResume = try await harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: replacement.invocation.callID,
            expectedGeneration: replacement.generation
        )
        XCTAssertTrue(replacementResume)
        let completedSnapshot = await harness.runService.snapshot(for: created.runID)
        let dispatchedInvocations = await dispatcher.recordedInvocations()
        XCTAssertEqual(completedSnapshot?.phase, .completed)
        XCTAssertEqual(dispatchedInvocations.count, 2)
    }

    func testBlockedTerminalRevocationDoesNotHoldClaimAcrossRetryGeneration() async throws {
        let dispatcher = ComputerUseHandshakeDispatchRecorder(behavior: .failWithoutResultOnce)
        let revocations = ComputerUseHandshakeRevocationRecorder(suspendOnRecord: true)
        let harness = try await makeHarness(
            name: "terminal-revocation-retry",
            dispatcher: dispatcher,
            revocations: revocations
        )
        let created = try await createBrowserRun(using: harness)
        let originalRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let original = try XCTUnwrap(originalRequirement)
        await harness.bindingGate.setAllowed(true)

        let originalResume = Task {
            try await harness.runService.resumeComputerUseRun(
                created.runID,
                expectedCallID: original.invocation.callID,
                expectedGeneration: original.generation
            )
        }
        await revocations.waitUntilRecordStarts()

        await harness.bindingGate.setAllowed(false)
        let retried = try await harness.runService.retryRun(
            BurnBarRunRetryRequest(runID: created.runID, clientID: harness.clientID)
        )
        let replacementRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let replacement = try XCTUnwrap(replacementRequirement)
        XCTAssertEqual(retried.run?.phase, .awaitingComputerUseSession)
        XCTAssertGreaterThan(replacement.generation, original.generation)

        await harness.bindingGate.setAllowed(true)
        let replacementResumed = try await harness.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: replacement.invocation.callID,
            expectedGeneration: replacement.generation
        )
        XCTAssertTrue(replacementResumed)
        let completedSnapshot = await harness.runService.snapshot(for: created.runID)
        XCTAssertEqual(completedSnapshot?.phase, .completed)

        await revocations.release()
        let originalDidResume = try await originalResume.value
        XCTAssertTrue(originalDidResume)
        let generations = await revocations.recordedGenerations()
        XCTAssertEqual(generations, [original.generation, replacement.generation])
        let invocations = await dispatcher.recordedInvocations()
        XCTAssertEqual(invocations.count, 2)
    }

    func testRestartRestoresRequirementButRequiresFreshBindingAuthority() async throws {
        let root = temporaryRoot(name: "restart")
        let first = try await makeHarness(name: "restart-first", root: root)
        let created = try await createBrowserRun(using: first)
        let originalRequirement = await first.runService.computerUseRequirement(for: created.runID)
        let original = try XCTUnwrap(originalRequirement)

        let restarted = try await makeHarness(name: "restart-second", root: root)
        let restoredRequirement = await restarted.runService.computerUseRequirement(for: created.runID)
        let restored = try XCTUnwrap(restoredRequirement)
        let legacyBridgeResponse = try await restarted.runService.executeTool(
            BurnBarToolExecutionRequest(
                clientID: restarted.clientID,
                sessionID: restarted.sessionID,
                runID: created.runID
            )
        )
        let withoutFreshAuthority = try await restarted.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: restored.invocation.callID,
            expectedGeneration: restored.generation
        )

        XCTAssertEqual(restored, original)
        XCTAssertEqual(legacyBridgeResponse.disposition, .noPendingToolCall)
        let requirementAfterLegacyPoll = await restarted.runService.computerUseRequirement(for: created.runID)
        XCTAssertEqual(requirementAfterLegacyPoll, original)
        XCTAssertFalse(withoutFreshAuthority)
        let invocationsWithoutAuthority = await restarted.dispatchRecorder.recordedInvocations()
        XCTAssertTrue(invocationsWithoutAuthority.isEmpty)

        await restarted.bindingGate.setAllowed(true)
        let resumed = try await restarted.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: restored.invocation.callID,
            expectedGeneration: restored.generation
        )
        XCTAssertTrue(resumed)
        let completedSnapshot = await restarted.runService.snapshot(for: created.runID)
        XCTAssertEqual(completedSnapshot?.phase, .completed)
    }

    func testRestartFailsInterruptedBrowserActionWithoutRedispatchAndRequiresRetry() async throws {
        let root = temporaryRoot(name: "restart-interrupted")
        let first = try await makeHarness(name: "restart-interrupted-first", root: root)
        let created = try await createBrowserRun(using: first)
        let pendingOriginalRequirement = await first.runService.computerUseRequirement(for: created.runID)
        let originalRequirement = try XCTUnwrap(pendingOriginalRequirement)
        let pendingOriginalCheckpoint = try await first.runJournal.checkpoint(for: created.runID)
        let originalCheckpoint = try XCTUnwrap(pendingOriginalCheckpoint)
        let invocation = originalRequirement.invocation
        let inProgressCall = BurnBarToolCallSnapshot(
            callID: invocation.callID,
            runID: invocation.runID,
            tool: invocation.tool,
            arguments: invocation.arguments,
            status: .inProgress,
            requestedBy: invocation.requestedBy,
            requestedAt: invocation.requestedAt,
            claimedBy: first.clientID,
            claimedAt: Date()
        )
        try await first.runJournal.writeCheckpoint(
            BurnBarRunJournalCheckpoint(
                runID: originalCheckpoint.runID,
                clientID: originalCheckpoint.clientID,
                sessionID: originalCheckpoint.sessionID,
                phase: .executingTool,
                modelID: originalCheckpoint.modelID,
                originalPrompt: originalCheckpoint.originalPrompt,
                metadata: originalCheckpoint.metadata,
                intent: originalCheckpoint.intent,
                planOutline: originalCheckpoint.planOutline,
                attempt: originalCheckpoint.attempt,
                errorMessage: nil,
                approvalRequest: nil,
                approvalResolvedForAttempt: originalCheckpoint.approvalResolvedForAttempt,
                activeApprovalID: nil,
                pendingApprovalToolInvocation: nil,
                pendingComputerUseInvocation: nil,
                computerUseGeneration: originalRequirement.generation,
                lastToolCall: inProgressCall,
                lastToolCallID: inProgressCall.callID,
                workflowStep: originalCheckpoint.workflowStep,
                workflowReadContent: originalCheckpoint.workflowReadContent,
                companionToolCompleted: originalCheckpoint.companionToolCompleted,
                lastRecoveryDecision: originalCheckpoint.lastRecoveryDecision,
                loopState: originalCheckpoint.loopState,
                updatedAt: Date()
            )
        )

        let revocations = ComputerUseHandshakeRevocationRecorder()
        let restarted = try await makeHarness(
            name: "restart-interrupted-second",
            root: root,
            revocations: revocations
        )
        let restored = try await restarted.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: restarted.clientID)
        )
        let legacyBridgeResponse = try await restarted.runService.executeTool(
            BurnBarToolExecutionRequest(
                clientID: restarted.clientID,
                sessionID: restarted.sessionID,
                runID: created.runID
            )
        )

        XCTAssertEqual(restored.run?.phase, .failed)
        XCTAssertEqual(restored.run?.errorMessage, BurnBarRunService.interruptedComputerUseMessage)
        XCTAssertEqual(legacyBridgeResponse.disposition, .noPendingToolCall)
        let restoredRequirement = await restarted.runService.computerUseRequirement(for: created.runID)
        let restoredDispatches = await restarted.dispatchRecorder.recordedInvocations()
        let restoredRevocations = await revocations.recordedGenerations()
        XCTAssertNil(restoredRequirement)
        XCTAssertTrue(restoredDispatches.isEmpty)
        XCTAssertEqual(restoredRevocations, [originalRequirement.generation])

        let retried = try await restarted.runService.retryRun(
            BurnBarRunRetryRequest(runID: created.runID, clientID: restarted.clientID)
        )
        let pendingReplacement = await restarted.runService.computerUseRequirement(for: created.runID)
        let replacement = try XCTUnwrap(pendingReplacement)
        XCTAssertEqual(retried.run?.phase, .awaitingComputerUseSession)
        XCTAssertGreaterThan(replacement.generation, originalRequirement.generation)
        XCTAssertNotEqual(replacement.invocation.callID, originalRequirement.invocation.callID)
    }

    func testAlreadyBoundSecondBrowserActionCheckpointsBeforeDispatchAndRestartNeverRedispatches() async throws {
        let root = temporaryRoot(name: "restart-second-action")
        let dispatcher = ComputerUseHandshakeDispatchRecorder(behavior: .suspendOnSecond)
        let first = try await makeHarness(
            name: "restart-second-action-first",
            root: root,
            dispatcher: dispatcher
        )
        let created = try await createBrowserRun(using: first)
        let pendingRequirement = await first.runService.computerUseRequirement(for: created.runID)
        let requirement = try XCTUnwrap(pendingRequirement)
        await first.bindingGate.setAllowed(true)
        let resumed = try await first.runService.resumeComputerUseRun(
            created.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation
        )
        XCTAssertTrue(resumed)

        let pendingManagedRun = await first.runService.runs[created.runID]
        var managedRun = try XCTUnwrap(pendingManagedRun)
        managedRun.snapshot = BurnBarRunStateSnapshot(
            runID: managedRun.runID,
            clientID: managedRun.snapshot.clientID,
            sessionID: managedRun.snapshot.sessionID,
            phase: .planning,
            modelID: managedRun.modelID,
            updatedAt: Date()
        )
        let secondInvocation = BurnBarToolInvocation(
            callID: "second-bound-browser-action",
            runID: managedRun.runID,
            tool: .browserClick,
            arguments: .object(["selector": .string("#continue")]),
            requestedBy: managedRun.snapshot.clientID,
            requestedAt: Date()
        )
        let secondDispatch = Task { () throws -> BurnBarManagedRun in
            var executingRun = managedRun
            try await first.runService.executeBrowserToolInvocation(
                secondInvocation,
                for: &executingRun
            )
            return executingRun
        }
        await dispatcher.waitUntilInvocationCount(2)

        let pendingCheckpoint = try await first.runJournal.checkpoint(for: created.runID)
        let checkpoint = try XCTUnwrap(pendingCheckpoint)
        XCTAssertEqual(checkpoint.phase, .executingTool)
        XCTAssertEqual(checkpoint.lastToolCall?.callID, secondInvocation.callID)
        XCTAssertEqual(checkpoint.lastToolCall?.status, .inProgress)

        let restartedDispatcher = ComputerUseHandshakeDispatchRecorder()
        let restarted = try await makeHarness(
            name: "restart-second-action-second",
            root: root,
            dispatcher: restartedDispatcher
        )
        let restored = try await restarted.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: restarted.clientID)
        )
        XCTAssertEqual(restored.run?.phase, .failed)
        XCTAssertEqual(restored.run?.errorMessage, BurnBarRunService.interruptedComputerUseMessage)
        let pendingNormalizedCheckpoint = try await restarted.runJournal.checkpoint(for: created.runID)
        let normalizedCheckpoint = try XCTUnwrap(pendingNormalizedCheckpoint)
        XCTAssertEqual(normalizedCheckpoint.lastToolCall?.callID, secondInvocation.callID)
        XCTAssertEqual(normalizedCheckpoint.lastToolCall?.status, .failed)
        let originalDispatches = await dispatcher.recordedInvocations()
        let restartedDispatches = await restartedDispatcher.recordedInvocations()
        XCTAssertEqual(
            originalDispatches.filter { $0.callID == secondInvocation.callID }.count,
            1
        )
        XCTAssertTrue(restartedDispatches.isEmpty)

        await dispatcher.releaseSuspendedDispatch()
        _ = try? await secondDispatch.value
    }

    func testEagerRestoreRetriesInterruptedNormalizationAfterJournalAppendFailure() async throws {
        try await assertInterruptedNormalizationRetriesDurably(
            restoreMode: .eager,
            failureStage: .journalAppend
        )
    }

    func testEagerRestoreRetriesInterruptedNormalizationAfterCheckpointWriteFailure() async throws {
        try await assertInterruptedNormalizationRetriesDurably(
            restoreMode: .eager,
            failureStage: .checkpointWrite
        )
    }

    func testLazyRestoreRetriesInterruptedNormalizationAfterJournalAppendFailure() async throws {
        try await assertInterruptedNormalizationRetriesDurably(
            restoreMode: .lazy,
            failureStage: .journalAppend
        )
    }

    func testLazyRestoreRetriesInterruptedNormalizationAfterCheckpointWriteFailure() async throws {
        try await assertInterruptedNormalizationRetriesDurably(
            restoreMode: .lazy,
            failureStage: .checkpointWrite
        )
    }

    func testPreDispatchJournalFailureFailsRunAndRevokesWithoutExecutingAction() async throws {
        let revocations = ComputerUseHandshakeRevocationRecorder()
        let harness = try await makeHarness(name: "pre-dispatch-journal-failure", revocations: revocations)
        let created = try await createBrowserRun(using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let requirement = try XCTUnwrap(pendingRequirement)
        let journalURL = harness.root.appendingPathComponent("run-journal.jsonl")
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        await harness.bindingGate.setAllowed(true)

        var observedJournalError: Error?
        do {
            _ = try await harness.runService.resumeComputerUseRun(
                created.runID,
                expectedCallID: requirement.invocation.callID,
                expectedGeneration: requirement.generation
            )
            XCTFail("expected journal persistence failure")
        } catch {
            observedJournalError = error
        }
        XCTAssertNotNil(observedJournalError)

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: harness.clientID)
        )
        let invocations = await harness.dispatchRecorder.recordedInvocations()
        let revokedGenerations = await revocations.recordedGenerations()
        XCTAssertEqual(detail.run?.phase, .failed)
        XCTAssertTrue(invocations.isEmpty)
        XCTAssertEqual(revokedGenerations, [requirement.generation])
    }

    func testPostDispatchJournalFailureFailsRunAndRevokesAfterSingleAction() async throws {
        let root = temporaryRoot(name: "post-dispatch-journal-failure")
        let journalURL = root.appendingPathComponent("run-journal.jsonl")
        let dispatcher = ComputerUseHandshakeDispatchRecorder(
            behavior: .succeedThenBreakJournal(journalURL)
        )
        let revocations = ComputerUseHandshakeRevocationRecorder()
        let harness = try await makeHarness(
            name: "post-dispatch-journal-failure",
            root: root,
            dispatcher: dispatcher,
            revocations: revocations
        )
        let created = try await createBrowserRun(using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(for: created.runID)
        let requirement = try XCTUnwrap(pendingRequirement)
        await harness.bindingGate.setAllowed(true)

        var observedJournalError: Error?
        do {
            _ = try await harness.runService.resumeComputerUseRun(
                created.runID,
                expectedCallID: requirement.invocation.callID,
                expectedGeneration: requirement.generation
            )
            XCTFail("expected post-dispatch journal failure")
        } catch {
            observedJournalError = error
        }
        XCTAssertNotNil(observedJournalError)

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: harness.clientID)
        )
        let invocations = await dispatcher.recordedInvocations()
        let revokedGenerations = await revocations.recordedGenerations()
        XCTAssertEqual(detail.run?.phase, .failed)
        XCTAssertEqual(invocations, [requirement.invocation])
        XCTAssertEqual(revokedGenerations, [requirement.generation])
    }

    private func createBrowserRun(
        using harness: ComputerUseHandshakeHarness
    ) async throws -> BurnBarRunCreateResponse {
        try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                prompt: "Extract the current browser page",
                modelID: "glm-5",
                metadata: [
                    "toolKind": .string(BurnBarToolKind.browserExtract.rawValue),
                    "toolArguments": .object([:])
                ]
            )
        )
    }

    private func assertInterruptedNormalizationRetriesDurably(
        restoreMode: RestoreMode,
        failureStage: NormalizationFailureStage
    ) async throws {
        let root = temporaryRoot(name: "normalization-\(restoreMode)-\(failureStage)")
        let first = try await makeHarness(name: "normalization-producer", root: root)
        let created = try await createBrowserRun(using: first)
        let pendingOriginalRequirement = await first.runService.computerUseRequirement(for: created.runID)
        let originalRequirement = try XCTUnwrap(pendingOriginalRequirement)
        try await persistInterruptedBrowserCheckpoint(
            runID: created.runID,
            requirement: originalRequirement,
            harness: first
        )

        let checkpointsURL = root.appendingPathComponent("run-checkpoints", isDirectory: true)
        let stagedCheckpointsURL = root.appendingPathComponent("run-checkpoints-staged", isDirectory: true)
        if restoreMode == .lazy {
            try FileManager.default.moveItem(at: checkpointsURL, to: stagedCheckpointsURL)
        }

        let revocations = ComputerUseHandshakeRevocationRecorder(suspendOnRecord: true)
        let restarted = try await makeHarness(
            name: "normalization-restarted",
            root: root,
            revocations: revocations
        )
        if restoreMode == .lazy {
            let initial = try await restarted.runService.listRuns(
                BurnBarRunListRequest(clientID: restarted.clientID)
            )
            XCTAssertTrue(initial.runs.isEmpty)
            try FileManager.default.moveItem(at: stagedCheckpointsURL, to: checkpointsURL)
        }

        let journalURL = root.appendingPathComponent("run-journal.jsonl")
        if failureStage == .journalAppend {
            _ = try await restarted.runJournal.events(for: created.runID)
        }
        let restoreTask = Task {
            try await restarted.runService.getRun(
                BurnBarRunGetRequest(runID: created.runID, clientID: restarted.clientID)
            )
        }
        await revocations.waitUntilRecordStarts()

        let faultBackupURL: URL
        switch failureStage {
        case .journalAppend:
            faultBackupURL = root.appendingPathComponent("run-journal-backup.jsonl")
            try FileManager.default.moveItem(at: journalURL, to: faultBackupURL)
            try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        case .checkpointWrite:
            faultBackupURL = root.appendingPathComponent("run-checkpoints-backup", isDirectory: true)
            try FileManager.default.moveItem(at: checkpointsURL, to: faultBackupURL)
            try Data().write(to: checkpointsURL)
        }
        await revocations.release()

        var observedRestoreError: Error?
        do {
            _ = try await restoreTask.value
            XCTFail("expected interrupted Computer Use normalization persistence to fail")
        } catch {
            observedRestoreError = error
        }
        XCTAssertNotNil(observedRestoreError)

        switch failureStage {
        case .journalAppend:
            try FileManager.default.removeItem(at: journalURL)
            try FileManager.default.moveItem(at: faultBackupURL, to: journalURL)
        case .checkpointWrite:
            try FileManager.default.removeItem(at: checkpointsURL)
            try FileManager.default.moveItem(at: faultBackupURL, to: checkpointsURL)
        }

        let retried = try await restarted.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: restarted.clientID)
        )
        XCTAssertEqual(retried.run?.phase, .failed)
        XCTAssertEqual(retried.run?.errorMessage, BurnBarRunService.interruptedComputerUseMessage)

        let pendingDurableCheckpoint = try await restarted.runJournal.checkpoint(for: created.runID)
        let durableCheckpoint = try XCTUnwrap(pendingDurableCheckpoint)
        XCTAssertEqual(durableCheckpoint.phase, .failed)
        XCTAssertEqual(
            durableCheckpoint.computerUseGeneration,
            originalRequirement.generation &+ 1
        )
        XCTAssertEqual(durableCheckpoint.lastToolCall?.status, .failed)

        let durableEvents = try await restarted.runJournal.events(for: created.runID)
        let normalizationEvents = durableEvents.filter {
            $0.kind == .runFailed
                && $0.phase == .failed
                && $0.payload == .object([
                    "reason": .string(BurnBarRunService.interruptedComputerUseMessage)
                ])
        }
        XCTAssertEqual(normalizationEvents.count, 1)
        let normalizationEvent = try XCTUnwrap(normalizationEvents.first)
        let recordedRevocations = await revocations.recordedGenerations()
        XCTAssertEqual(recordedRevocations, [originalRequirement.generation])

        let freshRevocations = ComputerUseHandshakeRevocationRecorder()
        let fresh = try await makeHarness(
            name: "normalization-fresh",
            root: root,
            revocations: freshRevocations
        )
        let freshDetail = try await fresh.runService.getRun(
            BurnBarRunGetRequest(runID: created.runID, clientID: fresh.clientID)
        )
        XCTAssertEqual(freshDetail.run?.phase, .failed)
        let pendingFreshCheckpoint = try await fresh.runJournal.checkpoint(for: created.runID)
        let freshCheckpoint = try XCTUnwrap(pendingFreshCheckpoint)
        XCTAssertEqual(
            freshCheckpoint.computerUseGeneration,
            originalRequirement.generation &+ 1
        )
        let freshRecordedRevocations = await freshRevocations.recordedGenerations()
        XCTAssertTrue(freshRecordedRevocations.isEmpty)
        let freshEvents = try await fresh.runJournal.events(for: created.runID)
        XCTAssertEqual(
            freshEvents.filter { $0.eventID == normalizationEvent.eventID }.count,
            1
        )
    }

    private func persistInterruptedBrowserCheckpoint(
        runID: BurnBarRunID,
        requirement: BurnBarComputerUseRunRequirement,
        harness: ComputerUseHandshakeHarness
    ) async throws {
        let pendingOriginalCheckpoint = try await harness.runJournal.checkpoint(for: runID)
        let originalCheckpoint = try XCTUnwrap(pendingOriginalCheckpoint)
        let invocation = requirement.invocation
        let inProgressCall = BurnBarToolCallSnapshot(
            callID: invocation.callID,
            runID: invocation.runID,
            tool: invocation.tool,
            arguments: invocation.arguments,
            status: .inProgress,
            requestedBy: invocation.requestedBy,
            requestedAt: invocation.requestedAt,
            claimedBy: harness.clientID,
            claimedAt: Date()
        )
        try await harness.runJournal.writeCheckpoint(
            BurnBarRunJournalCheckpoint(
                runID: originalCheckpoint.runID,
                clientID: originalCheckpoint.clientID,
                sessionID: originalCheckpoint.sessionID,
                phase: .executingTool,
                modelID: originalCheckpoint.modelID,
                originalPrompt: originalCheckpoint.originalPrompt,
                metadata: originalCheckpoint.metadata,
                intent: originalCheckpoint.intent,
                planOutline: originalCheckpoint.planOutline,
                attempt: originalCheckpoint.attempt,
                errorMessage: nil,
                approvalRequest: nil,
                approvalResolvedForAttempt: originalCheckpoint.approvalResolvedForAttempt,
                activeApprovalID: nil,
                pendingApprovalToolInvocation: nil,
                pendingComputerUseInvocation: nil,
                computerUseGeneration: requirement.generation,
                lastToolCall: inProgressCall,
                lastToolCallID: inProgressCall.callID,
                workflowStep: originalCheckpoint.workflowStep,
                workflowReadContent: originalCheckpoint.workflowReadContent,
                companionToolCompleted: originalCheckpoint.companionToolCompleted,
                lastRecoveryDecision: originalCheckpoint.lastRecoveryDecision,
                loopState: originalCheckpoint.loopState,
                updatedAt: Date()
            )
        )
    }

    private func makeHarness(
        name: String,
        root: URL? = nil,
        dispatcher: ComputerUseHandshakeDispatchRecorder = ComputerUseHandshakeDispatchRecorder(),
        revocations: ComputerUseHandshakeRevocationRecorder? = nil
    ) async throws -> ComputerUseHandshakeHarness {
        let root = root ?? temporaryRoot(name: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: root.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "computer-use-handshake-tests")
        )
        try await configStore.setSecret("zai-secret", for: "zai")
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        let clientID = BurnBarClientID(rawValue: "computer-use-handshake-controller")
        let sessionID = BurnBarSessionID(rawValue: "computer-use-handshake-session")
        let clientRegistry = BurnBarClientRegistry(
            logger: BurnBarDaemonLogger(category: "computer-use-handshake-tests")
        )
        _ = await clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Computer Use Handshake Tests",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        let bindingGate = ComputerUseHandshakeGate()
        let runJournal = BurnBarRunJournal(
            fileURL: root.appendingPathComponent("run-journal.jsonl"),
            checkpointsDirectoryURL: root.appendingPathComponent("run-checkpoints", isDirectory: true),
            logger: BurnBarDaemonLogger(category: "computer-use-handshake-tests")
        )
        let runRevoker: BurnBarComputerUseRunRevoker?
        if let revocations {
            runRevoker = { runID, generation in
                await revocations.record(runID, generation: generation)
            }
        } else {
            runRevoker = nil
        }
        let runService = BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "computer-use-handshake-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: root.appendingPathComponent("usage.jsonl"),
                logger: BurnBarDaemonLogger(category: "computer-use-handshake-tests")
            ),
            clientRegistry: clientRegistry,
            runJournal: runJournal,
            computerUseBrowserDispatcher: { invocation in
                await dispatcher.dispatch(invocation)
            },
            computerUseRunBindingChecker: { runID, _ in
                await bindingGate.permits(runID)
            },
            computerUseRunRevoker: runRevoker,
            logger: BurnBarDaemonLogger(category: "computer-use-handshake-tests")
        )

        return ComputerUseHandshakeHarness(
            root: root,
            clientID: clientID,
            sessionID: sessionID,
            bindingGate: bindingGate,
            dispatchRecorder: dispatcher,
            runJournal: runJournal,
            runService: runService
        )
    }

    private func temporaryRoot(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-handshake-\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}

private struct ComputerUseHandshakeHarness {
    let root: URL
    let clientID: BurnBarClientID
    let sessionID: BurnBarSessionID
    let bindingGate: ComputerUseHandshakeGate
    let dispatchRecorder: ComputerUseHandshakeDispatchRecorder
    let runJournal: BurnBarRunJournal
    let runService: BurnBarRunService
}

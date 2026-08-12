import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

private enum SafariRunBindingTestError: Error {
    case dispatchFailed
}

private actor SafariRunBindingProbe {
    private var allowedSafariRequirement: BurnBarComputerUseRunRequirement?
    private var allowedBrowserRunID: BurnBarRunID?
    private var allowedBrowserGeneration: UInt64?
    private var shouldFailNextSafariDispatch = false

    private(set) var safariBindingChecks: [BurnBarComputerUseRunRequirement] = []
    private(set) var safariDispatches: [BurnBarComputerUseRunRequirement] = []
    private(set) var safariRevocations: [BurnBarComputerUseRunRequirement] = []
    private(set) var browserBindingChecks: [(BurnBarRunID, UInt64)] = []
    private(set) var browserDispatches: [BurnBarToolInvocation] = []
    private(set) var browserRevocations: [(BurnBarRunID, UInt64)] = []

    func allowSafari(_ requirement: BurnBarComputerUseRunRequirement) {
        allowedSafariRequirement = requirement
    }

    func allowBrowser(runID: BurnBarRunID, generation: UInt64) {
        allowedBrowserRunID = runID
        allowedBrowserGeneration = generation
    }

    func failNextSafariDispatch() {
        shouldFailNextSafariDispatch = true
    }

    func checkSafari(_ requirement: BurnBarComputerUseRunRequirement) -> Bool {
        safariBindingChecks.append(requirement)
        return requirement == allowedSafariRequirement
    }

    func dispatchSafari(
        _ requirement: BurnBarComputerUseRunRequirement
    ) throws -> BurnBarComputerUseBrowserDispatchResult {
        safariDispatches.append(requirement)
        if shouldFailNextSafariDispatch {
            shouldFailNextSafariDispatch = false
            throw SafariRunBindingTestError.dispatchFailed
        }
        return Self.successfulDispatch(
            sessionID: "safari-cu-session",
            invocation: requirement.invocation,
            output: .object(["surface": .string("safari")])
        )
    }

    func revokeSafari(_ requirement: BurnBarComputerUseRunRequirement) {
        safariRevocations.append(requirement)
    }

    func checkBrowser(runID: BurnBarRunID, generation: UInt64) -> Bool {
        browserBindingChecks.append((runID, generation))
        return runID == allowedBrowserRunID && generation == allowedBrowserGeneration
    }

    func dispatchBrowser(
        _ invocation: BurnBarToolInvocation
    ) -> BurnBarComputerUseBrowserDispatchResult {
        browserDispatches.append(invocation)
        return Self.successfulDispatch(
            sessionID: "browser-cu-session",
            invocation: invocation,
            output: .object(["surface": .string("browser")])
        )
    }

    func revokeBrowser(runID: BurnBarRunID, generation: UInt64) {
        browserRevocations.append((runID, generation))
    }

    private static func successfulDispatch(
        sessionID: String,
        invocation: BurnBarToolInvocation,
        output: BurnBarJSONValue
    ) -> BurnBarComputerUseBrowserDispatchResult {
        BurnBarComputerUseBrowserDispatchResult(
            expectedSessionID: ComputerUseSessionID(sessionID),
            response: ComputerUseInvokeResponse(
                sessionId: sessionID,
                callID: invocation.callID,
                status: .executed,
                result: BurnBarToolResult(
                    callID: invocation.callID,
                    runID: invocation.runID,
                    succeeded: true,
                    output: output,
                    completedAt: Date()
                )
            )
        )
    }
}

final class SafariRunServiceBindingTests: XCTestCase {
    func testSafariRunWaitsForAndResumesOnlyItsExactDedicatedBinding() async throws {
        let probe = SafariRunBindingProbe()
        let harness = try await makeHarness(name: "exact-safari-binding", probe: probe)
        let created = try await createRun(tool: .safariExtract, using: harness)

        XCTAssertEqual(created.phase, .awaitingComputerUseSession)
        let pendingRequirement = await harness.runService.computerUseRequirement(
            for: created.runID
        )
        let requirement = try XCTUnwrap(pendingRequirement)
        let listed = await harness.runService.listComputerUseRequirements()

        XCTAssertEqual(requirement.runID, created.runID)
        XCTAssertEqual(requirement.clientID, harness.clientID)
        XCTAssertEqual(requirement.sessionID, harness.sessionID)
        XCTAssertEqual(requirement.invocation.runID, created.runID)
        XCTAssertEqual(requirement.invocation.requestedBy, harness.clientID)
        XCTAssertEqual(requirement.invocation.tool, .safariExtract)
        XCTAssertEqual(requirement.generation, 1)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.runID, requirement.runID)
        XCTAssertEqual(listed.first?.callID, requirement.invocation.callID)
        XCTAssertEqual(listed.first?.clientID, requirement.clientID)
        XCTAssertEqual(listed.first?.toolKind, .safariExtract)
        XCTAssertEqual(listed.first?.generation, requirement.generation)

        let prebindingChecks = await probe.safariBindingChecks
        XCTAssertEqual(prebindingChecks.count, 1)
        XCTAssertEqual(prebindingChecks.first?.runID, requirement.runID)
        XCTAssertEqual(prebindingChecks.first?.clientID, requirement.clientID)
        XCTAssertEqual(prebindingChecks.first?.sessionID, requirement.sessionID)
        XCTAssertEqual(prebindingChecks.first?.invocation, requirement.invocation)
        XCTAssertEqual(prebindingChecks.first?.generation, 0)
        let prebindingBrowserChecks = await probe.browserBindingChecks
        XCTAssertTrue(prebindingBrowserChecks.isEmpty)

        let legacyBridgeResponse = try await harness.runService.executeTool(
            BurnBarToolExecutionRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                runID: requirement.runID
            )
        )
        XCTAssertEqual(legacyBridgeResponse.disposition, .noPendingToolCall)
        let requirementAfterLegacyPoll = await harness.runService.computerUseRequirement(
            for: requirement.runID
        )
        XCTAssertEqual(requirementAfterLegacyPoll, requirement)

        await probe.allowSafari(requirement)
        let staleCallAccepted = try await harness.runService.resumeComputerUseRun(
            requirement.runID,
            expectedCallID: "stale-safari-call",
            expectedGeneration: requirement.generation
        )
        let staleGenerationAccepted = try await harness.runService.resumeComputerUseRun(
            requirement.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation &+ 1
        )
        XCTAssertFalse(staleCallAccepted)
        XCTAssertFalse(staleGenerationAccepted)
        let dispatchesBeforeResume = await probe.safariDispatches
        XCTAssertTrue(dispatchesBeforeResume.isEmpty)

        let resumed = try await harness.runService.resumeComputerUseRun(
            requirement.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation
        )

        XCTAssertTrue(resumed)
        let completedSnapshot = await harness.runService.snapshot(for: requirement.runID)
        let consumedRequirement = await harness.runService.computerUseRequirement(
            for: requirement.runID
        )
        let safariDispatches = await probe.safariDispatches
        let safariRevocations = await probe.safariRevocations
        let browserDispatches = await probe.browserDispatches
        let browserRevocations = await probe.browserRevocations
        XCTAssertEqual(completedSnapshot?.phase, .completed)
        XCTAssertNil(consumedRequirement)
        XCTAssertEqual(safariDispatches, [requirement])
        XCTAssertEqual(safariRevocations, [requirement])
        XCTAssertTrue(browserDispatches.isEmpty)
        XCTAssertTrue(browserRevocations.isEmpty)
    }

    func testSafariCancellationRevokesTheExactPendingRequirementOnly() async throws {
        let probe = SafariRunBindingProbe()
        let harness = try await makeHarness(name: "safari-cancellation", probe: probe)
        let created = try await createRun(tool: .safariClick, using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(
            for: created.runID
        )
        let requirement = try XCTUnwrap(pendingRequirement)

        let cancelled = try await harness.runService.cancelRun(
            BurnBarRunCancelRequest(
                runID: created.runID,
                clientID: harness.clientID,
                reason: "Safari extension disconnected"
            )
        )

        let safariRevocations = await probe.safariRevocations
        let browserRevocations = await probe.browserRevocations
        let safariDispatches = await probe.safariDispatches
        XCTAssertEqual(cancelled.run?.phase, .cancelled)
        XCTAssertEqual(safariRevocations, [requirement])
        XCTAssertTrue(browserRevocations.isEmpty)
        XCTAssertTrue(safariDispatches.isEmpty)
    }

    func testSafariDispatchErrorFailsRunAndRevokesTheExactRequirement() async throws {
        let probe = SafariRunBindingProbe()
        let harness = try await makeHarness(name: "safari-dispatch-error", probe: probe)
        let created = try await createRun(tool: .safariExtract, using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(
            for: created.runID
        )
        let requirement = try XCTUnwrap(pendingRequirement)
        await probe.allowSafari(requirement)
        await probe.failNextSafariDispatch()

        let resumed = try await harness.runService.resumeComputerUseRun(
            requirement.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation
        )

        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(
                runID: requirement.runID,
                clientID: harness.clientID
            )
        )
        let safariDispatches = await probe.safariDispatches
        let safariRevocations = await probe.safariRevocations
        let browserDispatches = await probe.browserDispatches
        let browserRevocations = await probe.browserRevocations
        XCTAssertTrue(resumed)
        XCTAssertEqual(detail.run?.phase, .failed)
        XCTAssertEqual(safariDispatches, [requirement])
        XCTAssertEqual(safariRevocations, [requirement])
        XCTAssertTrue(browserDispatches.isEmpty)
        XCTAssertTrue(browserRevocations.isEmpty)
    }

    func testInterruptedSafariActionRevokesExactRequirementWithoutLegacyFallback() async throws {
        let root = temporaryRoot(name: "safari-interrupted-restore")
        let firstProbe = SafariRunBindingProbe()
        let first = try await makeHarness(
            name: "safari-interrupted-first",
            probe: firstProbe,
            root: root
        )
        let created = try await createRun(tool: .safariExtract, using: first)
        let pendingRequirement = await first.runService.computerUseRequirement(
            for: created.runID
        )
        let requirement = try XCTUnwrap(pendingRequirement)
        try await persistInterruptedSafariCheckpoint(
            requirement: requirement,
            harness: first
        )

        let restartedProbe = SafariRunBindingProbe()
        let restarted = try await makeHarness(
            name: "safari-interrupted-second",
            probe: restartedProbe,
            root: root
        )
        let detail = try await restarted.runService.getRun(
            BurnBarRunGetRequest(
                runID: requirement.runID,
                clientID: restarted.clientID
            )
        )
        let legacyBridgeResponse = try await restarted.runService.executeTool(
            BurnBarToolExecutionRequest(
                clientID: restarted.clientID,
                sessionID: restarted.sessionID,
                runID: requirement.runID
            )
        )

        let safariDispatches = await restartedProbe.safariDispatches
        let safariRevocations = await restartedProbe.safariRevocations
        let browserDispatches = await restartedProbe.browserDispatches
        let browserRevocations = await restartedProbe.browserRevocations
        XCTAssertEqual(detail.run?.phase, .failed)
        XCTAssertEqual(
            detail.run?.errorMessage,
            BurnBarRunService.interruptedComputerUseMessage
        )
        XCTAssertEqual(legacyBridgeResponse.disposition, .noPendingToolCall)
        XCTAssertEqual(safariRevocations, [requirement])
        XCTAssertTrue(browserRevocations.isEmpty)
        XCTAssertTrue(safariDispatches.isEmpty)
        XCTAssertTrue(browserDispatches.isEmpty)
    }

    func testManagedBrowserRunKeepsUsingLegacyLinuxComputerUseSeam() async throws {
        let probe = SafariRunBindingProbe()
        let harness = try await makeHarness(name: "legacy-browser-seam", probe: probe)
        let created = try await createRun(tool: .browserExtract, using: harness)
        let pendingRequirement = await harness.runService.computerUseRequirement(
            for: created.runID
        )
        let requirement = try XCTUnwrap(pendingRequirement)

        let safariBindingChecks = await probe.safariBindingChecks
        XCTAssertTrue(safariBindingChecks.isEmpty)
        let browserChecks = await probe.browserBindingChecks
        XCTAssertEqual(browserChecks.count, 1)
        XCTAssertEqual(browserChecks.first?.0, requirement.runID)
        XCTAssertEqual(browserChecks.first?.1, 0)

        await probe.allowBrowser(
            runID: requirement.runID,
            generation: requirement.generation
        )
        let resumed = try await harness.runService.resumeComputerUseRun(
            requirement.runID,
            expectedCallID: requirement.invocation.callID,
            expectedGeneration: requirement.generation
        )

        let browserDispatches = await probe.browserDispatches
        let safariDispatches = await probe.safariDispatches
        let safariRevocations = await probe.safariRevocations
        XCTAssertTrue(resumed)
        XCTAssertEqual(browserDispatches, [requirement.invocation])
        let browserRevocations = await probe.browserRevocations
        XCTAssertEqual(browserRevocations.count, 1)
        XCTAssertEqual(browserRevocations.first?.0, requirement.runID)
        XCTAssertEqual(browserRevocations.first?.1, requirement.generation)
        XCTAssertTrue(safariDispatches.isEmpty)
        XCTAssertTrue(safariRevocations.isEmpty)
    }

    func testSafariDispatchRejectsMismatchedSessionCallAndRunResults() async throws {
        let invocation = safariInvocation()
        let requirement = safariRequirement(for: invocation)

        let wrongSession = try makeBareRunService(
            safariDispatcher: { requirement in
                BurnBarComputerUseBrowserDispatchResult(
                    expectedSessionID: ComputerUseSessionID("expected-session"),
                    response: Self.successResponse(
                        sessionID: "different-session",
                        invocation: requirement.invocation
                    )
                )
            }
        )
        let wrongSessionOutcome = await wrongSession.executeBrowserAction(
            invocation,
            bindingRequirement: requirement
        )
        XCTAssertFalse(wrongSessionOutcome.succeeded)
        XCTAssertEqual(
            wrongSessionOutcome.error?.message,
            "Computer Use returned a response for a different session or tool call."
        )

        let wrongCall = try makeBareRunService(
            safariDispatcher: { requirement in
                let invocation = requirement.invocation
                return BurnBarComputerUseBrowserDispatchResult(
                    expectedSessionID: ComputerUseSessionID("expected-session"),
                    response: ComputerUseInvokeResponse(
                        sessionId: "expected-session",
                        callID: "different-call",
                        status: .executed,
                        result: BurnBarToolResult(
                            callID: invocation.callID,
                            runID: invocation.runID,
                            succeeded: true,
                            output: .string("must not escape"),
                            completedAt: Date()
                        )
                    )
                )
            }
        )
        let wrongCallOutcome = await wrongCall.executeBrowserAction(
            invocation,
            bindingRequirement: requirement
        )
        XCTAssertFalse(wrongCallOutcome.succeeded)
        XCTAssertEqual(
            wrongCallOutcome.error?.message,
            "Computer Use returned a response for a different session or tool call."
        )

        let wrongRun = try makeBareRunService(
            safariDispatcher: { requirement in
                let invocation = requirement.invocation
                return BurnBarComputerUseBrowserDispatchResult(
                    expectedSessionID: ComputerUseSessionID("expected-session"),
                    response: ComputerUseInvokeResponse(
                        sessionId: "expected-session",
                        callID: invocation.callID,
                        status: .executed,
                        result: BurnBarToolResult(
                            callID: invocation.callID,
                            runID: BurnBarRunID(rawValue: "different-run"),
                            succeeded: true,
                            output: .string("must not escape"),
                            completedAt: Date()
                        )
                    )
                )
            }
        )
        let wrongRunOutcome = await wrongRun.executeBrowserAction(
            invocation,
            bindingRequirement: requirement
        )
        XCTAssertFalse(wrongRunOutcome.succeeded)
        XCTAssertEqual(
            wrongRunOutcome.error?.message,
            "Computer Use returned a Safari result for a different run or tool call."
        )
    }

    func testSafariNeverFallsThroughToLegacyBrowserDispatcherOrPlaywright() async throws {
        let legacyCalls = InvocationCounter()
        let service = try makeBareRunService(
            browserDispatcher: { invocation in
                await legacyCalls.record(invocation)
                return BurnBarComputerUseBrowserDispatchResult(
                    expectedSessionID: ComputerUseSessionID("legacy-session"),
                    response: Self.successResponse(
                        sessionID: "legacy-session",
                        invocation: invocation
                    )
                )
            }
        )
        let invocation = safariInvocation()
        let requirement = safariRequirement(for: invocation)

        let outcome = await service.executeBrowserAction(
            invocation,
            bindingRequirement: requirement
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(
            outcome.error?.message,
            "Safari Computer Use is unavailable because its dedicated dispatcher is not installed."
        )
        let recordedLegacyCalls = await legacyCalls.invocations
        XCTAssertTrue(recordedLegacyCalls.isEmpty)
    }

    func testSafariHandoffProjectsRunningThenTerminalExactOwnedIdentity() async throws {
        let probe = SafariRunBindingProbe()
        let supervisor = SafariHandoffSupervisorFake()
        let harness = try await makeHarness(
            name: "completed-safari-handoff",
            probe: probe,
            handoffSupervisor: supervisor
        )
        let runID = BurnBarRunID(rawValue: "safari-handoff-terminal")
        let packageDirectory = harness.root
            .appendingPathComponent("handoffs/\(runID.rawValue)")
        let launchedAt = Date(timeIntervalSince1970: 1_786_345_678)
        let packageIdentity =
            SafariHandoffProcessSupervisor.FilesystemIdentity(
                device: 41,
                inode: 73
            )
        await supervisor.seed(
            .running(
                runID: runID,
                packageDirectory: packageDirectory,
                launchedAt: launchedAt
            )
        )

        let recorded = try await harness.runService.recordRunningSafariHandoff(
            runID: runID,
            clientID: harness.clientID,
            sessionID: harness.sessionID,
            targetHarness: "codex",
            packageDirectory: packageDirectory,
            packageIdentity: packageIdentity,
            launchedAt: launchedAt
        )

        XCTAssertEqual(recorded.runID, runID)
        XCTAssertEqual(recorded.clientID, harness.clientID)
        XCTAssertEqual(recorded.sessionID, harness.sessionID)
        XCTAssertEqual(recorded.phase, .waitingOnCompanion)
        XCTAssertEqual(recorded.modelID, "cli:codex")

        let exactPoll = try await harness.runService.pollRuns(
            BurnBarRunPollRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                runID: runID
            )
        )
        XCTAssertEqual(exactPoll.runs, [recorded])
        XCTAssertTrue(exactPoll.approvals.isEmpty)
        XCTAssertTrue(exactPoll.pendingToolCalls.isEmpty)

        let list = try await harness.runService.listRuns(
            BurnBarRunListRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID
            )
        )
        XCTAssertTrue(list.runs.contains(recorded))
        let detail = try await harness.runService.getRun(
            BurnBarRunGetRequest(
                runID: runID,
                clientID: harness.clientID,
                sessionID: harness.sessionID
            )
        )
        XCTAssertEqual(detail.run, recorded)

        let completedAt = launchedAt.addingTimeInterval(3)
        await supervisor.seed(
            .completed(
                runID: runID,
                packageDirectory: packageDirectory,
                launchedAt: launchedAt,
                completedAt: completedAt
            )
        )
        let completedPoll = try await harness.runService.pollRuns(
            BurnBarRunPollRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                runID: runID
            )
        )
        XCTAssertEqual(completedPoll.runs.first?.phase, .completed)
        XCTAssertEqual(completedPoll.runs.first?.updatedAt, completedAt)
        let terminalEvents = try await harness.runJournal.events(for: runID)
            .filter { $0.kind == .runCompleted }
        XCTAssertEqual(terminalEvents.count, 1)

        let exactCancellation = try await harness.runService.cancelSafariRun(
            runID,
            clientID: harness.clientID,
            sessionID: harness.sessionID,
            reason: "terminal hand-off already launched"
        )
        XCTAssertTrue(
            exactCancellation,
            "Cancelling a terminal external projection is an idempotent success."
        )

        let otherClientID = BurnBarClientID(rawValue: "safari-extension:other-session")
        let otherSessionID = BurnBarSessionID(rawValue: "other-session")
        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: otherClientID,
                sessionID: otherSessionID,
                clientName: "Other Safari Extension",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        do {
            _ = try await harness.runService.getRun(
                BurnBarRunGetRequest(
                    runID: runID,
                    clientID: otherClientID,
                    sessionID: otherSessionID
                )
            )
            XCTFail("A different Safari client must not read this hand-off run.")
        } catch let error as BurnBarRunServiceError {
            guard case .runNotFound(let rejectedRunID) = error else {
                return XCTFail("Unexpected cross-client get error: \(error)")
            }
            XCTAssertEqual(rejectedRunID, runID)
        }
        do {
            _ = try await harness.runService.pollRuns(
                BurnBarRunPollRequest(
                    clientID: otherClientID,
                    sessionID: otherSessionID,
                    runID: runID
                )
            )
            XCTFail("A different Safari session must not poll this hand-off run.")
        } catch let error as BurnBarRunServiceError {
            guard case .runNotFound(let rejectedRunID) = error else {
                return XCTFail("Unexpected cross-session poll error: \(error)")
            }
            XCTAssertEqual(rejectedRunID, runID)
        }
        let crossSessionCancellation = try await harness.runService.cancelSafariRun(
            runID,
            clientID: otherClientID,
            sessionID: otherSessionID,
            reason: "cross-session cancellation attempt"
        )
        XCTAssertFalse(crossSessionCancellation)

        do {
            _ = try await harness.runService.recordRunningSafariHandoff(
                runID: runID,
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                targetHarness: "codex",
                packageDirectory: packageDirectory,
                packageIdentity: packageIdentity,
                launchedAt: launchedAt
            )
            XCTFail("The same hand-off run identity must never be reused.")
        } catch let error as BurnBarRunServiceError {
            guard case .externalRunAlreadyExists(let duplicateRunID) = error else {
                return XCTFail("Unexpected duplicate identity error: \(error)")
            }
            XCTAssertEqual(duplicateRunID, runID)
        }
    }

    func testSafariHandoffGenericSurfacesRequireExactCurrentSession() async throws {
        let probe = SafariRunBindingProbe()
        let supervisor = SafariHandoffSupervisorFake()
        let harness = try await makeHarness(
            name: "safari-handoff-session-boundaries",
            probe: probe,
            handoffSupervisor: supervisor
        )
        let runID = BurnBarRunID(rawValue: "safari-handoff-session-boundaries")
        let packageDirectory = harness.root
            .appendingPathComponent("handoffs/\(runID.rawValue)")
        let launchedAt = Date(timeIntervalSince1970: 1_786_345_679)
        let packageIdentity =
            SafariHandoffProcessSupervisor.FilesystemIdentity(
                device: 43,
                inode: 79
            )
        await supervisor.seed(
            .running(
                runID: runID,
                packageDirectory: packageDirectory,
                launchedAt: launchedAt
            )
        )
        let recorded = try await harness.runService.recordRunningSafariHandoff(
            runID: runID,
            clientID: harness.clientID,
            sessionID: harness.sessionID,
            targetHarness: "codex",
            packageDirectory: packageDirectory,
            packageIdentity: packageIdentity,
            launchedAt: launchedAt
        )

        let legacyList = try await harness.runService.listRuns(
            BurnBarRunListRequest(clientID: harness.clientID)
        )
        XCTAssertFalse(legacyList.runs.contains(recorded))
        await assertRunNotFound(runID) {
            _ = try await harness.runService.getRun(
                BurnBarRunGetRequest(
                    runID: runID,
                    clientID: harness.clientID
                )
            )
        }
        await assertRunNotFound(runID) {
            _ = try await harness.runService.cancelRun(
                BurnBarRunCancelRequest(
                    runID: runID,
                    clientID: harness.clientID,
                    reason: "missing session must not stop the CLI"
                )
            )
        }
        let stateAfterMissingSession = await supervisor.observation(
            for: runID
        )?.state
        XCTAssertEqual(stateAfterMissingSession, .running)

        let exactList = try await harness.runService.listRuns(
            BurnBarRunListRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID
            )
        )
        XCTAssertTrue(exactList.runs.contains(recorded))
        let exactGet = try await harness.runService.getRun(
            BurnBarRunGetRequest(
                runID: runID,
                clientID: harness.clientID,
                sessionID: harness.sessionID
            )
        )
        XCTAssertEqual(exactGet.run, recorded)

        let replacementSessionID = BurnBarSessionID(
            rawValue: "replacement-safari-session"
        )
        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: harness.clientID,
                sessionID: replacementSessionID,
                clientName: "Reattached Safari Extension",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        let replacementList = try await harness.runService.listRuns(
            BurnBarRunListRequest(
                clientID: harness.clientID,
                sessionID: replacementSessionID
            )
        )
        XCTAssertFalse(replacementList.runs.contains(recorded))
        await assertRunNotFound(runID) {
            _ = try await harness.runService.getRun(
                BurnBarRunGetRequest(
                    runID: runID,
                    clientID: harness.clientID,
                    sessionID: replacementSessionID
                )
            )
        }
        await assertRunNotFound(runID) {
            _ = try await harness.runService.getRun(
                BurnBarRunGetRequest(
                    runID: runID,
                    clientID: harness.clientID,
                    sessionID: harness.sessionID
                )
            )
        }
        await assertRunNotFound(runID) {
            _ = try await harness.runService.cancelRun(
                BurnBarRunCancelRequest(
                    runID: runID,
                    clientID: harness.clientID,
                    sessionID: replacementSessionID,
                    reason: "replacement session must not stop the CLI"
                )
            )
        }
        await assertRunNotFound(runID) {
            _ = try await harness.runService.pollRuns(
                BurnBarRunPollRequest(
                    clientID: harness.clientID,
                    sessionID: replacementSessionID,
                    runID: runID
                )
            )
        }
        let replacementStop = try await harness.runService.cancelSafariRun(
            runID,
            clientID: harness.clientID,
            sessionID: replacementSessionID,
            reason: "replacement session must not stop the CLI"
        )
        XCTAssertFalse(replacementStop)
        let stateAfterReplacementSession = await supervisor.observation(
            for: runID
        )?.state
        XCTAssertEqual(stateAfterReplacementSession, .running)

        _ = await harness.clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                clientName: "Original Safari Extension",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        let cancelled = try await harness.runService.cancelRun(
            BurnBarRunCancelRequest(
                runID: runID,
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                reason: "exact session cancellation"
            )
        )
        XCTAssertEqual(cancelled.run?.phase, .cancelled)
        let stateAfterExactCancellation = await supervisor.observation(
            for: runID
        )?.state
        XCTAssertEqual(stateAfterExactCancellation, .cancelled)
    }

    func testSafariHandoffJournalPersistsExactFilesystemIdentityAsDecimalStrings()
        async throws {
        let harness = try await makeHarness(
            name: "safari-handoff-identity-journal",
            probe: SafariRunBindingProbe()
        )
        let runID = BurnBarRunID(
            rawValue: "safari-handoff-identity-journal"
        )
        let packageDirectory = harness.root
            .appendingPathComponent("handoffs/\(runID.rawValue)")
        let packageIdentity =
            SafariHandoffProcessSupervisor.FilesystemIdentity(
                device: 9_007_199_254_740_993,
                inode: 18_446_744_073_709_551_599
            )

        _ = try await harness.runService.recordRunningSafariHandoff(
            runID: runID,
            clientID: harness.clientID,
            sessionID: harness.sessionID,
            targetHarness: "codex",
            packageDirectory: packageDirectory,
            packageIdentity: packageIdentity,
            launchedAt: Date(timeIntervalSince1970: 1_786_345_680)
        )

        let events = try await harness.runJournal.events(for: runID)
        let created = try XCTUnwrap(
            events.first { $0.kind == .runCreated }
        )
        let payload = try XCTUnwrap(created.payload?.objectValue())
        XCTAssertEqual(
            payload.stringValue(forKey: "packageDevice"),
            "9007199254740993"
        )
        XCTAssertEqual(
            payload.stringValue(forKey: "packageInode"),
            "18446744073709551599"
        )
        XCTAssertNil(payload["packageDirectory"])
        XCTAssertNil(payload["packagePath"])

        let journal = try String(
            contentsOf: harness.root.appendingPathComponent(
                "run-journal.jsonl"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(journal.contains(packageDirectory.path))
    }

    func testSafariHandoffRestartPassesExactJournaledIdentityUnderCurrentCanonicalRoot()
        async throws {
        let root = temporaryRoot(name: "safari-handoff-identity-restore")
        let first = try await makeHarness(
            name: "safari-handoff-identity-restore-first",
            probe: SafariRunBindingProbe(),
            root: root
        )
        let runID = BurnBarRunID(
            rawValue: "safari-handoff-identity-restore"
        )
        let launchedAt = Date(timeIntervalSince1970: 1_786_345_681)
        let packageIdentity =
            SafariHandoffProcessSupervisor.FilesystemIdentity(
                device: 9_007_199_254_740_995,
                inode: 18_446_744_073_709_551_597
            )
        try await appendSafariHandoffCreatedEvent(
            runID: runID,
            clientID: first.clientID,
            sessionID: first.sessionID,
            targetHarness: "codex",
            packageIdentity: packageIdentity,
            launchedAt: launchedAt,
            journal: first.runJournal
        )

        let alternateHandoffRoot = root.appendingPathComponent(
            "replacement-handoffs",
            isDirectory: true
        )
        let replacementPackage = alternateHandoffRoot.appendingPathComponent(
            runID.rawValue,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementPackage,
            withIntermediateDirectories: true
        )
        let sentinel = replacementPackage.appendingPathComponent(
            "replacement-sentinel"
        )
        try Data("preserve replacement".utf8).write(to: sentinel)
        let supervisor = SafariHandoffSupervisorFake()
        let restarted = try await makeHarness(
            name: "safari-handoff-identity-restore-second",
            probe: SafariRunBindingProbe(),
            root: root,
            handoffSupervisor: supervisor,
            safariHandoffRootURL: alternateHandoffRoot
        )

        _ = try await restarted.runService.getRun(
            BurnBarRunGetRequest(
                runID: runID,
                clientID: restarted.clientID,
                sessionID: restarted.sessionID
            )
        )

        let registrations = await supervisor.interruptedRegistrations
        XCTAssertEqual(registrations.count, 1)
        XCTAssertEqual(registrations.first?.runID, runID)
        XCTAssertEqual(registrations.first?.targetHarness, "codex")
        XCTAssertEqual(
            registrations.first?.packageDirectory.standardizedFileURL,
            replacementPackage.standardizedFileURL
        )
        XCTAssertEqual(
            registrations.first?.expectedPackageIdentity,
            packageIdentity
        )
        XCTAssertEqual(registrations.first?.launchedAt, launchedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        let discardedRunIDs = await supervisor.discardedRunIDs
        XCTAssertTrue(discardedRunIDs.isEmpty)
    }

    func testSafariHandoffRestartRejectsInvalidIdentityBeforePackageAccess()
        async throws {
        let invalidIdentities: [
            (
                name: String,
                device: BurnBarJSONValue?,
                inode: BurnBarJSONValue?
            )
        ] = [
            ("missing-device", nil, .string("73")),
            ("missing-inode", .string("41"), nil),
            ("numeric-device", .number(41), .string("73")),
            ("leading-zero-device", .string("041"), .string("73")),
            ("whitespace-inode", .string("41"), .string("73 ")),
            ("negative-device", .string("-1"), .string("73")),
            (
                "overflow-inode",
                .string("41"),
                .string("18446744073709551616")
            )
        ]

        for invalid in invalidIdentities {
            let root = temporaryRoot(
                name: "safari-handoff-invalid-identity-\(invalid.name)"
            )
            let first = try await makeHarness(
                name: "\(invalid.name)-first",
                probe: SafariRunBindingProbe(),
                root: root
            )
            let runID = BurnBarRunID(
                rawValue: "safari-handoff-invalid-\(invalid.name)"
            )
            try await appendSafariHandoffCreatedEvent(
                runID: runID,
                clientID: first.clientID,
                sessionID: first.sessionID,
                targetHarness: "codex",
                packageDevice: invalid.device,
                packageInode: invalid.inode,
                launchedAt: Date(timeIntervalSince1970: 1_786_345_682),
                journal: first.runJournal
            )

            let packageDirectory = root
                .appendingPathComponent("handoffs", isDirectory: true)
                .appendingPathComponent(runID.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(
                at: packageDirectory,
                withIntermediateDirectories: true
            )
            let sentinel = packageDirectory.appendingPathComponent(
                "must-not-be-touched"
            )
            try Data(invalid.name.utf8).write(to: sentinel)
            let supervisor = SafariHandoffSupervisorFake()
            let restarted = try await makeHarness(
                name: "\(invalid.name)-second",
                probe: SafariRunBindingProbe(),
                root: root,
                handoffSupervisor: supervisor
            )

            await assertRunNotFound(runID) {
                _ = try await restarted.runService.getRun(
                    BurnBarRunGetRequest(
                        runID: runID,
                        clientID: restarted.clientID,
                        sessionID: restarted.sessionID
                    )
                )
            }
            let registrations = await supervisor.interruptedRegistrations
            let discardedRunIDs = await supervisor.discardedRunIDs
            XCTAssertTrue(registrations.isEmpty, invalid.name)
            XCTAssertTrue(discardedRunIDs.isEmpty, invalid.name)
            XCTAssertEqual(
                try Data(contentsOf: sentinel),
                Data(invalid.name.utf8),
                invalid.name
            )
        }
    }

    private func assertRunNotFound(
        _ expectedRunID: BurnBarRunID,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected run \(expectedRunID.rawValue) to be hidden.")
        } catch let error as BurnBarRunServiceError {
            guard case .runNotFound(let actualRunID) = error else {
                return XCTFail("Unexpected run lookup error: \(error)")
            }
            XCTAssertEqual(actualRunID, expectedRunID)
        } catch {
            XCTFail("Unexpected run lookup error: \(error)")
        }
    }

    private func makeHarness(
        name: String,
        probe: SafariRunBindingProbe,
        root: URL? = nil,
        handoffSupervisor: any SafariHandoffProcessSupervising =
            SafariHandoffSupervisorFake(),
        safariHandoffRootURL: URL? = nil
    ) async throws -> SafariRunServiceHarness {
        let root = root ?? temporaryRoot(name: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: root.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
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

        let clientID = BurnBarClientID(rawValue: "safari-extension:safari-session")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let clientRegistry = BurnBarClientRegistry(
            logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
        )
        _ = await clientRegistry.attach(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Safari Extension",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )
        let runJournal = BurnBarRunJournal(
            fileURL: root.appendingPathComponent("run-journal.jsonl"),
            checkpointsDirectoryURL: root.appendingPathComponent(
                "run-checkpoints",
                isDirectory: true
            ),
            logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
        )
        let runService = BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: root.appendingPathComponent("usage.jsonl"),
                logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
            ),
            clientRegistry: clientRegistry,
            providerExecutor: SafariRunBindingProviderExecutor(),
            runJournal: runJournal,
            computerUseBrowserDispatcher: { invocation in
                await probe.dispatchBrowser(invocation)
            },
            computerUseRunBindingChecker: { runID, generation in
                await probe.checkBrowser(runID: runID, generation: generation)
            },
            computerUseRunRevoker: { runID, generation in
                await probe.revokeBrowser(runID: runID, generation: generation)
            },
            safariComputerUseRunDispatcher: { requirement in
                try await probe.dispatchSafari(requirement)
            },
            safariComputerUseRunBindingChecker: { requirement in
                await probe.checkSafari(requirement)
            },
            safariComputerUseRunRevoker: { requirement in
                await probe.revokeSafari(requirement)
            },
            safariHandoffSupervisor: handoffSupervisor,
            safariHandoffRootURL: safariHandoffRootURL
                ?? root.appendingPathComponent(
                    "handoffs",
                    isDirectory: true
                ),
            logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
        )
        return SafariRunServiceHarness(
            root: root,
            clientID: clientID,
            sessionID: sessionID,
            clientRegistry: clientRegistry,
            runService: runService,
            runJournal: runJournal
        )
    }

    private func appendSafariHandoffCreatedEvent(
        runID: BurnBarRunID,
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        targetHarness: String,
        packageIdentity: SafariHandoffProcessSupervisor.FilesystemIdentity,
        launchedAt: Date,
        journal: BurnBarRunJournal
    ) async throws {
        try await appendSafariHandoffCreatedEvent(
            runID: runID,
            clientID: clientID,
            sessionID: sessionID,
            targetHarness: targetHarness,
            packageDevice: .string(String(packageIdentity.device)),
            packageInode: .string(String(packageIdentity.inode)),
            launchedAt: launchedAt,
            journal: journal
        )
    }

    private func appendSafariHandoffCreatedEvent(
        runID: BurnBarRunID,
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        targetHarness: String,
        packageDevice: BurnBarJSONValue?,
        packageInode: BurnBarJSONValue?,
        launchedAt: Date,
        journal: BurnBarRunJournal
    ) async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        var payload: [String: BurnBarJSONValue] = [
            "surface": .string("safari_extension"),
            "kind": .string("cli_handoff"),
            "targetHarness": .string(targetHarness),
            "clientID": .string(clientID.rawValue),
            "sessionID": .string(sessionID.rawValue),
            "launchedAt": .string(formatter.string(from: launchedAt))
        ]
        payload["packageDevice"] = packageDevice
        payload["packageInode"] = packageInode
        try await journal.append(
            BurnBarRunJournalEvent(
                runID: runID,
                kind: .runCreated,
                phase: .waitingOnCompanion,
                payload: .object(payload),
                emittedAt: launchedAt
            )
        )
    }

    private func persistInterruptedSafariCheckpoint(
        requirement: BurnBarComputerUseRunRequirement,
        harness: SafariRunServiceHarness
    ) async throws {
        let pendingCheckpoint = try await harness.runJournal.checkpoint(
            for: requirement.runID
        )
        let checkpoint = try XCTUnwrap(pendingCheckpoint)
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
                runID: checkpoint.runID,
                clientID: checkpoint.clientID,
                sessionID: checkpoint.sessionID,
                phase: .executingTool,
                modelID: checkpoint.modelID,
                originalPrompt: checkpoint.originalPrompt,
                metadata: checkpoint.metadata,
                intent: checkpoint.intent,
                planOutline: checkpoint.planOutline,
                attempt: checkpoint.attempt,
                errorMessage: nil,
                approvalRequest: nil,
                approvalResolvedForAttempt: checkpoint.approvalResolvedForAttempt,
                activeApprovalID: nil,
                pendingApprovalToolInvocation: nil,
                pendingComputerUseInvocation: nil,
                computerUseGeneration: requirement.generation,
                lastToolCall: inProgressCall,
                lastToolCallID: inProgressCall.callID,
                workflowStep: checkpoint.workflowStep,
                workflowReadContent: checkpoint.workflowReadContent,
                companionToolCompleted: checkpoint.companionToolCompleted,
                lastRecoveryDecision: checkpoint.lastRecoveryDecision,
                loopState: checkpoint.loopState,
                updatedAt: Date()
            )
        )
    }

    private func temporaryRoot(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openburnbar-safari-run-binding-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func createRun(
        tool: BurnBarToolKind,
        using harness: SafariRunServiceHarness
    ) async throws -> BurnBarRunCreateResponse {
        let arguments: BurnBarJSONValue
        if tool.isSafariComputerUse {
            arguments = .object([
                "safariSessionId": .string(harness.sessionID.rawValue),
                "selector": .string("main")
            ])
        } else {
            arguments = .object(["selector": .string("main")])
        }
        return try await harness.runService.createRun(
            BurnBarRunCreateRequest(
                clientID: harness.clientID,
                sessionID: harness.sessionID,
                prompt: "Inspect the active page",
                modelID: "glm-5",
                metadata: [
                    "toolKind": .string(tool.rawValue),
                    "toolArguments": arguments
                ]
            )
        )
    }

    private func makeBareRunService(
        browserDispatcher: BurnBarComputerUseBrowserDispatcher? = nil,
        safariDispatcher: BurnBarSafariComputerUseRunDispatcher? = nil
    ) throws -> BurnBarRunService {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openburnbar-safari-dispatch-result-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configStore = BurnBarConfigStore(
            fileURL: root.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
        )
        return BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: root.appendingPathComponent("usage.jsonl"),
                logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
            ),
            clientRegistry: BurnBarClientRegistry(
                logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
            ),
            computerUseBrowserDispatcher: browserDispatcher,
            safariComputerUseRunDispatcher: safariDispatcher,
            logger: BurnBarDaemonLogger(category: "safari-run-binding-tests")
        )
    }

    private func safariInvocation() -> BurnBarToolInvocation {
        BurnBarToolInvocation(
            callID: "safari-call",
            runID: BurnBarRunID(rawValue: "safari-run"),
            tool: .safariExtract,
            arguments: .object([
                "safariSessionId": .string("safari-session"),
                "selector": .string("main")
            ]),
            requestedBy: BurnBarClientID(rawValue: "safari-extension:safari-session"),
            requestedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
    }

    private func safariRequirement(
        for invocation: BurnBarToolInvocation
    ) -> BurnBarComputerUseRunRequirement {
        BurnBarComputerUseRunRequirement(
            runID: invocation.runID,
            clientID: invocation.requestedBy,
            sessionID: BurnBarSessionID(rawValue: "safari-session"),
            invocation: invocation,
            generation: 7
        )
    }

    private static func successResponse(
        sessionID: String,
        invocation: BurnBarToolInvocation
    ) -> ComputerUseInvokeResponse {
        ComputerUseInvokeResponse(
            sessionId: sessionID,
            callID: invocation.callID,
            status: .executed,
            result: BurnBarToolResult(
                callID: invocation.callID,
                runID: invocation.runID,
                succeeded: true,
                output: .string("ok"),
                completedAt: Date()
            )
        )
    }
}

private actor InvocationCounter {
    private(set) var invocations: [BurnBarToolInvocation] = []

    func record(_ invocation: BurnBarToolInvocation) {
        invocations.append(invocation)
    }
}

private actor SafariHandoffSupervisorFake: SafariHandoffProcessSupervising {
    struct InterruptedRegistration: Sendable, Equatable {
        let runID: BurnBarRunID
        let targetHarness: String
        let packageDirectory: URL
        let expectedPackageIdentity:
            SafariHandoffProcessSupervisor.FilesystemIdentity?
        let launchedAt: Date
    }

    private var observations:
        [BurnBarRunID: SafariHandoffProcessSupervisor.Observation] = [:]
    private(set) var interruptedRegistrations: [InterruptedRegistration] = []
    private(set) var discardedRunIDs: [BurnBarRunID] = []

    func seed(_ observation: SafariHandoffProcessSupervisor.Observation) {
        observations[observation.runID] = observation
    }

    func launch(
        _ specification: SafariHandoffProcessSupervisor.LaunchSpecification
    ) async throws -> SafariHandoffProcessSupervisor.Observation {
        let observation = SafariHandoffProcessSupervisor.Observation.running(
            runID: specification.runID,
            packageDirectory: specification.packageDirectory,
            launchedAt: Date(),
            targetHarness: specification.targetHarness
        )
        observations[specification.runID] = observation
        return observation
    }

    func observation(
        for runID: BurnBarRunID
    ) async -> SafariHandoffProcessSupervisor.Observation? {
        observations[runID]
    }

    func cancel(
        runID: BurnBarRunID
    ) async -> SafariHandoffProcessSupervisor.Observation? {
        guard let current = observations[runID] else { return nil }
        let cancelled = SafariHandoffProcessSupervisor.Observation(
            runID: runID,
            targetHarness: current.targetHarness,
            state: .cancelled,
            launchedAt: current.launchedAt,
            observedAt: Date(),
            completedAt: Date(),
            terminationReason: .cancelled,
            exitStatus: 15,
            stdoutBytes: 0,
            stderrBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            failure: nil,
            packageDirectory: current.packageDirectory
        )
        observations[runID] = cancelled
        return cancelled
    }

    func registerInterruptedRun(
        runID: BurnBarRunID,
        targetHarness: String,
        packageDirectory: URL,
        expectedPackageIdentity:
            SafariHandoffProcessSupervisor.FilesystemIdentity?,
        launchedAt: Date
    ) async -> SafariHandoffProcessSupervisor.Observation {
        interruptedRegistrations.append(
            InterruptedRegistration(
                runID: runID,
                targetHarness: targetHarness,
                packageDirectory: packageDirectory,
                expectedPackageIdentity: expectedPackageIdentity,
                launchedAt: launchedAt
            )
        )
        if let existing = observations[runID] { return existing }
        let interrupted = SafariHandoffProcessSupervisor.Observation(
            runID: runID,
            targetHarness: targetHarness,
            state: .interrupted,
            launchedAt: launchedAt,
            observedAt: Date(),
            completedAt: Date(),
            terminationReason: .interrupted,
            exitStatus: nil,
            stdoutBytes: 0,
            stderrBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            failure: .interrupted,
            packageDirectory: packageDirectory
        )
        observations[runID] = interrupted
        return interrupted
    }

    func cleanupEligiblePackages(now: Date) async {}

    func discard(runID: BurnBarRunID) async {
        discardedRunIDs.append(runID)
        observations.removeValue(forKey: runID)
    }

    func shutdownAll() async {
        for runID in observations.keys
            where observations[runID]?.state == .running {
            _ = await cancel(runID: runID)
        }
    }
}

private extension SafariHandoffProcessSupervisor.Observation {
    static func running(
        runID: BurnBarRunID,
        packageDirectory: URL,
        launchedAt: Date,
        targetHarness: String = "codex"
    ) -> Self {
        Self(
            runID: runID,
            targetHarness: targetHarness,
            state: .running,
            launchedAt: launchedAt,
            observedAt: launchedAt,
            completedAt: nil,
            terminationReason: nil,
            exitStatus: nil,
            stdoutBytes: 0,
            stderrBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            failure: nil,
            packageDirectory: packageDirectory
        )
    }

    static func completed(
        runID: BurnBarRunID,
        packageDirectory: URL,
        launchedAt: Date,
        completedAt: Date,
        targetHarness: String = "codex"
    ) -> Self {
        Self(
            runID: runID,
            targetHarness: targetHarness,
            state: .completed,
            launchedAt: launchedAt,
            observedAt: completedAt,
            completedAt: completedAt,
            terminationReason: .exit,
            exitStatus: 0,
            stdoutBytes: 0,
            stderrBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            failure: nil,
            packageDirectory: packageDirectory
        )
    }
}

private struct SafariRunServiceHarness {
    let root: URL
    let clientID: BurnBarClientID
    let sessionID: BurnBarSessionID
    let clientRegistry: BurnBarClientRegistry
    let runService: BurnBarRunService
    let runJournal: BurnBarRunJournal
}

private struct SafariRunBindingProviderExecutor: BurnBarProviderExecuting {
    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        BurnBarProviderExecutionResult(
            outputText: #"{"action":"complete","rationale":"Safari binding test completed.","message":"done"}"#,
            inputTokens: 1,
            outputTokens: 1,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }
}

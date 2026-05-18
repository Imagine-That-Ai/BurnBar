import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class ComputerUseRunCoordinatorTests: XCTestCase {
    func testUnknownSessionFailsClosed() async throws {
        let coordinator = makeCoordinator()
        let response = await coordinator.invoke(
            sessionId: ComputerUseSessionID("missing"),
            invocation: invocation(tool: .macInspectAccessibility, arguments: .object([:])),
            scopeContext: ComputerUseScopeContext(),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capability(for: makeState(sessionId: ComputerUseSessionID("missing")))
        )

        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.denyReason, "unknown_session")
    }

    func testGateDenialAppendsAuditAndIncrementsRejectedCount() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let coordinator = makeCoordinator()
        let manifest = manifest(sessionId: sessionId, mode: .system, trustMode: .manual)
        _ = try await coordinator.startSession(manifest: manifest)

        let response = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(tool: .macInputClick, arguments: macClickArguments()),
            scopeContext: ComputerUseScopeContext(bundleId: "com.apple.finder"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capability(
                for: makeState(sessionId: sessionId, manifest: manifest),
                entitlement: .inactive,
                accessibilityTrusted: true
            )
        )

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.denyReason, ComputerUseDenyReason.entitlement.rawValue)
        XCTAssertEqual(response.auditEntryIndex, 0)
        XCTAssertNotNil(response.auditHeadHashHex)

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsRejected, 1)
        XCTAssertEqual(state.actionsExecuted, 0)
    }

    func testReadOnlyInspectSkipsApprovalAndDispatches() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let recorder = InspectRecorder()
        let coordinator = makeCoordinator(
            macInspectDispatcher: { _, action in
                recorder.record(action)
                return .object(["role": .string("AXWindow")])
            }
        )
        let manifest = manifest(sessionId: sessionId, mode: .system, trustMode: .manual)
        _ = try await coordinator.startSession(manifest: manifest)

        let response = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(
                tool: .macInspectAccessibility,
                arguments: .object(["displayX": .number(12), "displayY": .number(34)])
            ),
            scopeContext: ComputerUseScopeContext(bundleId: "com.apple.finder"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capability(
                for: makeState(sessionId: sessionId, manifest: manifest),
                accessibilityTrusted: true
            )
        )

        XCTAssertEqual(response.status, .executed)
        XCTAssertEqual(recorder.last?.displayX, 12)
        XCTAssertEqual(recorder.last?.displayY, 34)
        XCTAssertEqual(response.result?.succeeded, true)

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsExecuted, 1)
        XCTAssertEqual(state.actionsRejected, 0)
    }

    func testMacInputApprovalApproveDispatchesAndAudits() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let approvals = ApprovalRecorder(decision: .approve)
        let inputs = MacInputRecorder()
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            macInputDispatcher: { _, action in
                inputs.record(action)
                return .object(["posted": .bool(true)])
            }
        )
        let manifest = manifest(sessionId: sessionId, mode: .system, trustMode: .manual)
        _ = try await coordinator.startSession(manifest: manifest)

        let response = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(tool: .macInputClick, arguments: macClickArguments()),
            scopeContext: ComputerUseScopeContext(bundleId: "com.apple.finder"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capability(
                for: makeState(sessionId: sessionId, manifest: manifest),
                accessibilityTrusted: true
            )
        )

        XCTAssertEqual(response.status, .executed)
        XCTAssertEqual(approvals.requests.count, 1)
        XCTAssertEqual(inputs.last?.displayX, 100)
        XCTAssertEqual(inputs.last?.displayY, 200)
        XCTAssertEqual(response.result?.succeeded, true)
        XCTAssertNotNil(response.approvalId)
        XCTAssertEqual(response.auditEntryIndex, 0)

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsExecuted, 1)
        XCTAssertEqual(state.actionsRejected, 0)
    }

    func testMacInputApprovalRejectDoesNotDispatch() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let approvals = ApprovalRecorder(decision: .reject)
        let inputs = MacInputRecorder()
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            macInputDispatcher: { _, action in
                inputs.record(action)
                return .object(["posted": .bool(true)])
            }
        )
        let manifest = manifest(sessionId: sessionId, mode: .system, trustMode: .manual)
        _ = try await coordinator.startSession(manifest: manifest)

        let response = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(tool: .macInputClick, arguments: macClickArguments()),
            scopeContext: ComputerUseScopeContext(bundleId: "com.apple.finder"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capability(
                for: makeState(sessionId: sessionId, manifest: manifest),
                accessibilityTrusted: true
            )
        )

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.denyReason, ComputerUseDenyReason.userRejected.rawValue)
        XCTAssertEqual(approvals.requests.count, 1)
        XCTAssertNil(inputs.last)

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsExecuted, 0)
        XCTAssertEqual(state.actionsRejected, 1)
    }

    func testBrowserApprovalApproveDispatchesAndAudits() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let auditBaseDirectory = testAuditBaseDirectory()
        let approvals = ApprovalRecorder(decision: .approve)
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            auditBaseDirectory: auditBaseDirectory
        )
        let manifest = manifest(sessionId: sessionId, mode: .browser, trustMode: .manual)
        let driver = try await makeEchoDriver(sessionId: sessionId, expectedRequestCount: 2)
        _ = try await coordinator.startSession(manifest: manifest, playwrightDriver: driver)

        let response = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(
                tool: .browserGoto,
                arguments: .object([
                    "url": .string("https://example.com/dashboard"),
                    "timeoutMillis": .number(5_000)
                ])
            ),
            scopeContext: ComputerUseScopeContext(url: "https://example.com/dashboard"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capability(for: makeState(sessionId: sessionId, manifest: manifest))
        )

        XCTAssertEqual(response.status, .executed)
        XCTAssertNotNil(response.approvalId)
        XCTAssertEqual(response.auditEntryIndex, 0)
        XCTAssertNotNil(response.auditHeadHashHex)
        XCTAssertEqual(approvals.requests.count, 1)
        XCTAssertEqual(approvals.requests.first?.toolKind, BurnBarToolKind.browserGoto.rawValue)
        XCTAssertEqual(approvals.requests.first?.trustMode, ComputerUseTrustMode.manual.rawValue)
        XCTAssertEqual(approvals.requests.first?.beforeScreenshotMimeType, "image/png")
        XCTAssertNotNil(approvals.requests.first?.beforeScreenshotPNGBase64)
        XCTAssertGreaterThan(approvals.requests.first?.beforeScreenshotSizeBytes ?? 0, 0)
        XCTAssertNotNil(approvals.requests.first?.beforeScreenshotBlake3)
        XCTAssertEqual(response.result?.succeeded, true)

        let entry = try firstAuditEntry(baseDirectory: auditBaseDirectory, sessionId: sessionId)
        XCTAssertEqual(entry.actionKind, "browser.goto")
        XCTAssertEqual(entry.approvedBy, .mac)
        XCTAssertEqual(entry.approvalId, response.approvalId)
        XCTAssertNil(entry.denyReason)

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsExecuted, 1)
        XCTAssertEqual(state.actionsRejected, 0)
    }

    func testBrowserApprovalRejectDoesNotDispatchAndAuditsDenial() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let auditBaseDirectory = testAuditBaseDirectory()
        let approvals = ApprovalRecorder(decision: .reject)
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            auditBaseDirectory: auditBaseDirectory
        )
        let manifest = manifest(sessionId: sessionId, mode: .browser, trustMode: .manual)
        _ = try await coordinator.startSession(manifest: manifest)

        let response = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(
                tool: .browserClick,
                arguments: .object(["selector": .string("#danger")])
            ),
            scopeContext: ComputerUseScopeContext(url: "https://example.com/danger"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capability(for: makeState(sessionId: sessionId, manifest: manifest))
        )

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.denyReason, ComputerUseDenyReason.userRejected.rawValue)
        XCTAssertEqual(approvals.requests.count, 1)
        XCTAssertEqual(response.auditEntryIndex, 0)

        let entry = try firstAuditEntry(baseDirectory: auditBaseDirectory, sessionId: sessionId)
        XCTAssertEqual(entry.actionKind, "browser.click")
        XCTAssertEqual(entry.approvedBy, .denied)
        XCTAssertEqual(entry.denyReason, ComputerUseDenyReason.userRejected.rawValue)

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsExecuted, 0)
        XCTAssertEqual(state.actionsRejected, 1)
    }

    func testBrowserScopeViolationAuditsWithoutApprovalOrDispatch() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let auditBaseDirectory = testAuditBaseDirectory()
        let approvals = ApprovalRecorder(decision: .approve)
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            auditBaseDirectory: auditBaseDirectory
        )
        let manifest = manifest(sessionId: sessionId, mode: .browser, trustMode: .manual)
        _ = try await coordinator.startSession(manifest: manifest)
        let denyRule = ComputerUseScopeRuleID(rawValue: "deny-bank")

        let response = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(
                tool: .browserGoto,
                arguments: .object(["url": .string("https://bank.example")])
            ),
            scopeContext: ComputerUseScopeContext(url: "https://bank.example"),
            scopeOutcome: .denied(rule: denyRule),
            accessibilityDeny: nil,
            capability: capability(for: makeState(sessionId: sessionId, manifest: manifest))
        )

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.denyReason, ComputerUseDenyReason.scopeDenied.rawValue)
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertEqual(response.auditEntryIndex, 0)

        let entry = try firstAuditEntry(baseDirectory: auditBaseDirectory, sessionId: sessionId)
        XCTAssertEqual(entry.actionKind, "browser.goto")
        XCTAssertEqual(entry.approvedBy, .denied)
        XCTAssertEqual(entry.scopeRuleId, denyRule.rawValue)
        XCTAssertEqual(entry.denyReason, ComputerUseDenyReason.scopeDenied.rawValue)

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsExecuted, 0)
        XCTAssertEqual(state.actionsRejected, 1)
    }

    func testBrowserTrustedScopeDispatchesWithoutApprovalAndAuditsTrustedScope() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let auditBaseDirectory = testAuditBaseDirectory()
        let approvals = ApprovalRecorder(decision: .approve)
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            auditBaseDirectory: auditBaseDirectory
        )
        let manifest = manifest(sessionId: sessionId, mode: .browser, trustMode: .trusted)
        let driver = try await makeEchoDriver(sessionId: sessionId, expectedRequestCount: 1)
        _ = try await coordinator.startSession(manifest: manifest, playwrightDriver: driver)
        let allowRule = ComputerUseScopeRuleID(rawValue: "allow-example")

        let response = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(
                tool: .browserClick,
                arguments: .object(["selector": .string("#safe")])
            ),
            scopeContext: ComputerUseScopeContext(url: "https://example.com/app"),
            scopeOutcome: .allowed(rule: allowRule),
            accessibilityDeny: nil,
            capability: capability(for: makeState(sessionId: sessionId, manifest: manifest))
        )

        XCTAssertEqual(response.status, .executed)
        XCTAssertNil(response.approvalId)
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertEqual(response.auditEntryIndex, 0)
        XCTAssertNotNil(response.auditHeadHashHex)

        let entry = try firstAuditEntry(baseDirectory: auditBaseDirectory, sessionId: sessionId)
        XCTAssertEqual(entry.actionKind, "browser.click")
        XCTAssertEqual(entry.approvedBy, .trustedScope)
        XCTAssertEqual(entry.scopeRuleId, allowRule.rawValue)
        XCTAssertNil(entry.approvalId)
        XCTAssertNil(entry.denyReason)

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsExecuted, 1)
        XCTAssertEqual(state.actionsRejected, 0)
    }

    func testBrowserStepModeBurstRunsTenActionsWithOneApprovalAndTenAuditEntries() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let auditBaseDirectory = testAuditBaseDirectory()
        let approvals = ApprovalRecorder(
            decision: .approve,
            note: "Step-mode burst approved from Mac"
        )
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            auditBaseDirectory: auditBaseDirectory
        )
        let manifest = manifest(sessionId: sessionId, mode: .browser, trustMode: .step)
        let driver = try await makeEchoDriver(sessionId: sessionId, expectedRequestCount: 11)
        _ = try await coordinator.startSession(manifest: manifest, playwrightDriver: driver)
        let capabilityContext = capability(for: makeState(sessionId: sessionId, manifest: manifest))
        var approvalId: String?

        for _ in 0..<10 {
            let response = await coordinator.invoke(
                sessionId: sessionId,
                invocation: invocation(
                    tool: .browserClick,
                    arguments: .object(["selector": .string("#safe")])
                ),
                scopeContext: ComputerUseScopeContext(url: "https://example.com/app"),
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                capability: capabilityContext
            )

            XCTAssertEqual(response.status, .executed)
            let responseApprovalId = try XCTUnwrap(response.approvalId)
            approvalId = approvalId ?? responseApprovalId
            XCTAssertEqual(responseApprovalId, approvalId)
        }

        XCTAssertEqual(approvals.requests.count, 1)
        XCTAssertEqual(approvals.requests.first?.trustMode, ComputerUseTrustMode.step.rawValue)
        XCTAssertEqual(approvals.requests.first?.beforeScreenshotMimeType, "image/png")
        XCTAssertNotNil(approvals.requests.first?.beforeScreenshotPNGBase64)

        let entries = try auditEntries(baseDirectory: auditBaseDirectory, sessionId: sessionId)
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.map(\.entryIndex), Array(0..<10))
        XCTAssertTrue(entries.allSatisfy { $0.actionKind == "browser.click" })
        XCTAssertTrue(entries.allSatisfy { $0.approvedBy == .mac })
        XCTAssertTrue(entries.allSatisfy { $0.approvalId == approvalId })
        XCTAssertTrue(entries.allSatisfy { $0.denyReason == nil })

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsExecuted, 10)
        XCTAssertEqual(state.actionsRejected, 0)
    }

    func testStepModeBurstApprovalCoversNextSimilarActions() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let approvals = ApprovalRecorder(
            decision: .approve,
            note: "Step-mode burst approved from Mac"
        )
        let inputs = MacInputRecorder()
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            macInputDispatcher: { _, action in
                inputs.record(action)
                return .object(["posted": .bool(true)])
            }
        )
        let manifest = manifest(sessionId: sessionId, mode: .system, trustMode: .step)
        _ = try await coordinator.startSession(manifest: manifest)

        let capabilityContext = capability(
            for: makeState(sessionId: sessionId, manifest: manifest),
            accessibilityTrusted: true
        )
        let first = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(tool: .macInputClick, arguments: macClickArguments()),
            scopeContext: ComputerUseScopeContext(bundleId: "com.apple.finder"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capabilityContext
        )
        let second = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(tool: .macInputClick, arguments: macClickArguments()),
            scopeContext: ComputerUseScopeContext(bundleId: "com.apple.finder"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capabilityContext
        )

        XCTAssertEqual(first.status, .executed)
        XCTAssertEqual(second.status, .executed)
        XCTAssertEqual(approvals.requests.count, 1)
        XCTAssertEqual(approvals.requests.first?.trustMode, ComputerUseTrustMode.step.rawValue)
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(second.approvalId, first.approvalId)

        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)
        XCTAssertEqual(state.actionsExecuted, 2)
        XCTAssertEqual(state.actionsRejected, 0)
    }

    func testStepModeBurstApprovalDoesNotCoverDifferentAction() async throws {
        let sessionId = ComputerUseSessionID.newRandom()
        let approvals = ApprovalRecorder(
            decision: .approve,
            note: "Step-mode burst approved from Mac"
        )
        let inputs = MacInputRecorder()
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            macInputDispatcher: { _, action in
                inputs.record(action)
                return .object(["posted": .bool(true)])
            }
        )
        let manifest = manifest(sessionId: sessionId, mode: .system, trustMode: .step)
        _ = try await coordinator.startSession(manifest: manifest)

        let capabilityContext = capability(
            for: makeState(sessionId: sessionId, manifest: manifest),
            accessibilityTrusted: true
        )
        _ = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(tool: .macInputClick, arguments: macClickArguments()),
            scopeContext: ComputerUseScopeContext(bundleId: "com.apple.finder"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capabilityContext
        )
        _ = await coordinator.invoke(
            sessionId: sessionId,
            invocation: invocation(
                tool: .macInputClick,
                arguments: .object([
                    "displayX": .number(111),
                    "displayY": .number(222),
                    "mouseButton": .number(0)
                ])
            ),
            scopeContext: ComputerUseScopeContext(bundleId: "com.apple.finder"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: capabilityContext
        )

        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(approvals.requests.count, 2)
    }

    func testApprovalBridgeQueuesAndResolvesMacPresenterDecision() async throws {
        let bridge = ComputerUseApprovalBridge()
        let request = HermesRealtimeRelayApprovalRequest(
            approvalId: "approval-bridge-1",
            runId: "run-bridge",
            sessionId: "session-bridge",
            toolKind: BurnBarToolKind.browserGoto.rawValue,
            title: "Open page",
            message: "Open example.com",
            actionSummary: "Go to https://example.com",
            requestedAt: Date(timeIntervalSince1970: 1_000)
        )

        let issued = Task {
            try await bridge.issue(request)
        }

        try await waitForCondition {
            await bridge.pendingApprovals(sessionId: request.sessionId).count == 1
        }
        let pending = await bridge.pendingApprovals(sessionId: request.sessionId)
        XCTAssertEqual(pending.first?.approvalId, request.approvalId)

        let accepted = await bridge.respond(
            sessionId: request.sessionId,
            response: HermesRealtimeRelayApprovalResponse(
                approvalId: request.approvalId,
                decision: .approve,
                respondedBy: "mac",
                respondedAt: Date(timeIntervalSince1970: 1_001)
            )
        )

        XCTAssertTrue(accepted)
        let response = try await issued.value
        XCTAssertEqual(response.approvalId, request.approvalId)
        XCTAssertEqual(response.decision, .approve)
        let remaining = await bridge.pendingApprovals(sessionId: request.sessionId)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPanicHaltAllEndsEveryActiveSession() async throws {
        let coordinator = makeCoordinator()
        let first = ComputerUseSessionID.newRandom()
        let second = ComputerUseSessionID.newRandom()

        _ = try await coordinator.startSession(
            manifest: manifest(sessionId: first, mode: .browser, trustMode: .manual)
        )
        _ = try await coordinator.startSession(
            manifest: manifest(sessionId: second, mode: .browser, trustMode: .manual)
        )

        let halted = await coordinator.panicHaltAll(source: .hotkey)
        let firstState = await coordinator.session(first)
        let secondState = await coordinator.session(second)

        XCTAssertEqual(Set(halted), Set([first, second]))
        XCTAssertNil(firstState)
        XCTAssertNil(secondState)
    }

    func testDaemonServiceRejectsAppOwnedSystemSessionEarly() async throws {
        let service = ComputerUseService(
            auditBaseDirectory: testAuditBaseDirectory(),
            bridgeScriptURL: testAuditBaseDirectory().appendingPathComponent("missing-bridge.js")
        )

        do {
            _ = try await service.startSession(
                ComputerUseSessionStartRequest(
                    mode: ComputerUseMode.system.rawValue,
                    trustMode: ComputerUseTrustMode.manual.rawValue,
                    clientID: BurnBarClientID(rawValue: "test-client")
                )
            )
            XCTFail("Expected daemon service to reject app-owned System mode")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .unsupportedDaemonMode(ComputerUseMode.system.rawValue))
        }
    }

    func testDaemonServiceRejectsAppOwnedAgentWatchSessionEarly() async throws {
        let service = ComputerUseService(
            auditBaseDirectory: testAuditBaseDirectory(),
            bridgeScriptURL: testAuditBaseDirectory().appendingPathComponent("missing-bridge.js")
        )

        do {
            _ = try await service.startSession(
                ComputerUseSessionStartRequest(
                    mode: ComputerUseMode.agentWatch.rawValue,
                    trustMode: ComputerUseTrustMode.manual.rawValue,
                    clientID: BurnBarClientID(rawValue: "test-client")
                )
            )
            XCTFail("Expected daemon service to reject app-owned Agent Watch mode")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .unsupportedDaemonMode(ComputerUseMode.agentWatch.rawValue))
        }
    }

    // MARK: - Helpers

    private func waitForCondition(
        timeout: TimeInterval = 2,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for Computer Use condition")
    }

    private func makeCoordinator(
        approvalIssuer: @escaping ComputerUseRunCoordinator.ApprovalIssuer = { request in
            HermesRealtimeRelayApprovalResponse(
                approvalId: request.approvalId,
                decision: .approve,
                respondedBy: "mac",
                respondedAt: Date()
            )
        },
        macInputDispatcher: ComputerUseRunCoordinator.MacInputDispatcher? = nil,
        macInspectDispatcher: ComputerUseRunCoordinator.MacInspectDispatcher? = nil,
        auditBaseDirectory: URL? = nil
    ) -> ComputerUseRunCoordinator {
        let auditBaseDirectory = auditBaseDirectory ?? testAuditBaseDirectory()
        return ComputerUseRunCoordinator(
            approvalIssuer: approvalIssuer,
            macInputDispatcher: macInputDispatcher,
            macInspectDispatcher: macInspectDispatcher,
            macAppVersion: "test",
            auditBaseDirectory: auditBaseDirectory,
            logger: BurnBarDaemonLogger(category: "cu-coordinator-tests")
        )
    }

    private func manifest(
        sessionId: ComputerUseSessionID,
        mode: ComputerUseMode,
        trustMode: ComputerUseTrustMode
    ) -> ComputerUseSessionManifest {
        ComputerUseSessionManifest(
            sessionId: sessionId,
            mode: mode,
            trustMode: trustMode,
            startedAt: Date(),
            userId: "test-user",
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: 50,
            sessionTimeoutSeconds: 1_800
        )
    }

    private func makeState(
        sessionId: ComputerUseSessionID,
        manifest suppliedManifest: ComputerUseSessionManifest? = nil
    ) -> ComputerUseSessionState {
        let baseManifest = suppliedManifest ?? manifest(sessionId: sessionId, mode: .system, trustMode: .manual)
        return ComputerUseSessionState(
            sessionId: sessionId,
            manifest: baseManifest,
            liveTrustMode: baseManifest.trustMode
        )
    }

    private func capability(
        for state: ComputerUseSessionState,
        entitlement: ComputerUseEntitlementSnapshot = ComputerUseEntitlementSnapshot(
            isActive: true,
            productId: "com.openburnbar.hostedComputerUseSync.monthly",
            allowsBrowser: true,
            allowsSystem: true,
            allowsPhoneControl: true,
            allowsTrustedScopes: true,
            allowsAuditExport: true
        ),
        accessibilityTrusted: Bool = false
    ) -> ComputerUseCapabilityContext {
        ComputerUseCapabilityContext(
            entitlement: entitlement,
            envelope: .initialNormal,
            usage: ComputerUseQuotaUsage(dayKey: "2026-05-17"),
            session: state,
            concurrentSessionActive: false,
            killSwitch: false,
            accessibilityTrusted: accessibilityTrusted
        )
    }

    private func invocation(
        tool: BurnBarToolKind,
        arguments: BurnBarJSONValue
    ) -> BurnBarToolInvocation {
        BurnBarToolInvocation(
            callID: UUID().uuidString,
            runID: BurnBarRunID(rawValue: "run-\(UUID().uuidString)"),
            tool: tool,
            arguments: arguments,
            requestedBy: BurnBarClientID(rawValue: "client"),
            requestedAt: Date()
        )
    }

    private func macClickArguments() -> BurnBarJSONValue {
        .object([
            "displayX": .number(100),
            "displayY": .number(200),
            "mouseButton": .number(0)
        ])
    }

    private func testAuditBaseDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func firstAuditEntry(
        baseDirectory: URL,
        sessionId: ComputerUseSessionID
    ) throws -> ComputerUseAuditEntry {
        let entries = try auditEntries(baseDirectory: baseDirectory, sessionId: sessionId)
        return try XCTUnwrap(entries.first)
    }

    private func auditEntries(
        baseDirectory: URL,
        sessionId: ComputerUseSessionID
    ) throws -> [ComputerUseAuditEntry] {
        let chainURL = baseDirectory
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        let data = try Data(contentsOf: chainURL)
        let lines = try XCTUnwrap(String(data: data, encoding: .utf8)?
            .split(separator: "\n"))
        return try lines.map { line in
            try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
                ComputerUseAuditEntry.self,
                from: Data(line.utf8)
            )
        }
    }

    private func makeEchoDriver(
        sessionId: ComputerUseSessionID,
        expectedRequestCount: Int
    ) async throws -> OpenBurnBarPlaywrightDriver {
        let node = try XCTUnwrap(nodeExecutablePath())
        let bridge = try makeEchoBridge(expectedRequestCount: expectedRequestCount)
        let driver = OpenBurnBarPlaywrightDriver(
            configuration: OpenBurnBarPlaywrightDriver.Configuration(
                nodeExecutablePath: node,
                bridgeScriptPath: bridge,
                headless: true,
                perActionTimeoutMillis: 1_000
            ),
            sessionId: sessionId,
            logger: BurnBarDaemonLogger(category: "cu-coordinator-driver-tests")
        )
        try await driver.start()
        return driver
    }

    private func makeEchoBridge(expectedRequestCount: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-coordinator-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bridge = directory.appendingPathComponent("echo-bridge.js")
        let script = """
        const readline = require('readline');
        let requestCount = 0;
        setTimeout(() => process.exit(0), 5000);
        const rl = readline.createInterface({ input: process.stdin, terminal: false });
        rl.on('line', (line) => {
          requestCount += 1;
          const req = JSON.parse(line);
          const result = req.method === 'screenshot'
            ? {
                kind: 'screenshot',
                sizeBytes: 68,
                base64: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII='
              }
            : { method: req.method, params: req.params };
          setTimeout(() => {
            process.stdout.write(JSON.stringify({
              id: req.id,
              ok: true,
              result,
              elapsedMillis: 1
            }) + '\\n', () => {
              if (requestCount >= \(expectedRequestCount)) process.exit(0);
            });
          }, 25);
        });
        """
        try script.write(to: bridge, atomically: true, encoding: .utf8)
        return bridge
    }

    private func nodeExecutablePath() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["NODE_EXECUTABLE"],
            ProcessInfo.processInfo.environment["NODE_BINARY"],
            "/Users/albertonunez/.local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ].compactMap { $0 }

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "node"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

private final class ApprovalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HermesRealtimeRelayApprovalRequest] = []
    private let decision: HermesRealtimeRelayApprovalResponse.Decision
    private let note: String?

    init(
        decision: HermesRealtimeRelayApprovalResponse.Decision,
        note: String? = nil
    ) {
        self.decision = decision
        self.note = note
    }

    func issue(_ request: HermesRealtimeRelayApprovalRequest) async throws -> HermesRealtimeRelayApprovalResponse {
        lock.withLock { requests.append(request) }
        return HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: decision,
            respondedBy: "mac",
            respondedAt: Date(),
            note: note
        )
    }
}

private final class MacInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLast: MacInputAction?
    private var storedCount = 0

    var last: MacInputAction? {
        lock.withLock { storedLast }
    }

    var count: Int {
        lock.withLock { storedCount }
    }

    func record(_ action: MacInputAction) {
        lock.withLock {
            storedLast = action
            storedCount += 1
        }
    }
}

private final class InspectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLast: MacInspectAction?

    var last: MacInspectAction? {
        lock.withLock { storedLast }
    }

    func record(_ action: MacInspectAction) {
        lock.withLock { storedLast = action }
    }
}

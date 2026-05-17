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
        macInspectDispatcher: ComputerUseRunCoordinator.MacInspectDispatcher? = nil
    ) -> ComputerUseRunCoordinator {
        let auditBaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
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

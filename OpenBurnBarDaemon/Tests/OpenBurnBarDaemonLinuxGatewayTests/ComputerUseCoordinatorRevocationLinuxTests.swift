#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

private actor RevocationApprovalLatch {
    private var request: HermesRealtimeRelayApprovalRequest?
    private var continuation: CheckedContinuation<HermesRealtimeRelayApprovalResponse, Error>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func issue(
        _ request: HermesRealtimeRelayApprovalRequest
    ) async throws -> HermesRealtimeRelayApprovalResponse {
        self.request = request
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async {
        if request != nil { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func approve() {
        guard let request, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: .approve,
            respondedBy: "linux-shell",
            respondedAt: Date()
        ))
    }

    private func cancel() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: CancellationError())
    }
}

private actor RevocationDispatchRecorder {
    private(set) var count = 0

    func dispatch() -> BurnBarJSONValue {
        count += 1
        return .object(["posted": .bool(true)])
    }
}

private actor RevocationAuthorizationCounter {
    private(set) var count = 0
    private let denyAt: Int

    init(denyAt: Int) {
        self.denyAt = denyAt
    }

    func authorize() -> Bool {
        count += 1
        return count < denyAt
    }
}

final class ComputerUseCoordinatorRevocationLinuxTests: XCTestCase {
    func testPanicDuringApprovalCancelsAndCannotDispatchOrResurrectSession() async throws {
        let latch = RevocationApprovalLatch()
        let dispatches = RevocationDispatchRecorder()
        let sessionId = ComputerUseSessionID.newRandom()
        let coordinator = makeCoordinator(
            approvalIssuer: { try await latch.issue($0) },
            macInputDispatcher: { _, _ in await dispatches.dispatch() }
        )
        let manifest = makeManifest(sessionId: sessionId)
        _ = try await coordinator.startSession(manifest: manifest)

        let invokeTask = Task {
            await coordinator.invoke(
                sessionId: sessionId,
                invocation: makeInvocation(callID: "panic-during-approval"),
                scopeContext: ComputerUseScopeContext(bundleId: "org.openburnbar.test"),
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                capability: makeCapability(manifest: manifest)
            )
        }
        await latch.waitUntilEntered()

        await coordinator.panicHalt(sessionId: sessionId, source: .hotkey)
        let response = await invokeTask.value
        let dispatchCount = await dispatches.count
        let state = await coordinator.session(sessionId)

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.denyReason, "session_revoked")
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertNil(state)
    }

    func testConcurrentInvocationFailsClosedWhileFirstActionOwnsSession() async throws {
        let latch = RevocationApprovalLatch()
        let sessionId = ComputerUseSessionID.newRandom()
        let coordinator = makeCoordinator(approvalIssuer: { try await latch.issue($0) })
        let manifest = makeManifest(sessionId: sessionId)
        _ = try await coordinator.startSession(manifest: manifest)

        let first = Task {
            await coordinator.invoke(
                sessionId: sessionId,
                invocation: makeInvocation(callID: "first"),
                scopeContext: ComputerUseScopeContext(bundleId: "org.openburnbar.test"),
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                capability: makeCapability(manifest: manifest)
            )
        }
        await latch.waitUntilEntered()

        let second = await coordinator.invoke(
            sessionId: sessionId,
            invocation: makeInvocation(callID: "second"),
            scopeContext: ComputerUseScopeContext(bundleId: "org.openburnbar.test"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: makeCapability(manifest: manifest)
        )
        XCTAssertEqual(second.status, .denied)
        XCTAssertEqual(second.denyReason, "session_action_in_flight")

        await coordinator.panicHalt(sessionId: sessionId, source: .hotkey)
        _ = await first.value
    }

    func testAuthorizerIsRecheckedBeforeDispatchAndDenialIsAudited() async throws {
        let authorizations = RevocationAuthorizationCounter(denyAt: 3)
        let dispatches = RevocationDispatchRecorder()
        let sessionId = ComputerUseSessionID.newRandom()
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .approve,
                    respondedBy: "linux-shell",
                    respondedAt: Date()
                )
            },
            macInputDispatcher: { _, _ in await dispatches.dispatch() },
            preDispatchAuthorizer: { _, _ in await authorizations.authorize() }
        )
        let manifest = makeManifest(sessionId: sessionId)
        _ = try await coordinator.startSession(manifest: manifest)

        let response = await coordinator.invoke(
            sessionId: sessionId,
            invocation: makeInvocation(callID: "authorization-recheck"),
            scopeContext: ComputerUseScopeContext(bundleId: "org.openburnbar.test"),
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            capability: makeCapability(manifest: manifest)
        )
        let authorizationCount = await authorizations.count
        let dispatchCount = await dispatches.count
        let maybeState = await coordinator.session(sessionId)
        let state = try XCTUnwrap(maybeState)

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.denyReason, "pre_dispatch_authorization_denied")
        XCTAssertNotNil(response.auditEntryIndex)
        XCTAssertEqual(authorizationCount, 3)
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertEqual(state.actionsRejected, 1)
        XCTAssertEqual(state.actionsExecuted, 0)
    }

    private func makeCoordinator(
        approvalIssuer: @escaping ComputerUseRunCoordinator.ApprovalIssuer,
        macInputDispatcher: ComputerUseRunCoordinator.MacInputDispatcher? = nil,
        preDispatchAuthorizer: ComputerUseRunCoordinator.PreDispatchAuthorizer? = nil
    ) -> ComputerUseRunCoordinator {
        ComputerUseRunCoordinator(
            approvalIssuer: approvalIssuer,
            macInputDispatcher: macInputDispatcher,
            preDispatchAuthorizer: preDispatchAuthorizer,
            macAppVersion: "linux-revocation-test",
            auditBaseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "openburnbar-cu-revocation-\(UUID().uuidString)",
                isDirectory: true
            )
        )
    }

    private func makeManifest(sessionId: ComputerUseSessionID) -> ComputerUseSessionManifest {
        ComputerUseSessionManifest(
            sessionId: sessionId,
            mode: .system,
            trustMode: .manual,
            startedAt: Date(),
            userId: "linux-shell",
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: 50,
            sessionTimeoutSeconds: 1_800
        )
    }

    private func makeCapability(
        manifest: ComputerUseSessionManifest
    ) -> ComputerUseCapabilityContext {
        ComputerUseCapabilityContext(
            entitlement: ComputerUseEntitlementSnapshot(
                isActive: true,
                productId: "com.openburnbar.hostedComputerUseSync.monthly",
                allowsBrowser: true,
                allowsSystem: true,
                allowsPhoneControl: false,
                allowsTrustedScopes: true,
                allowsAuditExport: true
            ),
            envelope: .initialNormal,
            usage: ComputerUseQuotaUsage(dayKey: "2026-07-11"),
            session: ComputerUseSessionState(
                sessionId: manifest.sessionId,
                manifest: manifest,
                liveTrustMode: manifest.trustMode
            ),
            concurrentSessionActive: false,
            killSwitch: false,
            accessibilityTrusted: true
        )
    }

    private func makeInvocation(callID: String) -> BurnBarToolInvocation {
        BurnBarToolInvocation(
            callID: callID,
            runID: BurnBarRunID(rawValue: "run-revocation"),
            tool: .macInputClick,
            arguments: .object([
                "displayX": .number(100),
                "displayY": .number(200),
                "mouseButton": .number(0)
            ]),
            requestedBy: BurnBarClientID(rawValue: "linux-shell"),
            requestedAt: Date()
        )
    }
}
#endif

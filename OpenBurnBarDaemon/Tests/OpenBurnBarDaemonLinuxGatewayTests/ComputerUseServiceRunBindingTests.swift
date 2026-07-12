import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

private actor EndedSessionRecorder {
    private var sessionIDs: [String] = []

    func append(_ sessionID: String) {
        sessionIDs.append(sessionID)
    }

    var recordedSessionIDs: [String] {
        sessionIDs
    }
}

private actor ControlledApprovalPublisher {
    private var entered = false
    private var finished = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var publishedApprovalIDs: [String] = []

    func publish(_ request: HermesRealtimeRelayApprovalRequest) async throws {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        defer {
            finished = true
            finishedWaiters.forEach { $0.resume() }
            finishedWaiters.removeAll()
        }
        try Task.checkCancellation()
        publishedApprovalIDs.append(request.approvalId)
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { finishedWaiters.append($0) }
    }

    var approvalIDs: [String] {
        publishedApprovalIDs
    }
}

final class ComputerUseServiceRunBindingTests: XCTestCase {
    private func makeCapabilityStateStore(
        at root: URL,
        publisherInstanceID: String = "computer-use-run-binding-tests"
    ) async throws -> ComputerUseCapabilityStateStore {
        let now = Date()
        let store = ComputerUseCapabilityStateStore(
            fileURL: root.appendingPathComponent("capability-state.json"),
            now: { now }
        )
        let provenance = ComputerUseAuthorityProvenance(
            source: .firestoreServer,
            observedAt: now,
            updatedAt: now
        )
        _ = try await store.update(ComputerUseCapabilityStateSnapshot(
            publisherInstanceID: publisherInstanceID,
            revision: 1,
            generatedAt: now,
            userID: "linux-test-user",
            entitlement: ComputerUseEntitlementSnapshot(
                isActive: true,
                productId: ComputerUseEntitlementSnapshot.hostedProductID,
                expireAt: now.addingTimeInterval(3_600),
                allowsBrowser: true,
                allowsSystem: true,
                allowsPhoneControl: true,
                allowsTrustedScopes: true,
                allowsAuditExport: true
            ),
            entitlementProvenance: provenance,
            budgetEnvelope: ComputerUseBudgetEnvelope(
                level: .normal,
                projectedMonthEndUSD: 0,
                monthToDateUSD: 0,
                activeActionsPerRun: 50,
                activeActionsPerDay: 200,
                activeSessionsPerDay: 4,
                perUserDailySpendCeilingUSD: 5,
                updatedAt: now
            ),
            budgetProvenance: provenance,
            quotaUsage: ComputerUseQuotaUsage(
                dayKey: String(ISO8601DateFormatter().string(from: now).prefix(10)),
                updatedAt: now
            ),
            quotaProvenance: provenance,
            concurrentSessionActive: false,
            killSwitch: false,
            isComplete: true
        ))
        return store
    }

    func testApprovalCancellationStopsSuspendedPhonePublication() async throws {
        let bridge = ComputerUseApprovalBridge()
        let publisher = ControlledApprovalPublisher()
        let request = HermesRealtimeRelayApprovalRequest(
            approvalId: "linux-approval-cancelled-before-publish",
            runId: "linux-run-cancelled-before-publish",
            sessionId: "linux-session-cancelled-before-publish",
            toolKind: BurnBarToolKind.browserGoto.rawValue,
            title: "Open page",
            message: "Open example.com",
            actionSummary: "Go to https://example.com",
            requestedAt: Date(timeIntervalSince1970: 1_000)
        )
        let issued = Task {
            try await bridge.issue(request) { request in
                try await publisher.publish(request)
            }
        }

        await publisher.waitUntilEntered()
        issued.cancel()
        do {
            _ = try await issued.value
            XCTFail("Cancelled approval unexpectedly resolved")
        } catch is CancellationError {
            // Expected: cancelling the approval owns publication cancellation.
        }
        await publisher.release()
        await publisher.waitUntilFinished()

        let pending = await bridge.pendingApprovals(sessionId: request.sessionId)
        let publishedApprovalIDs = await publisher.approvalIDs
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(publishedApprovalIDs.isEmpty)
    }

    #if os(Linux)
    func testNonBrowserSessionCannotReserveAgentRunBinding() async throws {
        let service = ComputerUseService(
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil },
            requiresManagedBrowserRunAuthority: true
        )

        do {
            _ = try await service.startSession(ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "linux-shell"),
                runID: BurnBarRunID(rawValue: "browser-run")
            ))
            XCTFail("Non-browser sessions must not reserve managed browser runs.")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .runBindingUnsupportedMode(ComputerUseMode.system.rawValue))
        }
    }
    #endif

    func testBrowserSessionRequiresRunBinding() async throws {
        let service = ComputerUseService(
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil },
            requiresManagedBrowserRunAuthority: true
        )

        do {
            _ = try await service.startSession(ComputerUseSessionStartRequest(
                mode: ComputerUseMode.browser.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "linux-shell")
            ))
            XCTFail("Browser sessions must never start without an agent run binding.")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .browserRunRequired)
        }
    }

    func testConcurrentStartsCannotBindTheSameRunTwice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-concurrent-binding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capabilityStateStore = try await makeCapabilityStateStore(at: root)
        let authorizationRegistry = ComputerUseAuthorizationRegistry(enforcementEnabled: true)
        let service = ComputerUseService(
            auditBaseDirectory: root,
            capabilityStateStore: capabilityStateStore,
            leafKillSwitch: { false },
            playwrightDriverFactory: { _ in nil },
            privilegedInputKillSwitchActivator: { _ in },
            authorizationRegistry: authorizationRegistry,
            requiresManagedBrowserRunAuthority: true
        )
        let runID = BurnBarRunID(rawValue: "concurrent-run")
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            sessionTimeoutSeconds: 0,
            clientID: BurnBarClientID(rawValue: "linux-shell"),
            runID: runID
        )

        let didReservePendingStart = await authorizationRegistry.reserve(runID: runID)
        XCTAssertTrue(didReservePendingStart)

        do {
            _ = try await service.startSession(request)
            XCTFail("A pending session start must reserve its agent run binding.")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .runAlreadyBound(runID.rawValue))
        }

        await authorizationRegistry.releaseReservation(runID: runID)
        let didReserveAfterRelease = await authorizationRegistry.reserve(runID: runID)
        XCTAssertTrue(didReserveAfterRelease)
        await authorizationRegistry.releaseReservation(runID: runID)
        let boundSessionID = await service.sessionID(for: runID)
        XCTAssertNil(boundSessionID)
    }

    func testGlobalPanicNotifiesSessionEndObserverForManifestedSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-global-panic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endedSessions = EndedSessionRecorder()
        let now = Date()
        let capabilityStateStore = ComputerUseCapabilityStateStore(
            fileURL: root.appendingPathComponent("capability-state.json"),
            now: { now }
        )
        let provenance = ComputerUseAuthorityProvenance(
            source: .firestoreServer,
            observedAt: now,
            updatedAt: now
        )
        _ = try await capabilityStateStore.update(ComputerUseCapabilityStateSnapshot(
            publisherInstanceID: "global-panic-observer-test",
            revision: 1,
            generatedAt: now,
            userID: "linux-test-user",
            entitlement: ComputerUseEntitlementSnapshot(
                isActive: true,
                productId: ComputerUseEntitlementSnapshot.hostedProductID,
                expireAt: now.addingTimeInterval(3_600),
                allowsBrowser: true,
                allowsSystem: true,
                allowsPhoneControl: true,
                allowsTrustedScopes: true,
                allowsAuditExport: true
            ),
            entitlementProvenance: provenance,
            budgetEnvelope: ComputerUseBudgetEnvelope(
                level: .normal,
                projectedMonthEndUSD: 0,
                monthToDateUSD: 0,
                activeActionsPerRun: 50,
                activeActionsPerDay: 200,
                activeSessionsPerDay: 4,
                perUserDailySpendCeilingUSD: 5,
                updatedAt: now
            ),
            budgetProvenance: provenance,
            quotaUsage: ComputerUseQuotaUsage(
                dayKey: String(ISO8601DateFormatter().string(from: now).prefix(10)),
                updatedAt: now
            ),
            quotaProvenance: provenance,
            concurrentSessionActive: false,
            killSwitch: false,
            isComplete: true
        ))
        let service = ComputerUseService(
            auditBaseDirectory: root,
            capabilityStateStore: capabilityStateStore,
            leafKillSwitch: { false },
            playwrightDriverFactory: { _ in nil },
            privilegedInputKillSwitchActivator: { _ in },
            requiresManagedBrowserRunAuthority: true,
            sessionEndedObserver: { sessionID in
                await endedSessions.append(sessionID)
            }
        )
        let first = try await service.startSession(ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            clientID: BurnBarClientID(rawValue: "linux-shell"),
            runID: BurnBarRunID(rawValue: "global-panic-run-1")
        ))

        _ = try await service.panicHalt(ComputerUsePanicHaltRequest(
            sessionId: "*",
            source: ComputerUsePanicSource.hotkey.rawValue
        ))

        let observedSessionIDs = await endedSessions.recordedSessionIDs
        XCTAssertEqual(observedSessionIDs, [first.sessionId])
    }

    func testExpiredSessionReleasesRunBindingBeforeRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-expired-binding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capabilityStateStore = try await makeCapabilityStateStore(at: root)
        let service = ComputerUseService(
            auditBaseDirectory: root,
            capabilityStateStore: capabilityStateStore,
            leafKillSwitch: { false },
            playwrightDriverFactory: { _ in nil },
            privilegedInputKillSwitchActivator: { _ in },
            requiresManagedBrowserRunAuthority: true
        )
        let runID = BurnBarRunID(rawValue: "expired-run")
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            sessionTimeoutSeconds: 1,
            clientID: BurnBarClientID(rawValue: "linux-shell"),
            runID: runID
        )

        let first = try await service.startSession(request)
        let activePoll = await service.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: first.sessionId)
        )
        XCTAssertTrue(try XCTUnwrap(activePoll.sessionActive))
        try await Task.sleep(for: .milliseconds(1_100))

        let expiredPoll = await service.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: first.sessionId)
        )
        XCTAssertFalse(try XCTUnwrap(expiredPoll.sessionActive))
        let expiredSessionID = await service.sessionID(for: runID)
        XCTAssertNil(expiredSessionID)
        let replacement = try await service.startSession(request)
        XCTAssertNotEqual(replacement.sessionId, first.sessionId)
        _ = try await service.panicHalt(ComputerUsePanicHaltRequest(
            sessionId: replacement.sessionId,
            source: ComputerUsePanicSource.hotkey.rawValue
        ))
    }

    func testFilteredPendingPollReportsAuthoritativeSessionLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-pending-lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capabilityStateStore = try await makeCapabilityStateStore(at: root)
        let service = ComputerUseService(
            auditBaseDirectory: root,
            capabilityStateStore: capabilityStateStore,
            leafKillSwitch: { false },
            playwrightDriverFactory: { _ in nil },
            privilegedInputKillSwitchActivator: { _ in },
            requiresManagedBrowserRunAuthority: true
        )
        let runID = BurnBarRunID(rawValue: "pending-lifecycle-run")
        let started = try await service.startSession(ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            clientID: BurnBarClientID(rawValue: "linux-shell"),
            runID: runID
        ))

        let unfiltered = await service.pendingApprovals(ComputerUseApprovalPendingRequest())
        let active = await service.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: started.sessionId)
        )
        let unknown = await service.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: "unknown-session")
        )
        XCTAssertNil(unfiltered.sessionActive)
        XCTAssertTrue(try XCTUnwrap(active.sessionActive))
        XCTAssertFalse(try XCTUnwrap(unknown.sessionActive))

        _ = try await service.panicHalt(ComputerUsePanicHaltRequest(
            sessionId: started.sessionId,
            source: ComputerUsePanicSource.hotkey.rawValue
        ))
        let halted = await service.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: started.sessionId)
        )
        XCTAssertFalse(try XCTUnwrap(halted.sessionActive))

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(halted)
        ) as? [String: Any]
        XCTAssertEqual(encoded?["sessionActive"] as? Bool, false)
    }

    func testRunBindingIsManifestBoundUniqueAndRemovedByPanicHalt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-run-binding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capabilityStateStore = try await makeCapabilityStateStore(at: root)
        let service = ComputerUseService(
            auditBaseDirectory: root,
            capabilityStateStore: capabilityStateStore,
            leafKillSwitch: { false },
            playwrightDriverFactory: { _ in nil },
            privilegedInputKillSwitchActivator: { _ in },
            requiresManagedBrowserRunAuthority: true
        )
        let runID = BurnBarRunID(rawValue: "run-bound-to-cu")
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            clientID: BurnBarClientID(rawValue: "linux-shell"),
            runID: runID
        )

        let started = try await service.startSession(request)
        let boundSessionID = await service.sessionID(for: runID)
        XCTAssertEqual(boundSessionID?.rawValue, started.sessionId)

        let manifestURL = root
            .appendingPathComponent(started.sessionId, isDirectory: true)
            .appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            ComputerUseSessionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.runId, runID.rawValue)

        do {
            _ = try await service.startSession(request)
            XCTFail("A second Computer Use session must be rejected while one is active.")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(
                error,
                .capabilityDenied(ComputerUseDenyReason.concurrentSession.rawValue)
            )
        }

        _ = try await service.panicHalt(ComputerUsePanicHaltRequest(
            sessionId: started.sessionId,
            source: ComputerUsePanicSource.hotkey.rawValue
        ))
        let sessionAfterHalt = await service.sessionID(for: runID)
        XCTAssertNil(sessionAfterHalt)
    }

    func testInvokeForUnboundRunFailsBeforeAnyBrowserDispatch() async throws {
        let service = ComputerUseService(
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil },
            requiresManagedBrowserRunAuthority: true
        )
        let runID = BurnBarRunID(rawValue: "unbound-run")
        let invocation = BurnBarToolInvocation(
            callID: "call-1",
            runID: runID,
            tool: .browserGoto,
            arguments: .object(["url": .string("https://example.com")]),
            requestedBy: BurnBarClientID(rawValue: "linux-shell"),
            requestedAt: Date()
        )

        do {
            _ = try await service.invokeForRun(invocation)
            XCTFail("An unbound agent run must fail closed.")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .runNotBound(runID.rawValue))
        }
    }

    func testExternalInvokeCannotBypassManagedRunAndInternalDispatchChecksClient() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-identity-binding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capabilityStateStore = try await makeCapabilityStateStore(at: root)
        let service = ComputerUseService(
            auditBaseDirectory: root,
            capabilityStateStore: capabilityStateStore,
            leafKillSwitch: { false },
            playwrightDriverFactory: { _ in nil },
            privilegedInputKillSwitchActivator: { _ in },
            requiresManagedBrowserRunAuthority: true
        )
        let runID = BurnBarRunID(rawValue: "identity-run")
        let started = try await service.startSession(ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            clientID: BurnBarClientID(rawValue: "run-owner"),
            runID: runID
        ))

        let arbitraryExternalAction = BurnBarToolInvocation(
            callID: "arbitrary-external-call",
            runID: runID,
            tool: .browserScreenshot,
            arguments: .object([:]),
            requestedBy: BurnBarClientID(rawValue: "run-owner"),
            requestedAt: Date()
        )
        do {
            _ = try await service.invoke(ComputerUseInvokeRequest(
                sessionId: started.sessionId,
                invocation: arbitraryExternalAction
            ))
            XCTFail("External callers must not dispatch actions for a daemon-managed run.")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .managedRunDispatchRequired)
        }

        let wrongClient = BurnBarToolInvocation(
            callID: "wrong-client-call",
            runID: runID,
            tool: .browserScreenshot,
            arguments: .object([:]),
            requestedBy: BurnBarClientID(rawValue: "other-client"),
            requestedAt: Date()
        )
        do {
            _ = try await service.invokeForRun(wrongClient)
            XCTFail("A session must not execute another client's invocation.")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(
                error,
                .clientIdentityMismatch(expected: "run-owner", actual: "other-client")
            )
        }
        _ = try await service.panicHalt(ComputerUsePanicHaltRequest(
            sessionId: started.sessionId,
            source: ComputerUsePanicSource.hotkey.rawValue
        ))
    }

    func testRunIDChangesManifestAuditRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-manifest-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = ComputerUseSessionID("fixed-session")
        let startedAt = Date(timeIntervalSinceReferenceDate: 42)
        func manifest(runID: String) -> ComputerUseSessionManifest {
            ComputerUseSessionManifest(
                sessionId: sessionID,
                mode: .browser,
                trustMode: .manual,
                startedAt: startedAt,
                userId: "owner",
                runId: runID,
                entitlementProductId: "product",
                actionCap: 10,
                sessionTimeoutSeconds: 30
            )
        }
        let first = try ComputerUseAuditLogger(
            sessionId: sessionID,
            baseDirectory: root.appendingPathComponent("first"),
            macAppVersion: "test"
        )
        try first.beginSession(manifest: manifest(runID: "run-a"))
        let second = try ComputerUseAuditLogger(
            sessionId: sessionID,
            baseDirectory: root.appendingPathComponent("second"),
            macAppVersion: "test"
        )
        try second.beginSession(manifest: manifest(runID: "run-b"))

        XCTAssertNotEqual(first.headHashHex, second.headHashHex)
    }
}

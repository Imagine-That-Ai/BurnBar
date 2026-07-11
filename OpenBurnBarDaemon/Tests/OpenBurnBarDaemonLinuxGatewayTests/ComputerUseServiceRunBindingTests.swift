import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

private actor PlaywrightFactoryLatch {
    private var callCount = 0
    private var firstCallEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseFirstCall() async {
        callCount += 1
        guard callCount == 1 else { return }
        firstCallEntered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilFirstCallEntered() async {
        if firstCallEntered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func releaseFirstCall() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class ComputerUseServiceRunBindingTests: XCTestCase {
    func testNonBrowserSessionCannotReserveAgentRunBinding() async throws {
        let service = ComputerUseService(
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil }
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

    func testBrowserSessionRequiresRunBinding() async throws {
        let service = ComputerUseService(
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil }
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
        let latch = PlaywrightFactoryLatch()
        let service = ComputerUseService(
            auditBaseDirectory: root,
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in
                await latch.pauseFirstCall()
                return nil
            }
        )
        let runID = BurnBarRunID(rawValue: "concurrent-run")
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            clientID: BurnBarClientID(rawValue: "linux-shell"),
            runID: runID
        )

        let firstStart = Task { try await service.startSession(request) }
        await latch.waitUntilFirstCallEntered()

        do {
            _ = try await service.startSession(request)
            XCTFail("A pending session start must reserve its agent run binding.")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .runAlreadyBound(runID.rawValue))
        }

        await latch.releaseFirstCall()
        let started = try await firstStart.value
        let boundSessionID = await service.sessionID(for: runID)
        XCTAssertEqual(boundSessionID?.rawValue, started.sessionId)
        _ = try await service.panicHalt(ComputerUsePanicHaltRequest(
            sessionId: started.sessionId,
            source: ComputerUsePanicSource.hotkey.rawValue
        ))
    }

    func testExpiredSessionReleasesRunBindingBeforeRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-expired-binding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ComputerUseService(
            auditBaseDirectory: root,
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil }
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
        XCTAssertEqual(activePoll.sessionActive, true)
        try await Task.sleep(for: .milliseconds(1_100))

        let expiredPoll = await service.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: first.sessionId)
        )
        XCTAssertEqual(expiredPoll.sessionActive, false)
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
        let service = ComputerUseService(
            auditBaseDirectory: root,
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil }
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
        XCTAssertEqual(active.sessionActive, true)
        XCTAssertEqual(unknown.sessionActive, false)

        _ = try await service.panicHalt(ComputerUsePanicHaltRequest(
            sessionId: started.sessionId,
            source: ComputerUsePanicSource.hotkey.rawValue
        ))
        let halted = await service.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: started.sessionId)
        )
        XCTAssertEqual(halted.sessionActive, false)

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(halted)
        ) as? [String: Any]
        XCTAssertEqual(encoded?["sessionActive"] as? Bool, false)
    }

    func testRunBindingIsManifestBoundUniqueAndRemovedByPanicHalt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-run-binding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = ComputerUseService(
            auditBaseDirectory: root,
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil }
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
            XCTFail("A run must not bind to two active Computer Use sessions.")
        } catch let error as ComputerUseService.ServiceError {
            XCTAssertEqual(error, .runAlreadyBound(runID.rawValue))
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
            playwrightDriverFactory: { _ in nil }
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
        let service = ComputerUseService(
            auditBaseDirectory: root,
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil }
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

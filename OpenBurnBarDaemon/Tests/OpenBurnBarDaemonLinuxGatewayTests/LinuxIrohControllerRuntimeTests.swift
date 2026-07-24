#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay
import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBarDaemon

private struct TestLinuxIrohIdentityProvider: LinuxIrohHostIdentityProviding {
    let identity: LinuxIrohHostIdentity
    func loadOrCreate() throws -> LinuxIrohHostIdentity { identity }
}

private actor TestLinuxIrohDirectory: LinuxIrohControllerDirectoryServing {
    private var route: LinuxIrohControllerRoute
    private var resolveFailuresRemaining = 0
    private var publishedKeyCount = 0
    private var publishedRecordCount = 0
    private var revokedConnectionIDs: [String] = []
    private var recordFailuresAfterApplyRemaining = 0
    private var revokeFailuresRemaining = 0
    private var suspendRecordPublication = false
    private var recordPublicationSuspended = false
    private var recordPublicationContinuation: CheckedContinuation<Void, Never>?
    private var rejectCancelledRevocations = false
    private var controlledResolutionCount = 0
    private var nextControlledResolutionID = 0
    private var controlledResolutions: [
        Int: CheckedContinuation<LinuxIrohControllerRoute?, Never>
    ] = [:]

    init(route: LinuxIrohControllerRoute) { self.route = route }

    func publishHostPublicKey(_ keypair: IrohPairingKeypair) async throws {
        _ = keypair
        publishedKeyCount += 1
    }

    func publishHostRecord(_ record: IrohPairingRecord) async throws {
        XCTAssertEqual(record.uid, route.uid)
        XCTAssertEqual(record.connectionId, route.connectionID)
        publishedRecordCount += 1
        if suspendRecordPublication {
            suspendRecordPublication = false
            recordPublicationSuspended = true
            await withCheckedContinuation { continuation in
                recordPublicationContinuation = continuation
            }
            recordPublicationSuspended = false
        }
        if recordFailuresAfterApplyRemaining > 0 {
            recordFailuresAfterApplyRemaining -= 1
            throw LinuxIrohControllerDirectoryError.transportFailure
        }
    }

    func resolveActiveRoute(connectionID: String) async throws -> LinuxIrohControllerRoute? {
        if resolveFailuresRemaining > 0 {
            resolveFailuresRemaining -= 1
            throw LinuxIrohControllerDirectoryError.transportFailure
        }
        guard connectionID == route.connectionID else {
            throw LinuxIrohControllerDirectoryError.routeMismatch
        }
        if controlledResolutionCount > 0 {
            controlledResolutionCount -= 1
            let resolutionID = nextControlledResolutionID
            nextControlledResolutionID += 1
            return await withCheckedContinuation { continuation in
                controlledResolutions[resolutionID] = continuation
            }
        }
        return route
    }

    func revokeHostRecord(connectionID: String) async throws {
        if rejectCancelledRevocations, Task.isCancelled { throw CancellationError() }
        if revokeFailuresRemaining > 0 {
            revokeFailuresRemaining -= 1
            throw LinuxIrohControllerDirectoryError.transportFailure
        }
        revokedConnectionIDs.append(connectionID)
    }

    func counts() -> (Int, Int, [String]) {
        (publishedKeyCount, publishedRecordCount, revokedConnectionIDs)
    }

    func updateRoute(_ route: LinuxIrohControllerRoute) { self.route = route }
    func failNextResolutions(_ count: Int) { resolveFailuresRemaining = count }
    func failRecordPublicationsAfterApply(_ count: Int) { recordFailuresAfterApplyRemaining = count }
    func failNextRevocations(_ count: Int) { revokeFailuresRemaining = count }
    func suspendNextRecordPublicationAfterApply() { suspendRecordPublication = true }
    func isRecordPublicationSuspended() -> Bool { recordPublicationSuspended }
    func releaseRecordPublication() {
        suspendRecordPublication = false
        recordPublicationContinuation?.resume()
        recordPublicationContinuation = nil
    }
    func setRejectCancelledRevocations(_ reject: Bool) { rejectCancelledRevocations = reject }
    func controlNextResolutions(_ count: Int) { controlledResolutionCount = count }
    func controlledRequestCount() -> Int { nextControlledResolutionID }
    func releaseControlledResolution(_ id: Int, route: LinuxIrohControllerRoute?) {
        controlledResolutions.removeValue(forKey: id)?.resume(returning: route)
    }
}

private actor TestLinuxIrohStream: IrohRelayStream {
    nonisolated let remotePeerNodeId: String?
    private var inbound: [HermesRealtimeRelayFrame]
    private var outbound: [HermesRealtimeRelayFrame] = []
    private var closed = false

    init(remotePeerNodeId: String?, inbound: [HermesRealtimeRelayFrame]) {
        self.remotePeerNodeId = remotePeerNodeId
        self.inbound = inbound
    }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        guard closed == false else { throw IrohRelayTransportError.shutdown }
        outbound.append(frame)
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        while inbound.isEmpty, closed == false {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard inbound.isEmpty == false else { return nil }
        return inbound.removeFirst()
    }

    func close() async { closed = true }
    func enqueue(_ frame: HermesRealtimeRelayFrame) { inbound.append(frame) }
    func isClosed() -> Bool { closed }
    func sentFrames() -> [HermesRealtimeRelayFrame] { outbound }
}

private actor TestLinuxIrohRevocations {
    private var entries: [([String], String)] = []

    func append(sessionIDs: [String], reason: String) {
        entries.append((sessionIDs, reason))
    }

    func contains(sessionID: String, reason: String) -> Bool {
        entries.contains { $0.0.contains(sessionID) && $0.1 == reason }
    }

    func containsSession(_ sessionID: String) -> Bool {
        entries.contains { $0.0.contains(sessionID) }
    }
}

private actor TestLinuxIrohPanicIngress {
    private var haltedSessionIDs: Set<String> = []

    func record(_ sessionIDs: [String]) {
        haltedSessionIDs.formUnion(sessionIDs)
    }

    func containsExactly(_ sessionIDs: Set<String>) -> Bool {
        haltedSessionIDs == sessionIDs
    }
}

private actor TestLinuxIrohCredentialGate {
    private var continuation: CheckedContinuation<LinuxIrohControllerCredentialContext, Never>?
    private var requested = false

    func value() async -> LinuxIrohControllerCredentialContext {
        requested = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func hasRequest() -> Bool { requested }
    func release(_ context: LinuxIrohControllerCredentialContext) {
        continuation?.resume(returning: context)
        continuation = nil
    }
}

private actor TestLinuxIrohCredentialStore {
    private var context: LinuxIrohControllerCredentialContext

    init(_ context: LinuxIrohControllerCredentialContext) {
        self.context = context
    }

    func value() -> LinuxIrohControllerCredentialContext { context }
    func update(_ context: LinuxIrohControllerCredentialContext) { self.context = context }
}

private actor TestLinuxIrohRouteEndGate {
    private var enteredCount = 0
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        enteredCount += 1
        guard shouldSuspend else { return }
        shouldSuspend = false
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { enteredCount > 0 }
    func count() -> Int { enteredCount }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TestLinuxIrohAuthorityGate {
    private var allowed: Bool

    init(allowed: Bool) {
        self.allowed = allowed
    }

    func setAllowed(_ allowed: Bool) {
        self.allowed = allowed
    }

    func isAllowed() -> Bool {
        allowed
    }
}

private actor TestLinuxIrohTransport: IrohRelayTransport {
    private let identity: IrohEndpointIdentity
    private var pending: [any IrohRelayStream] = []
    private var stopped = false

    init(identity: IrohEndpointIdentity) { self.identity = identity }

    func start() async throws -> IrohEndpointIdentity {
        stopped = false
        return identity
    }

    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> any IrohRelayStream {
        _ = target
        _ = timeout
        throw IrohRelayTransportError.streamRejected("host-only test transport")
    }

    func accept(timeout: TimeInterval) async throws -> any IrohRelayStream {
        _ = timeout
        while pending.isEmpty, stopped == false {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard stopped == false else { throw IrohRelayTransportError.shutdown }
        return pending.removeFirst()
    }

    func shutdown() async { stopped = true }
    func enqueue(_ stream: any IrohRelayStream) { pending.append(stream) }
    func isStopped() -> Bool { stopped }
}

final class LinuxIrohControllerRuntimeTests: XCTestCase {
    private enum WaitError: Error {
        case timedOut
    }

    func testStopInvalidatesAndAwaitsInProgressStartEpoch() async throws {
        let deviceID = "linux-start-race"
        let connectionID = "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
        let route = LinuxIrohControllerRoute(
            uid: "user-start-race",
            connectionID: connectionID,
            sourceDeviceID: "phone",
            transportNodeID: String(repeating: "7", count: 64),
            authorityPeerNodeID: "authority",
            generation: 1,
            registeredAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            accountGeneration: 1
        )
        let transport = TestLinuxIrohTransport(identity: IrohEndpointIdentity(
            nodeId: String(repeating: "8", count: 64),
            rawPublicKey: Data(repeating: 0x88, count: 32)
        ))
        let gate = TestLinuxIrohCredentialGate()
        let runtime = LinuxIrohControllerRuntime(
            transport: transport,
            directory: TestLinuxIrohDirectory(route: route),
            identityStore: TestLinuxIrohIdentityProvider(identity: LinuxIrohHostIdentity(
                endpointSecret: IrohSecretKeyMaterial(raw: Data(repeating: 0x33, count: 32)),
                pairingKeypair: IrohPairingKeypair(signingKey: PlatformCrypto.ed25519PrivateKey())
            )),
            credentialProvider: { await gate.value() },
            authorityReadiness: { _, _ in true }
        )
        await runtime.installHandlers(
            grant: { _, _ in },
            approval: { _, _, _, _ in },
            panic: { _, _, _, _ in },
            revokeSessions: { _, _ in },
            media: { _, _, _ in }
        )
        let startTask = Task { try await runtime.start() }
        try await eventually { await gate.hasRequest() }
        let stopping = Task { await runtime.stop() }
        await gate.release(LinuxIrohControllerCredentialContext(
            uid: route.uid,
            sessionGeneration: 1,
            idToken: "id",
            appCheckToken: "app-check",
            deviceID: deviceID
        ))
        await stopping.value
        var startupWasCancelled = false
        do {
            try await startTask.value
            XCTFail("A stopped start epoch must not complete successfully")
        } catch is CancellationError {
            startupWasCancelled = true
        } catch {
            XCTFail("Unexpected startup error: \(error)")
        }
        XCTAssertTrue(startupWasCancelled)
        let status = await runtime.status()
        XCTAssertEqual(status.phase, .stopped)
        let ready = await runtime.isReady()
        XCTAssertFalse(ready)
        let transportStopped = await transport.isStopped()
        XCTAssertTrue(transportStopped)
    }

    func testStopCompensatesRecordAppliedByCancelledStartup() async throws {
        let deviceID = "linux-stop-ambiguous-publication"
        let connectionID = "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
        let route = LinuxIrohControllerRoute(
            uid: "user-stop-ambiguous-publication",
            connectionID: connectionID,
            sourceDeviceID: "phone-stop-ambiguous-publication",
            transportNodeID: String(repeating: "5", count: 64),
            authorityPeerNodeID: "authority-stop-ambiguous-publication",
            generation: 1,
            registeredAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            accountGeneration: 1
        )
        let directory = TestLinuxIrohDirectory(route: route)
        await directory.suspendNextRecordPublicationAfterApply()
        await directory.setRejectCancelledRevocations(true)
        let transport = TestLinuxIrohTransport(identity: IrohEndpointIdentity(
            nodeId: String(repeating: "6", count: 64),
            rawPublicKey: Data(repeating: 0x66, count: 32)
        ))
        let runtime = LinuxIrohControllerRuntime(
            transport: transport,
            directory: directory,
            identityStore: TestLinuxIrohIdentityProvider(identity: LinuxIrohHostIdentity(
                endpointSecret: IrohSecretKeyMaterial(raw: Data(repeating: 0x88, count: 32)),
                pairingKeypair: IrohPairingKeypair(signingKey: PlatformCrypto.ed25519PrivateKey())
            )),
            credentialProvider: {
                LinuxIrohControllerCredentialContext(
                    uid: route.uid,
                    sessionGeneration: 1,
                    idToken: "id-token",
                    appCheckToken: "app-check",
                    deviceID: deviceID
                )
            },
            authorityReadiness: { _, _ in true }
        )
        await runtime.installHandlers(
            grant: { _, _ in },
            approval: { _, _, _, _ in },
            panic: { _, _, _, _ in },
            revokeSessions: { _, _ in },
            media: { _, _, _ in }
        )

        let startTask = Task { try await runtime.start() }
        var stopTask: Task<Void, Never>?
        do {
            try await eventually(timeout: 10) { await directory.isRecordPublicationSuspended() }
            let task = Task { await runtime.stop() }
            stopTask = task
            try await eventually(timeout: 10) { await runtime.status().phase == .stopping }
            await directory.releaseRecordPublication()
            await task.value
        } catch {
            startTask.cancel()
            await directory.releaseRecordPublication()
            await stopTask?.value
            _ = await startTask.result
            throw error
        }
        var startupWasCancelled = false
        do {
            try await startTask.value
            XCTFail("A stopped startup must not complete")
        } catch is CancellationError {
            startupWasCancelled = true
        } catch {
            XCTFail("Unexpected startup error: \(error)")
        }
        XCTAssertTrue(startupWasCancelled)
        let counts = await directory.counts()
        XCTAssertEqual(counts.2, [connectionID])
        let status = await runtime.status()
        XCTAssertEqual(status.phase, .stopped)
        XCTAssertEqual(status.reason, .stoppedByOwner)
    }

    func testExactRouteControlsReadinessPublicationAndShutdownRevocation() async throws {
        let uid = "user-1"
        let deviceID = "linux-device"
        let connectionID = "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
        let transportNodeID = String(repeating: "a", count: 64)
        let authorityID = "ios-authority"
        let expiry = Date().addingTimeInterval(600)
        let route = LinuxIrohControllerRoute(
            uid: uid,
            connectionID: connectionID,
            sourceDeviceID: "ios-device",
            transportNodeID: transportNodeID,
            authorityPeerNodeID: authorityID,
            generation: 7,
            registeredAt: Date(),
            expiresAt: expiry,
            accountGeneration: 3
        )
        let directory = TestLinuxIrohDirectory(route: route)
        let transport = TestLinuxIrohTransport(identity: IrohEndpointIdentity(
            nodeId: String(repeating: "b", count: 64),
            rawPublicKey: Data(repeating: 0xBB, count: 32),
            relayURL: "https://relay.example"
        ))
        let hostIdentity = LinuxIrohHostIdentity(
            endpointSecret: IrohSecretKeyMaterial(raw: Data(repeating: 0x11, count: 32)),
            pairingKeypair: IrohPairingKeypair(signingKey: PlatformCrypto.ed25519PrivateKey())
        )
        let runtime = LinuxIrohControllerRuntime(
            transport: transport,
            directory: directory,
            identityStore: TestLinuxIrohIdentityProvider(identity: hostIdentity),
            credentialProvider: {
                LinuxIrohControllerCredentialContext(
                    uid: uid,
                    sessionGeneration: 3,
                    idToken: "id-token",
                    appCheckToken: "app-check",
                    deviceID: deviceID
                )
            },
            authorityReadiness: { source, authority in
                source == "ios-device" && authority == authorityID
            },
            refreshIntervalNanoseconds: 60_000_000_000,
            acceptTimeout: 0.1
        )
        let revocations = TestLinuxIrohRevocations()
        let panicIngress = TestLinuxIrohPanicIngress()
        await runtime.installHandlers(
            grant: { _, _ in },
            approval: { _, _, _, _ in },
            panic: { sessionIDs, _, _, _ in await panicIngress.record(sessionIDs) },
            revokeSessions: { sessionIDs, reason in
                await revocations.append(sessionIDs: sessionIDs, reason: reason)
            },
            media: { _, _, _ in }
        )
        try await runtime.start()
        let initiallyReady = await runtime.isReady()
        XCTAssertFalse(initiallyReady)

        let classify = HermesRealtimeRelayFrame(
            type: .mediaClassify,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(streamClass: "media.control")
        )
        let wrongPeer = TestLinuxIrohStream(
            remotePeerNodeId: String(repeating: "c", count: 64),
            inbound: [classify]
        )
        await transport.enqueue(wrongPeer)
        try await eventually { await wrongPeer.isClosed() }
        let readyAfterWrongPeer = await runtime.isReady()
        XCTAssertFalse(readyAfterWrongPeer)

        let controllerStream = TestLinuxIrohStream(remotePeerNodeId: transportNodeID, inbound: [classify])
        await transport.enqueue(controllerStream)
        try await eventually { await runtime.isReady() }

        let metadata = ComputerUseSessionGrantBroker.AcquisitionMetadata(
            uid: uid,
            connectionID: connectionID,
            transportPeerNodeID: transportNodeID,
            authorityPeerNodeID: authorityID,
            sourceDeviceID: "ios-device",
            runtimeID: .hermes,
            threadID: "thread-1",
            preset: .desktop,
            capabilities: [.desktopBrowser, .desktopScreenshot],
            routeGeneration: 7,
            routeExpiresAt: expiry,
            accountGeneration: 3
        )
        try await runtime.bindSession("session-1", metadata: metadata)
        let exactAuthorityAccepted = await runtime.authorizesSessionAuthority(
            sessionID: "session-1",
            authorityPeerNodeID: authorityID,
            transportPeerNodeID: transportNodeID,
            routeGeneration: 7
        )
        let otherAuthorityAccepted = await runtime.authorizesSessionAuthority(
            sessionID: "session-1",
            authorityPeerNodeID: "other-pinned-authority",
            transportPeerNodeID: transportNodeID,
            routeGeneration: 7
        )
        XCTAssertTrue(exactAuthorityAccepted)
        XCTAssertFalse(otherAuthorityAccepted)
        try await runtime.bindSession("session-2", metadata: metadata)
        let panicIntent = HermesRealtimeRelayInputIntent(
            kind: .panic,
            clientIntentId: "panic-route-wide",
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: authorityID,
                counter: 1,
                timestamp: Date(),
                intentHashBlake3: "signed-panic",
                signatureEd25519: "signature"
            )
        )
        await controllerStream.enqueue(HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.input",
                sessionId: "session-1",
                inputIntent: panicIntent
            )
        ))
        try await eventually {
            await panicIngress.containsExactly(["session-1", "session-2"])
        }
        let renewedRoute = LinuxIrohControllerRoute(
            uid: route.uid,
            connectionID: route.connectionID,
            sourceDeviceID: route.sourceDeviceID,
            transportNodeID: route.transportNodeID,
            authorityPeerNodeID: route.authorityPeerNodeID,
            generation: 7,
            registeredAt: route.registeredAt,
            expiresAt: route.expiresAt.addingTimeInterval(300),
            accountGeneration: route.accountGeneration
        )
        await directory.updateRoute(renewedRoute)
        await directory.failNextResolutions(2)
        await runtime.refreshNow()
        let renewedAuthorityAccepted = await runtime.authorizesSessionAuthority(
            sessionID: "session-1",
            authorityPeerNodeID: authorityID,
            transportPeerNodeID: transportNodeID,
            routeGeneration: 7
        )
        XCTAssertTrue(renewedAuthorityAccepted)
        let streamClosedDuringRenewal = await controllerStream.isClosed()
        XCTAssertFalse(streamClosedDuringRenewal)
        let renewedStatus = await runtime.status()
        XCTAssertEqual(renewedStatus.phase, .running)
        XCTAssertEqual(renewedStatus.reason, .none)
        try await runtime.bindSession("session-late-bind", metadata: metadata)
        let approval = HermesRealtimeRelayApprovalRequest(
            approvalId: "approval-1",
            runId: "run-1",
            sessionId: "session-1",
            toolKind: "browser_click",
            title: "Approve action",
            message: "Approve browser click",
            actionSummary: "Click",
            requestedAt: Date()
        )
        try await runtime.publishApproval(approval)
        try await eventually {
            await controllerStream.sentFrames().contains { frame in
                frame.type == .controlApprovalRequest
                    && frame.control?.approvalRequest?.approvalId == "approval-1"
            }
        }

        let replacementRoute = LinuxIrohControllerRoute(
            uid: renewedRoute.uid,
            connectionID: renewedRoute.connectionID,
            sourceDeviceID: renewedRoute.sourceDeviceID,
            transportNodeID: renewedRoute.transportNodeID,
            authorityPeerNodeID: renewedRoute.authorityPeerNodeID,
            generation: 8,
            registeredAt: renewedRoute.registeredAt.addingTimeInterval(1),
            expiresAt: renewedRoute.expiresAt.addingTimeInterval(300),
            accountGeneration: renewedRoute.accountGeneration
        )
        await directory.updateRoute(replacementRoute)
        await runtime.refreshNow()
        try await eventually { await controllerStream.isClosed() }
        let replacedSessionRevoked = await revocations.contains(
            sessionID: "session-1",
            reason: "controller_route_replaced"
        )
        XCTAssertTrue(replacedSessionRevoked)
        let lateBoundSessionRevoked = await revocations.contains(
            sessionID: "session-late-bind",
            reason: "controller_route_replaced"
        )
        XCTAssertTrue(lateBoundSessionRevoked)

        let replacementStream = TestLinuxIrohStream(
            remotePeerNodeId: transportNodeID,
            inbound: [classify]
        )
        await transport.enqueue(replacementStream)
        try await eventually { await runtime.isReady() }
        let replacementMetadata = ComputerUseSessionGrantBroker.AcquisitionMetadata(
            uid: uid,
            connectionID: connectionID,
            transportPeerNodeID: transportNodeID,
            authorityPeerNodeID: authorityID,
            sourceDeviceID: "ios-device",
            runtimeID: .hermes,
            threadID: "thread-3",
            preset: .desktop,
            capabilities: [.desktopBrowser, .desktopScreenshot],
            routeGeneration: 8,
            routeExpiresAt: replacementRoute.expiresAt,
            accountGeneration: 3
        )
        try await runtime.bindSession("session-3", metadata: replacementMetadata)

        await directory.failNextRevocations(2)
        await runtime.stop()
        let transportStopped = await transport.isStopped()
        let streamClosed = await replacementStream.isClosed()
        XCTAssertTrue(transportStopped)
        XCTAssertTrue(streamClosed)
        let stoppedSessionRevoked = await revocations.contains(
            sessionID: "session-3",
            reason: "controller_runtime_stopped"
        )
        XCTAssertTrue(stoppedSessionRevoked)
        let counts = await directory.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 3)
        XCTAssertEqual(counts.2, [connectionID])
    }

    func testInboundFrameAfterAuthorityRevocationStopsRuntimeBeforeDispatch() async throws {
        let uid = "user-authority-revoked"
        let deviceID = "linux-authority-revoked"
        let connectionID = "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
        let transportNodeID = String(repeating: "d", count: 64)
        let authorityID = "authority-revoked"
        let route = LinuxIrohControllerRoute(
            uid: uid,
            connectionID: connectionID,
            sourceDeviceID: "phone-revoked",
            transportNodeID: transportNodeID,
            authorityPeerNodeID: authorityID,
            generation: 1,
            registeredAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            accountGeneration: 1
        )
        let directory = TestLinuxIrohDirectory(route: route)
        let transport = TestLinuxIrohTransport(identity: IrohEndpointIdentity(
            nodeId: String(repeating: "e", count: 64),
            rawPublicKey: Data(repeating: 0xEE, count: 32)
        ))
        let authorityGate = TestLinuxIrohAuthorityGate(allowed: true)
        let panicIngress = TestLinuxIrohPanicIngress()
        let revocations = TestLinuxIrohRevocations()
        let runtime = LinuxIrohControllerRuntime(
            transport: transport,
            directory: directory,
            identityStore: TestLinuxIrohIdentityProvider(identity: LinuxIrohHostIdentity(
                endpointSecret: IrohSecretKeyMaterial(raw: Data(repeating: 0x44, count: 32)),
                pairingKeypair: IrohPairingKeypair(signingKey: PlatformCrypto.ed25519PrivateKey())
            )),
            credentialProvider: {
                LinuxIrohControllerCredentialContext(
                    uid: uid,
                    sessionGeneration: 1,
                    idToken: "id-token",
                    appCheckToken: "app-check",
                    deviceID: deviceID
                )
            },
            authorityReadiness: { _, _ in await authorityGate.isAllowed() },
            refreshIntervalNanoseconds: 60_000_000_000,
            acceptTimeout: 0.1
        )
        await runtime.installHandlers(
            grant: { _, _ in },
            approval: { _, _, _, _ in },
            panic: { sessionIDs, _, _, _ in await panicIngress.record(sessionIDs) },
            revokeSessions: { sessionIDs, reason in
                await revocations.append(sessionIDs: sessionIDs, reason: reason)
            },
            media: { _, _, _ in }
        )

        try await runtime.start()
        let classify = HermesRealtimeRelayFrame(
            type: .mediaClassify,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(streamClass: "media.control")
        )
        let stream = TestLinuxIrohStream(
            remotePeerNodeId: transportNodeID,
            inbound: [classify]
        )
        await transport.enqueue(stream)
        try await eventually { await runtime.isReady() }

        let metadata = ComputerUseSessionGrantBroker.AcquisitionMetadata(
            uid: uid,
            connectionID: connectionID,
            transportPeerNodeID: transportNodeID,
            authorityPeerNodeID: authorityID,
            sourceDeviceID: "phone-revoked",
            runtimeID: .hermes,
            threadID: "thread-revoked",
            preset: .desktop,
            capabilities: [.desktopBrowser, .desktopScreenshot],
            routeGeneration: route.generation,
            routeExpiresAt: route.expiresAt,
            accountGeneration: route.accountGeneration
        )
        try await runtime.bindSession("session-revoked", metadata: metadata)

        await authorityGate.setAllowed(false)
        let panicIntent = HermesRealtimeRelayInputIntent(
            kind: .panic,
            clientIntentId: "panic-after-revocation",
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: authorityID,
                counter: 1,
                timestamp: Date(),
                intentHashBlake3: "signed-panic",
                signatureEd25519: "signature"
            )
        )
        await stream.enqueue(HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.input",
                sessionId: "session-revoked",
                inputIntent: panicIntent
            )
        ))

        try await eventually(timeout: 5) { (await runtime.status()).phase == .stopped }
        let status = await runtime.status()
        let panicWasNotDispatched = await panicIngress.containsExactly([])
        let streamClosed = await stream.isClosed()
        let sessionRevoked = await revocations.containsSession("session-revoked")
        XCTAssertEqual(status.reason, .routeUnavailable)
        XCTAssertTrue(panicWasNotDispatched)
        XCTAssertTrue(streamClosed)
        XCTAssertTrue(sessionRevoked)
    }

    func testAmbiguousHostRecordPublicationIsCompensatedBeforeStateClears() async throws {
        let deviceID = "linux-ambiguous-publication"
        let connectionID = "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
        let route = LinuxIrohControllerRoute(
            uid: "user-ambiguous-publication",
            connectionID: connectionID,
            sourceDeviceID: "phone-ambiguous-publication",
            transportNodeID: String(repeating: "3", count: 64),
            authorityPeerNodeID: "authority-ambiguous-publication",
            generation: 1,
            registeredAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            accountGeneration: 1
        )
        let directory = TestLinuxIrohDirectory(route: route)
        await directory.failRecordPublicationsAfterApply(4)
        let transport = TestLinuxIrohTransport(identity: IrohEndpointIdentity(
            nodeId: String(repeating: "4", count: 64),
            rawPublicKey: Data(repeating: 0x44, count: 32)
        ))
        let runtime = LinuxIrohControllerRuntime(
            transport: transport,
            directory: directory,
            identityStore: TestLinuxIrohIdentityProvider(identity: LinuxIrohHostIdentity(
                endpointSecret: IrohSecretKeyMaterial(raw: Data(repeating: 0x77, count: 32)),
                pairingKeypair: IrohPairingKeypair(signingKey: PlatformCrypto.ed25519PrivateKey())
            )),
            credentialProvider: {
                LinuxIrohControllerCredentialContext(
                    uid: route.uid,
                    sessionGeneration: 1,
                    idToken: "id-token",
                    appCheckToken: "app-check",
                    deviceID: deviceID
                )
            },
            authorityReadiness: { _, _ in true }
        )
        await runtime.installHandlers(
            grant: { _, _ in },
            approval: { _, _, _, _ in },
            panic: { _, _, _, _ in },
            revokeSessions: { _, _ in },
            media: { _, _, _ in }
        )

        do {
            try await runtime.start()
            XCTFail("An ambiguous host-record publication must fail startup")
        } catch {
            XCTAssertEqual(error as? LinuxIrohControllerDirectoryError, .transportFailure)
        }
        let counts = await directory.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 4)
        XCTAssertEqual(counts.2, [connectionID])
        let status = await runtime.status()
        XCTAssertEqual(status.phase, .stopped)
        XCTAssertEqual(status.reason, .directoryUnavailable)
        let transportStopped = await transport.isStopped()
        XCTAssertTrue(transportStopped)
    }

    func testAccountGenerationChangeBeforeBindFailsClosed() async throws {
        let uid = "user-account-switch"
        let deviceID = "linux-account-switch"
        let connectionID = "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
        let transportNodeID = String(repeating: "e", count: 64)
        let expiry = Date().addingTimeInterval(600)
        let route = LinuxIrohControllerRoute(
            uid: uid,
            connectionID: connectionID,
            sourceDeviceID: "phone-account-switch",
            transportNodeID: transportNodeID,
            authorityPeerNodeID: "authority-account-switch",
            generation: 2,
            registeredAt: Date(),
            expiresAt: expiry,
            accountGeneration: 10
        )
        let transport = TestLinuxIrohTransport(identity: IrohEndpointIdentity(
            nodeId: String(repeating: "f", count: 64),
            rawPublicKey: Data(repeating: 0xFF, count: 32)
        ))
        let credentialStore = TestLinuxIrohCredentialStore(LinuxIrohControllerCredentialContext(
            uid: uid,
            sessionGeneration: 10,
            idToken: "id-token",
            appCheckToken: "app-check",
            deviceID: deviceID
        ))
        let runtime = LinuxIrohControllerRuntime(
            transport: transport,
            directory: TestLinuxIrohDirectory(route: route),
            identityStore: TestLinuxIrohIdentityProvider(identity: LinuxIrohHostIdentity(
                endpointSecret: IrohSecretKeyMaterial(raw: Data(repeating: 0x55, count: 32)),
                pairingKeypair: IrohPairingKeypair(signingKey: PlatformCrypto.ed25519PrivateKey())
            )),
            credentialProvider: { await credentialStore.value() },
            authorityReadiness: { _, _ in true }
        )
        await runtime.installHandlers(
            grant: { _, _ in },
            approval: { _, _, _, _ in },
            panic: { _, _, _, _ in },
            revokeSessions: { _, _ in },
            media: { _, _, _ in }
        )
        try await runtime.start()
        let classify = HermesRealtimeRelayFrame(
            type: .mediaClassify,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(streamClass: "media.control")
        )
        let stream = TestLinuxIrohStream(remotePeerNodeId: transportNodeID, inbound: [classify])
        await transport.enqueue(stream)
        try await eventually { await runtime.isReady() }
        let metadata = ComputerUseSessionGrantBroker.AcquisitionMetadata(
            uid: uid,
            connectionID: connectionID,
            transportPeerNodeID: transportNodeID,
            authorityPeerNodeID: route.authorityPeerNodeID,
            sourceDeviceID: route.sourceDeviceID,
            runtimeID: .hermes,
            threadID: "thread-account-switch",
            preset: .desktop,
            capabilities: [.desktopBrowser],
            routeGeneration: route.generation,
            routeExpiresAt: expiry,
            accountGeneration: 10
        )

        await credentialStore.update(LinuxIrohControllerCredentialContext(
            uid: uid,
            sessionGeneration: 11,
            idToken: "new-id-token",
            appCheckToken: "new-app-check",
            deviceID: deviceID
        ))
        do {
            try await runtime.bindSession("session-account-switch", metadata: metadata)
            XCTFail("A prior-account route must not bind after account generation changes")
        } catch {
            XCTAssertEqual(error as? LinuxIrohControllerRuntime.RuntimeError, .routeUnavailable)
        }
        try await eventually {
            let status = await runtime.status()
            return status.phase == .stopped && status.reason == .credentialsChanged
        }
        let streamClosed = await stream.isClosed()
        XCTAssertTrue(streamClosed)
    }

    func testCredentialInvalidationIsSingleFlightAndOwnerStopCannotRaceCleanup() async throws {
        let uid = "user-terminal-single-flight"
        let deviceID = "linux-terminal-single-flight"
        let connectionID = "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
        let transportNodeID = String(repeating: "9", count: 64)
        let route = LinuxIrohControllerRoute(
            uid: uid,
            connectionID: connectionID,
            sourceDeviceID: "phone-terminal-single-flight",
            transportNodeID: transportNodeID,
            authorityPeerNodeID: "authority-terminal-single-flight",
            generation: 3,
            registeredAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            accountGeneration: 12
        )
        let directory = TestLinuxIrohDirectory(route: route)
        let transport = TestLinuxIrohTransport(identity: IrohEndpointIdentity(
            nodeId: String(repeating: "8", count: 64),
            rawPublicKey: Data(repeating: 0x88, count: 32)
        ))
        let validCredentials = LinuxIrohControllerCredentialContext(
            uid: uid,
            sessionGeneration: 12,
            idToken: "id-token",
            appCheckToken: "app-check",
            deviceID: deviceID
        )
        let credentialStore = TestLinuxIrohCredentialStore(validCredentials)
        let routeEndGate = TestLinuxIrohRouteEndGate()
        let runtime = LinuxIrohControllerRuntime(
            transport: transport,
            directory: directory,
            identityStore: TestLinuxIrohIdentityProvider(identity: LinuxIrohHostIdentity(
                endpointSecret: IrohSecretKeyMaterial(raw: Data(repeating: 0x99, count: 32)),
                pairingKeypair: IrohPairingKeypair(signingKey: PlatformCrypto.ed25519PrivateKey())
            )),
            credentialProvider: { await credentialStore.value() },
            authorityReadiness: { _, _ in true },
            refreshIntervalNanoseconds: 60_000_000_000,
            acceptTimeout: 0.1
        )
        await runtime.installHandlers(
            grant: { _, _ in },
            approval: { _, _, _, _ in },
            panic: { _, _, _, _ in },
            revokeSessions: { _, _ in },
            routeEnded: { _, _ in await routeEndGate.suspend() },
            media: { _, _, _ in }
        )
        try await runtime.start()
        let classify = HermesRealtimeRelayFrame(
            type: .mediaClassify,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(streamClass: "media.control")
        )
        let stream = TestLinuxIrohStream(remotePeerNodeId: transportNodeID, inbound: [classify])
        await transport.enqueue(stream)
        try await eventually { await runtime.isReady() }

        await credentialStore.update(LinuxIrohControllerCredentialContext(
            uid: uid,
            sessionGeneration: 13,
            idToken: "replacement-id-token",
            appCheckToken: "replacement-app-check",
            deviceID: deviceID
        ))
        let readinessA = Task { await runtime.isReady() }
        let readinessB = Task { await runtime.isReady() }
        let readinessResultA = await readinessA.value
        let readinessResultB = await readinessB.value
        XCTAssertFalse(readinessResultA)
        XCTAssertFalse(readinessResultB)
        try await eventually { await routeEndGate.hasEntered() }

        let stopTask = Task { await runtime.stop() }
        try await eventually {
            let status = await runtime.status()
            return status.phase == .stopping
        }
        var startWasRejected = false
        do {
            try await runtime.start()
            XCTFail("A successor must not start while terminal cleanup owns the runtime")
        } catch is CancellationError {
            startWasRejected = true
        } catch {
            XCTFail("Unexpected successor start error: \(error)")
        }
        XCTAssertTrue(startWasRejected)
        await routeEndGate.release()
        await stopTask.value
        let routeEndCount = await routeEndGate.count()
        XCTAssertEqual(routeEndCount, 1)
        let countsAfterInvalidation = await directory.counts()
        XCTAssertEqual(countsAfterInvalidation.2, [connectionID])

        await credentialStore.update(validCredentials)
        try await runtime.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        let successorStatus = await runtime.status()
        XCTAssertEqual(successorStatus.phase, .running)
        let successorTransportStopped = await transport.isStopped()
        XCTAssertFalse(successorTransportStopped)
        await runtime.stop()
    }

    func testOlderRefreshCannotResurrectRouteAfterNewerAuthoritativeEmpty() async throws {
        let uid = "user-refresh-order"
        let deviceID = "linux-refresh-order"
        let connectionID = "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
        let transportNodeID = String(repeating: "1", count: 64)
        let route = LinuxIrohControllerRoute(
            uid: uid,
            connectionID: connectionID,
            sourceDeviceID: "phone-refresh-order",
            transportNodeID: transportNodeID,
            authorityPeerNodeID: "authority-refresh-order",
            generation: 4,
            registeredAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            accountGeneration: 6
        )
        let directory = TestLinuxIrohDirectory(route: route)
        let transport = TestLinuxIrohTransport(identity: IrohEndpointIdentity(
            nodeId: String(repeating: "2", count: 64),
            rawPublicKey: Data(repeating: 0x22, count: 32)
        ))
        let runtime = LinuxIrohControllerRuntime(
            transport: transport,
            directory: directory,
            identityStore: TestLinuxIrohIdentityProvider(identity: LinuxIrohHostIdentity(
                endpointSecret: IrohSecretKeyMaterial(raw: Data(repeating: 0x66, count: 32)),
                pairingKeypair: IrohPairingKeypair(signingKey: PlatformCrypto.ed25519PrivateKey())
            )),
            credentialProvider: {
                LinuxIrohControllerCredentialContext(
                    uid: uid,
                    sessionGeneration: 6,
                    idToken: "id-token",
                    appCheckToken: "app-check",
                    deviceID: deviceID
                )
            },
            authorityReadiness: { _, _ in true }
        )
        await runtime.installHandlers(
            grant: { _, _ in },
            approval: { _, _, _, _ in },
            panic: { _, _, _, _ in },
            revokeSessions: { _, _ in },
            media: { _, _, _ in }
        )
        try await runtime.start()
        let classify = HermesRealtimeRelayFrame(
            type: .mediaClassify,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(streamClass: "media.control")
        )
        let stream = TestLinuxIrohStream(remotePeerNodeId: transportNodeID, inbound: [classify])
        await transport.enqueue(stream)
        try await eventually { await runtime.isReady() }

        await directory.controlNextResolutions(2)
        let olderRefresh = Task { await runtime.refreshNow() }
        try await eventually { await directory.controlledRequestCount() == 1 }
        let newerRefresh = Task { await runtime.refreshNow() }
        try await eventually { await directory.controlledRequestCount() == 2 }
        await directory.releaseControlledResolution(1, route: nil)
        await newerRefresh.value
        try await eventually { await stream.isClosed() }
        let revokedStatus = await runtime.status()
        XCTAssertEqual(revokedStatus.reason, .routeUnavailable)

        await directory.releaseControlledResolution(0, route: route)
        await olderRefresh.value
        let finalStatus = await runtime.status()
        XCTAssertEqual(finalStatus.reason, .routeUnavailable)
        let readyAfterStaleResponse = await runtime.isReady()
        XCTAssertFalse(readyAfterStaleResponse)
        await runtime.stop()
    }

    func testRouteExpiryClosesEstablishedStreamAndRevokesBoundSession() async throws {
        let uid = "user-expiry"
        let deviceID = "linux-expiry-device"
        let connectionID = "linux-host-" + String(PlatformCrypto.sha256Hex(Data(deviceID.utf8)).prefix(32))
        let transportNodeID = String(repeating: "d", count: 64)
        let authorityID = "ios-expiry-authority"
        let expiry = Date().addingTimeInterval(0.5)
        let route = LinuxIrohControllerRoute(
            uid: uid,
            connectionID: connectionID,
            sourceDeviceID: "ios-expiry-device",
            transportNodeID: transportNodeID,
            authorityPeerNodeID: authorityID,
            generation: 9,
            registeredAt: Date(),
            expiresAt: expiry,
            accountGeneration: 4
        )
        let directory = TestLinuxIrohDirectory(route: route)
        let transport = TestLinuxIrohTransport(identity: IrohEndpointIdentity(
            nodeId: String(repeating: "e", count: 64),
            rawPublicKey: Data(repeating: 0xEE, count: 32),
            relayURL: "https://relay.example"
        ))
        let runtime = LinuxIrohControllerRuntime(
            transport: transport,
            directory: directory,
            identityStore: TestLinuxIrohIdentityProvider(identity: LinuxIrohHostIdentity(
                endpointSecret: IrohSecretKeyMaterial(raw: Data(repeating: 0x22, count: 32)),
                pairingKeypair: IrohPairingKeypair(signingKey: PlatformCrypto.ed25519PrivateKey())
            )),
            credentialProvider: {
                LinuxIrohControllerCredentialContext(
                    uid: uid,
                    sessionGeneration: 4,
                    idToken: "id-token",
                    appCheckToken: "app-check",
                    deviceID: deviceID
                )
            },
            authorityReadiness: { _, _ in true },
            refreshIntervalNanoseconds: 60_000_000_000,
            acceptTimeout: 0.1
        )
        let revocations = TestLinuxIrohRevocations()
        await runtime.installHandlers(
            grant: { _, _ in },
            approval: { _, _, _, _ in },
            panic: { _, _, _, _ in },
            revokeSessions: { sessionIDs, reason in
                await revocations.append(sessionIDs: sessionIDs, reason: reason)
            },
            media: { _, _, _ in }
        )
        try await runtime.start()
        let classify = HermesRealtimeRelayFrame(
            type: .mediaClassify,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(streamClass: "media.control")
        )
        let controllerStream = TestLinuxIrohStream(remotePeerNodeId: transportNodeID, inbound: [classify])
        await transport.enqueue(controllerStream)
        try await eventually { await runtime.isReady() }
        try await runtime.bindSession(
            "session-expiry",
            metadata: ComputerUseSessionGrantBroker.AcquisitionMetadata(
                uid: uid,
                connectionID: connectionID,
                transportPeerNodeID: transportNodeID,
                authorityPeerNodeID: authorityID,
                sourceDeviceID: "ios-expiry-device",
                runtimeID: .hermes,
                threadID: "thread-expiry",
                preset: .desktop,
                capabilities: [.desktopBrowser, .desktopScreenshot],
                routeGeneration: 9,
                routeExpiresAt: expiry,
                accountGeneration: 4
            )
        )

        try await eventually {
            let closed = await controllerStream.isClosed()
            let revoked = await revocations.contains(
                sessionID: "session-expiry",
                reason: "controller_route_expired"
            )
            return closed && revoked
        }
        let readyAfterExpiry = await runtime.isReady()
        XCTAssertFalse(readyAfterExpiry)
        await runtime.stop()
    }

    private func eventually(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true before timeout", file: file, line: line)
        throw WaitError.timedOut
    }
}
#endif

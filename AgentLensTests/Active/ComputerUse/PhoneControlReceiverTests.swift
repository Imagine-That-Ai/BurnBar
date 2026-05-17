#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import XCTest
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBar

final class PhoneControlReceiverTests: XCTestCase {
    @MainActor
    func testIrohRequestHandlerRoutesControlStreamIntoCoordinator() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "ios-phone-stream"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-stream",
            expectedConnectionID: "conn-stream",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-stream",
                macHostNodeId: "mac-stream",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-17"),
                auditBaseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("computer-use-handler-stream-\(UUID().uuidString)", isDirectory: true),
                macAppVersion: "test"
            ),
            authorityProvider: provider,
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 500)]
            },
            approvalPresenter: { request, _ in
                HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .approve,
                    respondedBy: "test",
                    respondedAt: Date()
                )
            }
        )
        let started = try await coordinator.startSession(
            request: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "client-stream")
            )
        )
        let classify = HermesRealtimeRelayFrame(
            type: .controlClassify,
            uid: "uid-stream",
            connectionId: "conn-stream",
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                sessionId: started.sessionId,
                authorityPeerNodeId: peerNodeId
            )
        )
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(kind: .panic, authority: placeholder)
        let signed = try ComputerUsePhoneControlSigner().sign(
            intent: intent,
            peerNodeId: peerNodeId,
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)
        let signedInput = HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: "uid-stream",
            connectionId: "conn-stream",
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                sessionId: started.sessionId,
                inputIntent: intent
            )
        )
        let stream = PhoneControlRecordingIrohStream(inbound: [classify, signedInput])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhoneControlReceiverTests.\(UUID().uuidString)"))
        let handler = IrohRelayRequestHandler(
            relayKeyStore: HermesRelayKeyStore(),
            urlSession: .shared,
            settingsManager: SettingsManager(defaults: defaults, flushDelayNanoseconds: 0),
            controlDispatcher: coordinator.controlDispatcher
        )

        try await handler.serve(stream: stream, uid: "uid-stream", connectionID: "conn-stream")

        let sentFrames = await stream.sentFrames()
        let fetchCount = await provider.fetchCount
        XCTAssertTrue(sentFrames.isEmpty)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(coordinator.state?.endReason, .panicPhoneGesture)
        XCTAssertEqual(coordinator.actionTimeline.last?.status, .panicHalted)
    }

    @MainActor
    func testCoordinatorClassifyRegistersAuthorityAndSignedPanicHaltsSession() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let peerNodeId = "android-phone-loopback"
        let provider = StaticPhoneControlAuthorityProvider(
            expectedUID: "uid-loopback",
            expectedConnectionID: "conn-loopback",
            expectedPeerNodeID: peerNodeId,
            publicKey: privateKey.publicKey
        )
        let replies = PhoneControlReceiverCapture()
        let coordinator = ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-loopback",
                macHostNodeId: "mac-loopback",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true,
                    allowsPhoneControl: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-05-17"),
                auditBaseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("computer-use-coordinator-loopback-\(UUID().uuidString)", isDirectory: true),
                macAppVersion: "test"
            ),
            authorityProvider: provider,
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 500)]
            },
            approvalPresenter: { request, _ in
                HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .approve,
                    respondedBy: "test",
                    respondedAt: Date()
                )
            }
        )
        let started = try await coordinator.startSession(
            request: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "client-loopback")
            )
        )

        let dispatcher = coordinator.controlDispatcher
        await dispatcher(
            HermesRealtimeRelayFrame(
                type: .controlClassify,
                uid: "uid-loopback",
                connectionId: "conn-loopback",
                control: HermesRealtimeRelayControlPayload(
                    streamClass: MediaStreamClass.controlInput.rawValue,
                    sessionId: started.sessionId,
                    authorityPeerNodeId: peerNodeId
                )
            ),
            { frame in await replies.recordDenied(frame) }
        )

        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(kind: .panic, authority: placeholder)
        let signed = try ComputerUsePhoneControlSigner().sign(
            intent: intent,
            peerNodeId: peerNodeId,
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)
        await dispatcher(
            HermesRealtimeRelayFrame(
                type: .controlInputIntent,
                uid: "uid-loopback",
                connectionId: "conn-loopback",
                control: HermesRealtimeRelayControlPayload(
                    streamClass: MediaStreamClass.controlInput.rawValue,
                    sessionId: started.sessionId,
                    inputIntent: intent
                )
            ),
            { frame in await replies.recordDenied(frame) }
        )

        let fetchCount = await provider.fetchCount
        let deniedFrames = await replies.deniedFrames()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(coordinator.state?.endReason, .panicPhoneGesture)
        XCTAssertEqual(coordinator.actionTimeline.last?.status, .panicHalted)
        XCTAssertTrue(deniedFrames.isEmpty)
    }

    func testSignedScrollIntentDispatchesMacScrollAction() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(
            kind: .scroll,
            normalizedX: 0.40,
            normalizedY: 0.50,
            normalizedX2: 0.40,
            normalizedY2: 0.20,
            authority: placeholder
        )
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "phone-peer",
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)

        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "phone-peer", publicKey: privateKey.publicKey)
        let capture = PhoneControlReceiverCapture()
        let receiver = PhoneControlReceiver(
            sessionId: ComputerUseSessionID("session-phone"),
            validator: validator,
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 500)]
            },
            dispatchHandler: { action, sessionId in
                await capture.record(action: action, sessionId: sessionId)
            },
            denyFrameSink: { frame in
                await capture.recordDenied(frame)
            }
        )

        await receiver.ingest(frame(intent))

        let dispatched = try await capture.firstAction()
        XCTAssertEqual(dispatched.sessionId, ComputerUseSessionID("session-phone"))
        guard case let .macInput(action) = dispatched.action else {
            return XCTFail("expected macInput action")
        }
        XCTAssertEqual(action.kind, .scroll)
        XCTAssertEqual(action.displayX, 400)
        XCTAssertEqual(action.displayY, 250)
        XCTAssertEqual(action.dragEndX, 400)
        XCTAssertEqual(action.dragEndY, 100)
        let deniedFrames = await capture.deniedFrames()
        XCTAssertTrue(deniedFrames.isEmpty)
    }

    func testMalformedScrollCoordinatesEmitDeniedFrame() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUsePhoneControlSigner()
        let placeholder = emptyAuthority()
        var intent = HermesRealtimeRelayInputIntent(
            kind: .scroll,
            normalizedX: 1.20,
            normalizedY: 0.50,
            normalizedX2: 0.40,
            normalizedY2: 0.20,
            authority: placeholder
        )
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: "phone-peer",
            counter: 1,
            timestamp: Date(),
            privateKey: privateKey
        )
        intent.authority = envelope(from: signed)

        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "phone-peer", publicKey: privateKey.publicKey)
        let capture = PhoneControlReceiverCapture()
        let receiver = PhoneControlReceiver(
            sessionId: ComputerUseSessionID("session-phone"),
            validator: validator,
            displayBoundsProvider: {
                [MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1_000, height: 500)]
            },
            dispatchHandler: { action, sessionId in
                await capture.record(action: action, sessionId: sessionId)
            },
            denyFrameSink: { frame in
                await capture.recordDenied(frame)
            }
        )

        await receiver.ingest(frame(intent))

        let actions = await capture.actions()
        XCTAssertTrue(actions.isEmpty)
        let deniedFrames = await capture.deniedFrames()
        let denied = try XCTUnwrap(deniedFrames.first)
        XCTAssertEqual(denied.type, .controlDenied)
        XCTAssertEqual(denied.control?.denied?.reason, .unknown)
        XCTAssertEqual(denied.control?.denied?.detail, "malformed_coordinates")
    }

    private func frame(_ intent: HermesRealtimeRelayInputIntent) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: "uid-phone",
            connectionId: "relay-phone",
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                inputIntent: intent
            )
        )
    }

    private func emptyAuthority() -> HermesRealtimeRelayAuthorityEnvelope {
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
    }

    private func envelope(
        from signed: ComputerUsePhoneControlSigner.SignedAuthority
    ) -> HermesRealtimeRelayAuthorityEnvelope {
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )
    }
}

private actor PhoneControlReceiverCapture {
    struct DispatchedAction: Sendable {
        let action: ComputerUseAction
        let sessionId: ComputerUseSessionID
    }

    private var recordedActions: [DispatchedAction] = []
    private var recordedDeniedFrames: [HermesRealtimeRelayFrame] = []

    func record(action: ComputerUseAction, sessionId: ComputerUseSessionID) {
        recordedActions.append(DispatchedAction(action: action, sessionId: sessionId))
    }

    func recordDenied(_ frame: HermesRealtimeRelayFrame) {
        recordedDeniedFrames.append(frame)
    }

    func actions() -> [DispatchedAction] {
        recordedActions
    }

    func firstAction() throws -> DispatchedAction {
        guard let action = recordedActions.first else {
            throw NSError(domain: "PhoneControlReceiverCapture", code: 1)
        }
        return action
    }

    func deniedFrames() -> [HermesRealtimeRelayFrame] {
        recordedDeniedFrames
    }
}

private final class PhoneControlRecordingIrohStream: IrohRelayStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inboundFrames: [HermesRealtimeRelayFrame]
    private var outboundFrames: [HermesRealtimeRelayFrame] = []
    private var isClosed = false

    init(inbound: [HermesRealtimeRelayFrame]) {
        self.inboundFrames = inbound
    }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        lock.withLock {
            outboundFrames.append(frame)
        }
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        lock.withLock {
            guard !isClosed, !inboundFrames.isEmpty else { return nil }
            return inboundFrames.removeFirst()
        }
    }

    func close() async {
        lock.withLock {
            isClosed = true
        }
    }

    func sentFrames() async -> [HermesRealtimeRelayFrame] {
        lock.withLock { outboundFrames }
    }
}

private actor StaticPhoneControlAuthorityProvider: PhoneControlAuthorityPublicKeyProviding {
    private let expectedUID: String
    private let expectedConnectionID: String
    private let expectedPeerNodeID: String
    private let publicKey: Curve25519.Signing.PublicKey
    private(set) var fetchCount = 0

    init(
        expectedUID: String,
        expectedConnectionID: String,
        expectedPeerNodeID: String,
        publicKey: Curve25519.Signing.PublicKey
    ) {
        self.expectedUID = expectedUID
        self.expectedConnectionID = expectedConnectionID
        self.expectedPeerNodeID = expectedPeerNodeID
        self.publicKey = publicKey
    }

    func fetchPublicKey(
        uid: String,
        connectionId: String,
        peerNodeId: String
    ) async throws -> Curve25519.Signing.PublicKey {
        fetchCount += 1
        XCTAssertEqual(uid, expectedUID)
        XCTAssertEqual(connectionId, expectedConnectionID)
        XCTAssertEqual(peerNodeId, expectedPeerNodeID)
        return publicKey
    }
}
#endif

import XCTest
import OpenBurnBarCore
import OpenBurnBarMedia
@testable import OpenBurnBar

/// Mercury Phase 8 — locks in the user-facing arbiter that turns
/// inbound `media.mirror.request` frames into ringing UI, cooldowns,
/// auto-accepts (consent fast-path), and acks on the control stream.
@MainActor
final class MercuryRouterTests: XCTestCase {

    // MARK: - Test scaffolding

    private func makeRouter(
        consent: Bool = false,
        cooldownSeconds: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = Date.init
    ) -> (router: MercuryRouter, sink: AckSink) {
        let registry = MediaControlStreamRegistry()
        let peerSource = MercuryPeerSource(
            registry: registry,
            uidProvider: { "u" },
            pollInterval: 999
        )
        let sessionCoordinator = MediaSessionCoordinator(
            capabilityGate: AlwaysAllowGate()
        )
        let consentStore = MercuryConsentStore(defaults: makeIsolatedDefaults())
        consentStore.alwaysAllow = consent

        let router = MercuryRouter(
            sessionCoordinator: sessionCoordinator,
            peerSource: peerSource,
            consentStore: consentStore,
            cooldownSeconds: cooldownSeconds,
            clock: clock
        )
        // Inject a sink factory that succeeds — exercises the
        // accept→starting→streaming transitions when relevant.
        router.setMirrorSinkFactory { _, _ in
            RecordingMediaStreamSink()
        }
        return (router, AckSink())
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "mercury.test.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first ?? "")
        return suite
    }

    private func mirrorRequestFrame(
        requestID: String = "req_test",
        requesterName: String = "Alberto's iPhone"
    ) -> HermesRealtimeRelayFrame {
        let req = HermesRealtimeRelayMirrorRequest(
            requestId: requestID,
            requestedAt: Date(),
            requesterDisplayName: requesterName,
            streamClass: MediaStreamClass.screenVideo.rawValue
        )
        return HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: "u",
            connectionId: "c",
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorRequest: req)
        )
    }

    // MARK: - Behavioral tests

    func testIncomingRequestEntersRingingPhase() async {
        let (router, sink) = makeRouter()
        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        if case let .ringing(_, name, _) = router.phase {
            XCTAssertEqual(name, "Alberto's iPhone")
        } else {
            XCTFail("expected .ringing, got \(router.phase)")
        }
        XCTAssertNotNil(router.pendingRequest)
        XCTAssertEqual(await sink.count, 0, "ringing must not auto-ack")
    }

    func testConsentToggleSkipsRingingAndAutoAccepts() async {
        let (router, sink) = makeRouter(consent: true)
        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        // With consent on, no ringing phase — router goes straight to
        // starting (and either lands in `.streaming` if the test host
        // can capture the screen, or `.idle` with an `unsupported` ack
        // otherwise). Either way: pending request is cleared, an ack
        // was emitted, and the phase is no longer `.ringing`.
        XCTAssertNil(router.pendingRequest)
        if case .ringing = router.phase {
            XCTFail("consent toggle must skip ringing, got \(router.phase)")
        }
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        let decision = frames[0].media?.mirrorAck?.decision
        XCTAssertTrue(
            decision == .accepted || decision == .unsupported,
            "consent fast-path must emit an ack; got \(String(describing: decision))"
        )
    }

    func testDeclineEmitsDeniedAckAndEntersCooldown() async {
        let (router, sink) = makeRouter(cooldownSeconds: 5)
        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        guard let pending = router.pendingRequest else {
            XCTFail("expected pending request")
            return
        }
        await router.declineMirror(pending)
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .denied)
        if case let .cooldown(remaining) = router.phase {
            XCTAssertEqual(remaining, 5)
        } else {
            XCTFail("expected .cooldown after decline, got \(router.phase)")
        }
    }

    func testCooldownAutoDeniesNewRequests() async {
        let (router, sink) = makeRouter(cooldownSeconds: 60)
        // Drive to cooldown.
        await router.handleFrame(mirrorRequestFrame(requestID: "req_a"), replySender: sink.sender)
        if let pending = router.pendingRequest {
            await router.declineMirror(pending)
        }
        await sink.reset()

        // Second request during cooldown — should ack `coolingDown`
        // without prompting the user.
        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_b"),
            replySender: sink.sender
        )
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .coolingDown)
        XCTAssertEqual(frames[0].media?.mirrorAck?.requestId, "req_b")
        XCTAssertNotNil(frames[0].media?.mirrorAck?.cooldownSecondsRemaining)
    }

    func testPresenceHeartbeatRoutesToPeerSourceWithoutAck() async {
        let (router, sink) = makeRouter()
        let beat = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(),
            deviceDisplayName: "iPad",
            capabilities: [MercuryPeer.Feature.mirrorViewer.rawValue]
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaPresenceHeartbeat,
            uid: "u",
            connectionId: "c",
            media: HermesRealtimeRelayMediaPayload(presence: beat)
        )
        await router.handleFrame(frame, replySender: sink.sender)
        XCTAssertEqual(await sink.count, 0, "heartbeat must not produce an ack")
        XCTAssertEqual(router.phase, .idle)
    }

    func testStopMirrorEntersCooldownEvenWhenNotStreaming() async {
        // We don't drive into actual streaming (host may lack screen
        // recording permission). Calling stopMirror from idle should
        // still settle into cooldown — defensive contract for the
        // CallHUD end-call tap.
        let (router, sink) = makeRouter(cooldownSeconds: 4)
        await router.stopMirror()
        if case let .cooldown(remaining) = router.phase {
            XCTAssertEqual(remaining, 4)
        } else {
            XCTFail("expected .cooldown after stop, got \(router.phase)")
        }
        XCTAssertEqual(await sink.count, 0,
                       "stop from idle has no active request to ack")
    }

    private func extractStreaming(from phase: MercuryRouter.Phase) throws -> String {
        if case let .streaming(id, _) = phase { return id }
        if case let .starting(id) = phase { return id }
        throw XCTSkip("phase not streaming/starting")
    }
}

// MARK: - Test doubles

private final class AlwaysAllowGate: MediaCapabilityGate {
    func check(
        feature: MediaStreamClass.Feature,
        sessionDurationLimitSeconds: Int?,
        sessionByteBudget: Int64?
    ) async -> MediaCapabilityCheck {
        .allowed(envelope: MediaCapabilityEnvelope(
            feature: feature,
            concurrentSessionsRemaining: 1
        ))
    }
}

private actor AckSink {
    private var stored: [HermesRealtimeRelayFrame] = []

    var frames: [HermesRealtimeRelayFrame] { stored }
    var count: Int { stored.count }

    func append(_ frame: HermesRealtimeRelayFrame) {
        stored.append(frame)
    }

    func reset() {
        stored.removeAll()
    }

    nonisolated var sender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void {
        { [self] frame in await self.append(frame) }
    }
}

private final class RecordingMediaStreamSink: MediaStreamSink, @unchecked Sendable {
    func write(frame: MediaFrame) async {}
    func close() async {}
}

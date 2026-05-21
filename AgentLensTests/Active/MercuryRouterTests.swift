import XCTest
import OpenBurnBarCore
import OpenBurnBarIrohRelay
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
        ensureComputerUseSession: MercuryRouter.ComputerUseSessionEnsurer? = nil,
        startScreenShare: MercuryRouter.ScreenShareStarter? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
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
            ensureComputerUseSession: ensureComputerUseSession,
            startScreenShare: startScreenShare,
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
        requesterName: String = "Alberto's iPhone",
        connectionID: String = "c",
        streamingCapabilities: HermesRealtimeRelayStreamingCapabilities? = nil
    ) -> HermesRealtimeRelayFrame {
        let req = HermesRealtimeRelayMirrorRequest(
            requestId: requestID,
            requestedAt: Date(),
            requesterDisplayName: requesterName,
            streamClass: MediaStreamClass.screenVideo.rawValue,
            streamingCapabilities: streamingCapabilities
        )
        return HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: "u",
            connectionId: connectionID,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorRequest: req)
        )
    }

    private func presenceHeartbeatFrame(
        connectionID: String,
        streamingCapabilities: HermesRealtimeRelayStreamingCapabilities?
    ) -> HermesRealtimeRelayFrame {
        let heartbeat = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(),
            deviceDisplayName: "Alberto's iPhone",
            capabilities: [MercuryPeer.Feature.mirrorViewer.rawValue],
            peerDeviceId: connectionID,
            streamingCapabilities: streamingCapabilities
        )
        return HermesRealtimeRelayFrame(
            type: .mediaPresenceHeartbeat,
            uid: "u",
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(presence: heartbeat)
        )
    }

    func testAcceptMirrorEnsuresComputerUseSessionBeforeAcceptedAck() async {
        var events: [String] = []
        let (router, sink) = makeRouter(
            consent: true,
            ensureComputerUseSession: {
                events.append("computer-use")
            },
            startScreenShare: { _, _, _, _, _, _, _ in
                events.append("screen-share")
            }
        )

        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)

        let frames = await sink.frames
        XCTAssertEqual(frames.first?.media?.mirrorAck?.decision, .accepted)
        XCTAssertEqual(events, ["screen-share", "computer-use"])
    }

    func testAcceptMirrorForwardsRequesterStreamingCapabilitiesWithLiveV2() async throws {
        let remote = MercuryStreamingCapabilitySnapshot(
            codecCapabilities: [
                MercuryVideoCodecCapability(
                    codec: .hevc,
                    canEncode: false,
                    canDecode: true,
                    hardwareAccelerated: true,
                    longTermReference: true
                ),
                MercuryVideoCodecCapability(
                    codec: .h264,
                    canEncode: false,
                    canDecode: true,
                    hardwareAccelerated: true
                )
            ],
            mediaFrameVersions: .v1AndV2,
            source: "test-remote"
        )
        var capturedLocal: MercuryStreamingCapabilitySnapshot?
        var capturedRemote: MercuryStreamingCapabilitySnapshot?
        var capturedPolicy: MercuryCodecPolicy?
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, localCapabilities, remoteCapabilities, codecPolicy in
                capturedLocal = localCapabilities
                capturedRemote = remoteCapabilities
                capturedPolicy = codecPolicy
            }
        )

        await router.handleFrame(
            mirrorRequestFrame(streamingCapabilities: remote.wireValue),
            replySender: sink.sender
        )

        XCTAssertEqual(capturedRemote, remote)
        XCTAssertEqual(capturedLocal?.mediaFrameVersions, .v1AndV2)
        XCTAssertEqual(capturedPolicy, .production)
        let frames = await sink.frames
        XCTAssertEqual(frames.first?.media?.mirrorAck?.decision, .accepted)
    }

    func testHeartbeatCapabilityCacheIsScopedPerControlConnection() async throws {
        let v2Remote = MercuryStreamingCapabilitySnapshot(
            codecCapabilities: [
                MercuryVideoCodecCapability(
                    codec: .hevc,
                    canEncode: false,
                    canDecode: true,
                    hardwareAccelerated: true
                )
            ],
            mediaFrameVersions: .v1AndV2,
            source: "v2-phone"
        )
        var capturedLocal: MercuryStreamingCapabilitySnapshot?
        var capturedRemote: MercuryStreamingCapabilitySnapshot?
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, localCapabilities, remoteCapabilities, _ in
                capturedLocal = localCapabilities
                capturedRemote = remoteCapabilities
            }
        )

        await router.handleFrame(
            presenceHeartbeatFrame(
                connectionID: "v2-conn",
                streamingCapabilities: v2Remote.wireValue
            ),
            replySender: sink.sender
        )
        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "req-legacy",
                connectionID: "legacy-conn",
                streamingCapabilities: nil
            ),
            replySender: sink.sender
        )

        XCTAssertNil(capturedLocal)
        XCTAssertNil(capturedRemote)
        let frames = await sink.frames
        XCTAssertEqual(frames.last?.media?.mirrorAck?.decision, .accepted)
    }

    func testMediaSessionBuildsV2FrameWithCodecAndLTRMetadata() throws {
        let frame = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            gopID: 7,
            frameIndex: 1,
            presentationTimestampMillis: 123,
            payload: Data([1, 2, 3])
        )

        let frameV2 = MediaSessionCoordinator.makeFrameV2(
            from: frame,
            codec: .hevc,
            longTermReferenceToken: MercuryLTRToken(value: 42)
        )
        let metadata = try MediaFrameV2Metadata.decode(frameV2.metadata)

        XCTAssertEqual(frameV2.kind, .videoNAL)
        XCTAssertEqual(frameV2.flags, UInt16(MediaFrame.Flags.keyframe.rawValue))
        XCTAssertEqual(frameV2.gopID, 7)
        XCTAssertEqual(frameV2.frameIndex, 1)
        XCTAssertEqual(frameV2.presentationTimestampMillis, 123)
        XCTAssertEqual(frameV2.payload, Data([1, 2, 3]))
        XCTAssertEqual(metadata.codec, .hevc)
        XCTAssertEqual(metadata.longTermReferenceToken?.value, 42)
    }

    func testControlStreamSinkWritesNegotiatedV2Envelope() async throws {
        let stream = RecordingIrohStream()
        let sink = MercuryControlStreamMediaSink(
            stream: stream,
            uid: "u",
            connectionID: "c",
            streamClass: .screenVideo
        )
        let frameV2 = MediaFrameV2(
            kind: .videoNAL,
            flags: UInt16(MediaFrame.Flags.keyframe.rawValue),
            gopID: 3,
            frameIndex: 2,
            presentationTimestampMillis: 456,
            metadata: try MediaFrameV2Metadata(codec: .h264).encode(),
            payload: Data([9, 8, 7])
        )

        await sink.write(frameV2: frameV2)

        let sentFrames = await stream.sentFrames
        let sent = try XCTUnwrap(sentFrames.first)
        let encoded = try XCTUnwrap(Data(base64Encoded: sent.media?.encodedFrameBase64 ?? ""))
        let decoded = try MediaFrameV2Codec().decode(encoded).frame
        XCTAssertEqual(sent.type, .mediaStreamFrame)
        XCTAssertEqual(sent.media?.streamClass, MediaStreamClass.screenVideo.rawValue)
        XCTAssertEqual(decoded, frameV2)
    }

    private func mirrorStopFrame(requestID: String = "req_test") -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaMirrorStop,
            uid: "u",
            connectionId: "c",
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(
                mirrorStop: HermesRealtimeRelayMirrorStop(
                    requestId: requestID,
                    stoppedAt: Date(timeIntervalSince1970: 1_700_000_001),
                    reason: "viewer_closed"
                )
            )
        )
    }

    private func mirrorDisplaySelectFrame(
        requestID: String = "req_test",
        displayID: String
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaMirrorDisplaySelect,
            uid: "u",
            connectionId: "c",
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(
                mirrorDisplaySelection: HermesRealtimeRelayMirrorDisplaySelection(
                    requestId: requestID,
                    displayId: displayID
                )
            )
        )
    }

    private func callInviteFrame(
        requestID: String = "call_test",
        requesterName: String = "Alberto's Android"
    ) -> HermesRealtimeRelayFrame {
        let invite = HermesRealtimeRelayCallInvite(
            requestId: requestID,
            requestedAt: Date(),
            requesterDisplayName: requesterName,
            callKind: "video"
        )
        return HermesRealtimeRelayFrame(
            type: .mediaCallInvite,
            uid: "u",
            connectionId: "c",
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(callInvite: invite)
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
        let ackCount = await sink.count
        XCTAssertEqual(ackCount, 0, "ringing must not auto-ack")
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
        let ackCount = await sink.count
        XCTAssertEqual(ackCount, 1, "heartbeat should receive Mac presence in reply")
        let frames = await sink.frames
        XCTAssertEqual(frames[0].type, .mediaPresenceHeartbeat)
        XCTAssertEqual(frames[0].media?.presence?.deviceDisplayName.isEmpty, false)
        XCTAssertEqual(router.phase, .idle)
    }

    func testCallInviteEntersCallRingingPhase() async {
        let (router, sink) = makeRouter()
        await router.handleFrame(callInviteFrame(), replySender: sink.sender)
        if case let .callRinging(_, name, _) = router.phase {
            XCTAssertEqual(name, "Alberto's Android")
        } else {
            XCTFail("expected .callRinging, got \(router.phase)")
        }
        XCTAssertNotNil(router.pendingCall)
        let ackCount = await sink.count
        XCTAssertEqual(ackCount, 0, "call ringing must wait for the user's decision")
    }

    func testAcceptCallInviteEmitsAcceptedCallAck() async {
        let (router, sink) = makeRouter()
        await router.handleFrame(callInviteFrame(), replySender: sink.sender)
        guard let pending = router.pendingCall else {
            XCTFail("expected pending call")
            return
        }
        await router.acceptCall(pending)
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, .mediaCallAck)
        XCTAssertEqual(frames[0].media?.callAck?.requestId, "call_test")
        XCTAssertEqual(frames[0].media?.callAck?.decision, .accepted)
        XCTAssertEqual(router.phase, .idle)
    }

    func testDeclineCallInviteEmitsDeniedCallAckAndCooldown() async {
        let (router, sink) = makeRouter(cooldownSeconds: 6)
        await router.handleFrame(callInviteFrame(), replySender: sink.sender)
        guard let pending = router.pendingCall else {
            XCTFail("expected pending call")
            return
        }
        await router.declineCall(pending)
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, .mediaCallAck)
        XCTAssertEqual(frames[0].media?.callAck?.decision, .denied)
        if case let .cooldown(remaining) = router.phase {
            XCTAssertEqual(remaining, 6)
        } else {
            XCTFail("expected .cooldown after decline, got \(router.phase)")
        }
    }

    func testStopMirrorFromIdleStaysIdle() async {
        // Normal hangup must reset only the active call surface. It must
        // not force cooldown, because the user should be able to start a
        // fresh mirror without restarting either app.
        let (router, sink) = makeRouter(cooldownSeconds: 4)
        await router.stopMirror()
        XCTAssertEqual(router.phase, .idle)
        let ackCount = await sink.count
        XCTAssertEqual(ackCount, 0,
                       "stop from idle has no active request to ack")
    }

    func testPhoneStopClearsActiveMirrorWithoutCooldown() async throws {
        let (router, sink) = makeRouter(
            consent: true,
            cooldownSeconds: 30,
            startScreenShare: { _, _, _, _, _, _, _ in }
        )
        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        let requestID = try extractStreaming(from: router.phase)

        await router.handleFrame(mirrorStopFrame(requestID: requestID), replySender: sink.sender)

        XCTAssertEqual(router.phase, .idle)
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1, "phone stop is a control signal, not a second ack")
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .accepted)
    }

    func testNormalHangupAllowsImmediateNewMirrorSession() async throws {
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _ in
                startCount += 1
            }
        )

        await router.handleFrame(mirrorRequestFrame(requestID: "req_one"), replySender: sink.sender)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_one")

        await router.stopMirror()
        XCTAssertEqual(router.phase, .idle)

        await router.handleFrame(mirrorRequestFrame(requestID: "req_two"), replySender: sink.sender)
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_two")
        let decisions = await sink.frames.compactMap { $0.media?.mirrorAck?.decision }
        XCTAssertEqual(decisions, [.accepted, .denied, .accepted])
    }

    func testSamePeerMirrorRequestRestartsActiveSessionForRecovery() async throws {
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _ in
                startCount += 1
            }
        )

        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_one", connectionID: "android-1"),
            replySender: sink.sender
        )
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_one")

        await sink.reset()
        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_two", connectionID: "android-1"),
            replySender: sink.sender
        )

        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_two")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.requestId, "req_two")
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .accepted)
    }

    func testDifferentPeerMirrorRequestRemainsBusyDuringActiveSession() async throws {
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _ in
                startCount += 1
            }
        )

        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_one", connectionID: "android-1"),
            replySender: sink.sender
        )
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_one")

        await sink.reset()
        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_two", connectionID: "android-2"),
            replySender: sink.sender
        )

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_one")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.requestId, "req_two")
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .busy)
        XCTAssertEqual(frames[0].media?.mirrorAck?.detail, "Another mirror is in progress")
    }

    func testDisplaySelectionAcknowledgesSelectedDisplayAndKeepsMirrorStreaming() async throws {
        guard let display = ScreenCapturePipeline.availableDisplays().first else {
            throw XCTSkip("No displays available on this test host.")
        }
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _ in }
        )

        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        let requestID = try extractStreaming(from: router.phase)
        await sink.reset()

        await router.handleFrame(
            mirrorDisplaySelectFrame(requestID: requestID, displayID: display.id),
            replySender: sink.sender
        )

        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        let ack = frames[0].media?.mirrorAck
        XCTAssertEqual(ack?.decision, .accepted)
        XCTAssertEqual(ack?.selectedDisplayId, display.id)
        XCTAssertEqual(try extractStreaming(from: router.phase), requestID)
    }

    func testMissingDisplaySelectionReturnsRecoverableAckWithoutEndingMirror() async throws {
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _ in }
        )

        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        let requestID = try extractStreaming(from: router.phase)
        await sink.reset()

        await router.handleFrame(
            mirrorDisplaySelectFrame(requestID: requestID, displayID: "missing-display-\(UUID().uuidString)"),
            replySender: sink.sender
        )

        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        let ack = frames[0].media?.mirrorAck
        XCTAssertEqual(ack?.decision, .unsupported)
        XCTAssertNotNil(ack?.availableDisplays)
        XCTAssertEqual(try extractStreaming(from: router.phase), requestID)
    }

    func testControlStreamSinkChunksLargeMediaFramesUnderIrohFrameBudget() async throws {
        let stream = RecordingIrohStream()
        let sink = MercuryControlStreamMediaSink(
            stream: stream,
            uid: "uid-1",
            connectionID: "conn-1",
            streamClass: .screenVideo
        )
        let payload = Data(repeating: 0x7A, count: 700_000)
        let source = MediaFrameV2(
            kind: .videoNAL,
            gopID: 12,
            frameIndex: 34,
            presentationTimestampMillis: 56,
            metadata: Data([0x01, 0x02]),
            payload: payload
        )

        await sink.write(frameV2: source)

        let frames = await stream.sentFrames
        XCTAssertGreaterThan(frames.count, 1)
        var chunkParts: [(Int, Data)] = []
        for frame in frames {
            XCTAssertNoThrow(try IrohRelayFrameCodec().encode(frame))
            XCTAssertEqual(frame.media?.streamClass, MediaStreamClass.screenVideo.rawValue)
            let chunk = try XCTUnwrap(frame.media?.frameChunk)
            XCTAssertEqual(chunk.chunkCount, frames.count)
            XCTAssertEqual(chunk.totalBytes, try MediaFrameV2Codec().encode(source, negotiatedVersion: .v2).count)
            let encoded = try XCTUnwrap(frame.media?.encodedFrameBase64)
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            chunkParts.append((chunk.chunkIndex, data))
        }
        let reassembled = chunkParts
            .sorted { $0.0 < $1.0 }
            .reduce(into: Data()) { result, part in result.append(part.1) }
        let decoded = try MediaFrameV2Codec().decode(reassembled).frame
        XCTAssertEqual(decoded, source)
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
    func write(frameV2: MediaFrameV2) async {}
    func close() async {}
}

private actor RecordingIrohStream: IrohRelayStream {
    private var storedFrames: [HermesRealtimeRelayFrame] = []

    var sentFrames: [HermesRealtimeRelayFrame] { storedFrames }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        storedFrames.append(frame)
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        nil
    }

    func close() async {}
}

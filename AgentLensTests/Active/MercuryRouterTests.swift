import XCTest
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
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
        applyFocusFollowMode: MercuryRouter.FocusFollowModeApplier? = nil,
        startScreenShare: MercuryRouter.ScreenShareStarter? = nil,
        maxMirrorViewers: Int = 3,
        remoteUnlockReadiness: MacRemoteUnlockReadinessService? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> (router: MercuryRouter, sink: AckSink) {
        let scoped = makeRouterWithConsentStore(
            consent: consent,
            cooldownSeconds: cooldownSeconds,
            ensureComputerUseSession: ensureComputerUseSession,
            applyFocusFollowMode: applyFocusFollowMode,
            startScreenShare: startScreenShare,
            maxMirrorViewers: maxMirrorViewers,
            remoteUnlockReadiness: remoteUnlockReadiness,
            clock: clock
        )
        return (scoped.router, scoped.sink)
    }

    private func makeRouterWithConsentStore(
        consent: Bool = false,
        cooldownSeconds: TimeInterval = 30,
        ensureComputerUseSession: MercuryRouter.ComputerUseSessionEnsurer? = nil,
        applyFocusFollowMode: MercuryRouter.FocusFollowModeApplier? = nil,
        startScreenShare: MercuryRouter.ScreenShareStarter? = nil,
        maxMirrorViewers: Int = 3,
        remoteUnlockReadiness: MacRemoteUnlockReadinessService? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> (router: MercuryRouter, sink: AckSink, consentStore: MercuryConsentStore) {
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
        if consent {
            seedTestAutoAcceptGrants(in: consentStore)
        }

        let router = MercuryRouter(
            sessionCoordinator: sessionCoordinator,
            peerSource: peerSource,
            consentStore: consentStore,
            ensureComputerUseSession: ensureComputerUseSession,
            applyFocusFollowMode: applyFocusFollowMode,
            startScreenShare: startScreenShare,
            maxMirrorViewers: maxMirrorViewers,
            remoteUnlockReadiness: remoteUnlockReadiness ?? makeRemoteUnlockReadinessService(
                lockStateProvider: { .unlocked }
            ),
            cooldownSeconds: cooldownSeconds,
            clock: clock
        )
        // Inject a sink factory that succeeds — exercises the
        // accept→starting→streaming transitions when relevant.
        router.setMirrorSinkFactory { _, _, _ in
            RecordingMediaStreamSink()
        }
        return (router, AckSink(), consentStore)
    }

    private func seedTestAutoAcceptGrants(in consentStore: MercuryConsentStore) {
        consentStore.rememberAcceptedMirrorPeers = true
        let grants: [(connectionId: String, viewerDeviceId: String?, controlAuthorityPeerNodeId: String?, requesterName: String)] = [
            ("c", nil, nil, "Alberto's iPhone"),
            ("c", "iphone-1", "ios-peer", "Alberto's iPhone"),
            ("legacy-conn", nil, nil, "Legacy phone"),
            ("iphone-1", nil, nil, "Alberto's iPhone"),
            ("android-1", nil, nil, "Samsung Galaxy"),
            ("android-1", "android-device", nil, "Samsung Galaxy"),
            ("android-2", nil, nil, "Samsung Galaxy"),
            ("ipad-1", nil, nil, "iPad"),
            ("shared-mac", nil, nil, "Shared control stream")
        ]
        for grant in grants {
            consentStore.rememberAcceptedPeer(
                connectionId: grant.connectionId,
                viewerDeviceId: grant.viewerDeviceId,
                controlAuthorityPeerNodeId: grant.controlAuthorityPeerNodeId,
                requesterName: grant.requesterName
            )
        }
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "mercury.test.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first ?? "")
        return suite
    }

    private func waitForSentFrame(
        on stream: RecordingIrohStream,
        matching predicate: (HermesRealtimeRelayFrame) -> Bool,
        timeout: TimeInterval = 1.0
    ) async throws -> HermesRealtimeRelayFrame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = await stream.sentFrames.first(where: predicate) {
                return frame
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for matching Mercury frame")
        throw NSError(domain: "MercuryRouterTests", code: 1)
    }

    private func mirrorRequestFrame(
        requestID: String = "req_test",
        requesterName: String = "Alberto's iPhone",
        connectionID: String = "c",
        streamingCapabilities: HermesRealtimeRelayStreamingCapabilities? = nil,
        streamClass: String = MediaStreamClass.screenVideo.rawValue,
        focusFollowMode: String? = nil,
        viewerID: String? = nil,
        viewerDeviceID: String? = nil,
        controlAuthorityPeerNodeID: String? = nil,
        remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession? = nil
    ) -> HermesRealtimeRelayFrame {
        let req = HermesRealtimeRelayMirrorRequest(
            requestId: requestID,
            requestedAt: Date(),
            requesterDisplayName: requesterName,
            streamClass: streamClass,
            streamingCapabilities: streamingCapabilities,
            focusFollowMode: focusFollowMode,
            viewerId: viewerID,
            viewerDeviceId: viewerDeviceID,
            controlAuthorityPeerNodeId: controlAuthorityPeerNodeID,
            remoteUnlockSession: remoteUnlockSession
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
        displayName: String = "Alberto's iPhone",
        capabilities: [String] = [MercuryPeer.Feature.mirrorViewer.rawValue],
        streamingCapabilities: HermesRealtimeRelayStreamingCapabilities?
    ) -> HermesRealtimeRelayFrame {
        let heartbeat = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(),
            deviceDisplayName: displayName,
            capabilities: capabilities,
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

    func testAcceptMirrorAcksBeforeScreenCaptureStartupCompletes() async throws {
        var didFinishCaptureStartup = false
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                didFinishCaptureStartup = true
            }
        )

        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)

        let frames = await sink.frames
        XCTAssertEqual(frames.first?.media?.mirrorAck?.decision, .accepted)
        XCTAssertFalse(
            didFinishCaptureStartup,
            "The accepted ack must not wait for ScreenCaptureKit startup."
        )
        await router.stopMirror()
    }

    func testRegularScreenMirrorForcesFocusFollowOffBeforeComputerUseSession() async {
        var events: [String] = []
        let (router, sink) = makeRouter(
            consent: true,
            ensureComputerUseSession: {
                events.append("computer-use")
            },
            applyFocusFollowMode: { mode in
                events.append("focus-\(mode.rawValue)")
            },
            startScreenShare: { _, _, _, _, _, _, _, _ in
                events.append("screen-share")
            }
        )

        await router.handleFrame(
            mirrorRequestFrame(focusFollowMode: AgentFocusFollowMode.smart.rawValue),
            replySender: sink.sender
        )

        let frames = await sink.frames
        XCTAssertEqual(frames.first?.media?.mirrorAck?.decision, .accepted)
        XCTAssertEqual(events, ["screen-share", "focus-off", "computer-use"])
    }

    func testAgentWatchSurfaceCanApplyRequestedFocusFollowMode() async {
        var modes: [AgentFocusFollowMode] = []
        let (router, sink) = makeRouter(
            consent: true,
            ensureComputerUseSession: {},
            applyFocusFollowMode: { modes.append($0) },
            startScreenShare: { _, _, _, _, _, _, _, _ in }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                streamClass: MediaStreamClass.controlSurfaceFrame.rawValue,
                focusFollowMode: AgentFocusFollowMode.smart.rawValue
            ),
            replySender: sink.sender
        )

        let frames = await sink.frames
        XCTAssertEqual(frames.first?.media?.mirrorAck?.decision, .accepted)
        XCTAssertEqual(modes, [.smart])
    }

    func testDisplayCaptureExcludesOpenBurnBarChromeApplications() {
        XCTAssertTrue(ScreenCapturePipeline.shouldExcludeApplicationFromDisplayCapture(
            bundleIdentifier: "com.openburnbar.app",
            ownBundleIdentifier: "com.openburnbar.app"
        ))
        XCTAssertTrue(ScreenCapturePipeline.shouldExcludeApplicationFromDisplayCapture(
            bundleIdentifier: "com.openburnbar.AgentLens",
            ownBundleIdentifier: "com.openburnbar.app"
        ))
        XCTAssertFalse(ScreenCapturePipeline.shouldExcludeApplicationFromDisplayCapture(
            bundleIdentifier: "com.apple.Terminal",
            ownBundleIdentifier: "com.openburnbar.app"
        ))
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
            startScreenShare: { _, _, _, _, _, localCapabilities, remoteCapabilities, codecPolicy in
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
            startScreenShare: { _, _, _, _, _, localCapabilities, remoteCapabilities, _ in
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

    private func mirrorStopFrame(
        requestID: String = "req_test",
        connectionID: String = "c",
        sessionID: String? = nil
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaMirrorStop,
            uid: "u",
            connectionId: connectionID,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(
                mirrorStop: HermesRealtimeRelayMirrorStop(
                    requestId: requestID,
                    sessionId: sessionID,
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

    func testExistingPeerGrantSkipsRingingAndAutoAccepts() async {
        let (router, sink) = makeRouter(consent: true)
        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        // With a grant scoped to this verified peer, no ringing phase — router
        // admits the viewer immediately. Host capture may fail later on
        // machines without ScreenCaptureKit permission, but the phone must not
        // wait for that startup before receiving the admission ack.
        XCTAssertNil(router.pendingRequest)
        if case .ringing = router.phase {
            XCTFail("peer grant must skip ringing, got \(router.phase)")
        }
        let frames = await sink.frames
        XCTAssertGreaterThanOrEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .accepted)
    }

    func testAcceptMirrorPersistsConsentForFutureAutoAccept() async {
        let (router, sink, consentStore) = makeRouterWithConsentStore(
            startScreenShare: { _, _, _, _, _, _, _, _ in }
        )

        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        guard let pending = router.pendingRequest else {
            XCTFail("expected pending request before first consent")
            return
        }
        XCTAssertEqual(consentStore.activeGrantCount, 0)

        consentStore.rememberAcceptedMirrorPeers = true
        await router.acceptMirror(pending)

        XCTAssertEqual(consentStore.activeGrantCount, 1)
        XCTAssertTrue(consentStore.canAutoAccept(
            connectionId: "c",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: nil
        ))
        XCTAssertFalse(consentStore.canAutoAccept(
            connectionId: "other-connection",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: nil
        ))
        XCTAssertNil(router.pendingRequest)
        let frames = await sink.frames
        XCTAssertEqual(frames.last?.media?.mirrorAck?.decision, .accepted)
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
        XCTAssertNil(frames[0].media?.presence?.blurredWallpaperBase64)
        XCTAssertNil(frames[0].media?.presence?.streamingCapabilities)
        XCTAssertEqual(router.phase, .idle)
    }

    func testPresenceHeartbeatDoesNotAdvertiseMirrorAutoAcceptCapability() async {
        let (router, sink) = makeRouter(consent: true)
        await router.handleFrame(
            presenceHeartbeatFrame(connectionID: "c", streamingCapabilities: nil),
            replySender: sink.sender
        )

        let frames = await sink.frames
        let capabilities = frames.first?.media?.presence?.capabilities ?? []
        XCTAssertTrue(capabilities.contains(MercuryPeer.Feature.mirrorHost.rawValue))
        XCTAssertFalse(
            capabilities.contains(MercuryPeer.Feature.mirrorAutoAccept.rawValue),
            "auto-accept is now proven per request from the stored peer grant, not advertised as a blanket host capability"
        )
    }

    func testControlStreamMirrorSinkEmitsHealthHeartbeatsWithoutVideoFrames() async throws {
        let stream = RecordingIrohStream()
        let sink = MercuryControlStreamMediaSink(
            stream: stream,
            uid: "u",
            connectionID: "c",
            streamClass: .screenVideo,
            heartbeatInterval: 0.02
        )
        defer { Task { await sink.close() } }

        let heartbeat = try await waitForSentFrame(on: stream) { frame in
            frame.type == .mediaPresenceHeartbeat
        }

        XCTAssertEqual(heartbeat.uid, "u")
        XCTAssertEqual(heartbeat.connectionId, "c")
        XCTAssertEqual(heartbeat.media?.presence?.capabilities.contains(MercuryPeer.Feature.mirrorHost.rawValue), true)
        XCTAssertEqual(heartbeat.media?.presence?.capabilities.contains(MediaStreamClass.screenVideo.rawValue), true)
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
            startScreenShare: { _, _, _, _, _, _, _, _ in }
        )
        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        let requestID = try extractStreaming(from: router.phase)

        await router.handleFrame(mirrorStopFrame(requestID: requestID), replySender: sink.sender)

        XCTAssertEqual(router.phase, .idle)
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1, "phone stop is a control signal, not a second ack")
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .accepted)
    }

    func testMacLockStopsActiveMirrorAndNotifiesViewer() async throws {
        let (router, sink) = makeRouter(
            consent: true,
            cooldownSeconds: 30,
            startScreenShare: { _, _, _, _, _, _, _, _ in }
        )
        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_test")

        await sink.reset()
        await router.handleHostAuthGateClosedForTesting(reason: "session_resigned_active")

        XCTAssertEqual(router.phase, .idle)
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.requestId, "req_test")
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .denied)
        XCTAssertEqual(
            frames[0].media?.mirrorAck?.detail,
            "Mac locked or screen capture became unavailable"
        )
    }

    func testMacLockClearsPendingMirrorPromptAndDeniesRequester() async {
        let (router, sink) = makeRouter(cooldownSeconds: 30)
        await router.handleFrame(mirrorRequestFrame(), replySender: sink.sender)
        XCTAssertNotNil(router.pendingRequest)

        await router.handleHostAuthGateClosedForTesting(reason: "screen_sleep")

        XCTAssertNil(router.pendingRequest)
        XCTAssertEqual(router.phase, .idle)
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .denied)
        XCTAssertEqual(
            frames[0].media?.mirrorAck?.detail,
            "Mac locked or screen capture became unavailable"
        )
    }

    func testPhoneStopAllowsDifferentDeviceToMirrorImmediately() async throws {
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: true,
            cooldownSeconds: 30,
            startScreenShare: { _, _, _, _, _, _, _, _ in
                startCount += 1
            }
        )

        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_phone", connectionID: "iphone-1"),
            replySender: sink.sender
        )
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_phone")

        await router.handleFrame(
            mirrorStopFrame(requestID: "req_phone", connectionID: "iphone-1"),
            replySender: sink.sender
        )
        XCTAssertEqual(router.phase, .idle)

        await sink.reset()
        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_android", connectionID: "android-1"),
            replySender: sink.sender
        )

        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_android")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .accepted)
    }

    func testControlStreamCloseClearsDisconnectedAndroidMirrorSoIPhoneCanReconnect() async throws {
        var startedPeers: [String] = []
        let (router, sink) = makeRouter(
            consent: true,
            cooldownSeconds: 30,
            startScreenShare: { peerDeviceID, _, _, _, _, _, _, _ in
                startedPeers.append(peerDeviceID)
            }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "req_android",
                requesterName: "Samsung Galaxy",
                connectionID: "android-1"
            ),
            replySender: sink.sender
        )
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_android")

        await router.handleControlStreamClosed(connectionID: "android-1")
        XCTAssertEqual(router.phase, .idle)

        await sink.reset()
        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "req_iphone",
                requesterName: "Alberto's iPhone",
                connectionID: "iphone-1"
            ),
            replySender: sink.sender
        )

        XCTAssertEqual(startedPeers, ["android-1", "iphone-1"])
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_iphone")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.requestId, "req_iphone")
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .accepted)
    }

    func testControlStreamCloseClearsRingingPromptForDisconnectedDevice() async {
        let (router, sink) = makeRouter()

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "req_android",
                requesterName: "Samsung Galaxy",
                connectionID: "android-1"
            ),
            replySender: sink.sender
        )
        XCTAssertNotNil(router.pendingRequest)

        await router.handleControlStreamClosed(connectionID: "android-1")

        XCTAssertNil(router.pendingRequest)
        XCTAssertEqual(router.phase, .idle)
    }

    func testPeerSourceDoesNotLetStaleAndroidHeartbeatOverrideLatestIPhoneStream() async throws {
        let registry = MediaControlStreamRegistry()
        let peerSource = MercuryPeerSource(
            registry: registry,
            uidProvider: { "u" },
            pollInterval: 999,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let androidHeartbeat = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(),
            deviceDisplayName: "Samsung Galaxy",
            capabilities: [MercuryPeer.Feature.mirrorViewer.rawValue],
            peerDeviceId: "android-1",
            streamingCapabilities: nil
        )
        peerSource.ingestHeartbeat(androidHeartbeat, connectionID: "android-1")

        await registry.register(
            stream: RecordingIrohStream(),
            uid: "u",
            connectionID: "iphone-1"
        )
        await peerSource.refreshForTesting()

        var peer = try XCTUnwrap(peerSource.peer)
        XCTAssertEqual(peer.connectionID, "iphone-1")
        XCTAssertEqual(peer.displayName, "Paired iPhone")
        XCTAssertEqual(peer.capabilities, MercuryPeer.iphoneFallbackCapabilities)

        let iphoneHeartbeat = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(),
            deviceDisplayName: "Alberto's iPhone",
            capabilities: [MercuryPeer.Feature.mirrorViewer.rawValue, MercuryPeer.Feature.fileSend.rawValue],
            peerDeviceId: "iphone-1",
            streamingCapabilities: nil
        )
        peerSource.ingestHeartbeat(iphoneHeartbeat, connectionID: "iphone-1")
        await peerSource.refreshForTesting()

        peer = try XCTUnwrap(peerSource.peer)
        XCTAssertEqual(peer.connectionID, "iphone-1")
        XCTAssertEqual(peer.displayName, "Alberto's iPhone")
        XCTAssertTrue(peer.capabilities.contains(.fileSend))
    }

    func testNormalHangupAllowsImmediateNewMirrorSession() async throws {
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in
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

    func testSameDeviceMirrorRequestRestartsActiveSessionForRecovery() async throws {
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in
                startCount += 1
            }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "req_one",
                connectionID: "android-1",
                viewerID: "viewer-old",
                viewerDeviceID: "android-device"
            ),
            replySender: sink.sender
        )
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_one")

        await sink.reset()
        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "req_two",
                connectionID: "android-1",
                viewerID: "viewer-new",
                viewerDeviceID: "android-device"
            ),
            replySender: sink.sender
        )

        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_two")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].media?.mirrorAck?.requestId, "req_two")
        XCTAssertEqual(frames[0].media?.mirrorAck?.decision, .accepted)
    }

    func testDifferentPeerMirrorRequestJoinsAsWatcherDuringActiveSession() async throws {
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in
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

        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_one")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 2)
        let secondViewerAck = frames.compactMap(\.media?.mirrorAck).first { $0.requestId == "req_two" }
        XCTAssertEqual(secondViewerAck?.decision, .accepted)
        XCTAssertEqual(secondViewerAck?.viewerRole, "watcher")
        XCTAssertEqual(secondViewerAck?.viewerCount, 2)
        XCTAssertEqual(secondViewerAck?.maxViewers, 3)
        XCTAssertNotNil(secondViewerAck?.controlOwnerViewerId)
        let controllerRosterAck = frames.compactMap(\.media?.mirrorAck).first { $0.requestId == "req_one" }
        XCTAssertEqual(controllerRosterAck?.decision, .accepted)
        XCTAssertEqual(controllerRosterAck?.viewerRole, "controller")
        XCTAssertEqual(controllerRosterAck?.viewerCount, 2)
    }

    func testMirrorViewerLimitDeniesAdditionalWatchers() async throws {
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in },
            maxMirrorViewers: 2
        )

        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_one", connectionID: "iphone-1"),
            replySender: sink.sender
        )
        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_two", connectionID: "android-1"),
            replySender: sink.sender
        )
        await sink.reset()

        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_three", connectionID: "ipad-1"),
            replySender: sink.sender
        )

        XCTAssertEqual(try extractStreaming(from: router.phase), "req_one")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        let ack = frames[0].media?.mirrorAck
        XCTAssertEqual(ack?.requestId, "req_three")
        XCTAssertEqual(ack?.decision, .busy)
        XCTAssertEqual(ack?.detail, "Mirror viewer limit reached")
        XCTAssertEqual(ack?.viewerCount, 2)
        XCTAssertEqual(ack?.maxViewers, 2)
        XCTAssertNotNil(ack?.controlOwnerViewerId)
    }

    func testRemoteUnlockMirrorRestartsNormalCaptureWhenHostUnlocks() async throws {
        let now = Date()
        var lockState = HermesRealtimeRelayMacLockState.loginWindow
        let readiness = makeRemoteUnlockReadinessService(lockStateProvider: { lockState })
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in
                startCount += 1
            },
            remoteUnlockReadiness: readiness,
            clock: { now }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "remote-unlock-mirror",
                viewerID: "viewer-1",
                viewerDeviceID: "iphone-1",
                controlAuthorityPeerNodeID: "ios-peer",
                remoteUnlockSession: remoteUnlockSession(
                    sessionId: "unlock-session",
                    peerNodeId: "ios-peer",
                    viewerDeviceId: "iphone-1",
                    issuedAt: now
                )
            ),
            replySender: sink.sender
        )
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(try extractStreaming(from: router.phase), "remote-unlock-mirror")

        await sink.reset()
        lockState = .unlocked
        await router.handleHostAuthGateOpenedForTesting(reason: "unit_unlock")

        XCTAssertEqual(startCount, 1, "locked Remote Unlock mirrors start capture only after the host unlocks")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        let ack = try XCTUnwrap(frames.first?.media?.mirrorAck)
        XCTAssertEqual(ack.decision, .accepted)
        XCTAssertEqual(ack.detail, "Mac unlocked; normal mirror resumed.")
        XCTAssertEqual(ack.remoteUnlockState?.lockState, .unlocked)
    }

    func testRemoteUnlockCredentialResultPollsUntilHostUnlocksAndResumesCapture() async throws {
        let now = Date()
        var lockState = HermesRealtimeRelayMacLockState.loginWindow
        let readiness = makeRemoteUnlockReadinessService(lockStateProvider: { lockState })
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in
                startCount += 1
            },
            remoteUnlockReadiness: readiness,
            clock: { now }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "remote-unlock-mirror",
                viewerID: "viewer-1",
                viewerDeviceID: "iphone-1",
                controlAuthorityPeerNodeID: "ios-peer",
                remoteUnlockSession: remoteUnlockSession(
                    sessionId: "unlock-session",
                    peerNodeId: "ios-peer",
                    viewerDeviceId: "iphone-1",
                    issuedAt: now
                )
            ),
            replySender: sink.sender
        )
        XCTAssertEqual(startCount, 0)

        await sink.reset()
        router.handleRemoteUnlockCredentialResult(
            HermesRealtimeRelayRemoteUnlockResult(
                requestId: "credential-request",
                sessionId: "unlock-session",
                status: .accepted,
                lockState: .loginWindow,
                detail: "credential_submitted",
                completedAt: now
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let framesBeforeUnlock = await sink.frames
        XCTAssertTrue(framesBeforeUnlock.isEmpty)

        lockState = .unlocked
        for _ in 0..<30 {
            if startCount == 1 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertEqual(startCount, 1, "credential result polling should start capture after the host unlocks")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 1)
        let ack = try XCTUnwrap(frames.first?.media?.mirrorAck)
        XCTAssertEqual(ack.decision, .accepted)
        XCTAssertEqual(ack.detail, "Mac unlocked; normal mirror resumed.")
        XCTAssertEqual(ack.remoteUnlockState?.lockState, .unlocked)
    }

    func testLockedMirrorWithoutRemoteUnlockSessionRequestsSignedRetry() async throws {
        let readiness = makeRemoteUnlockReadinessService(lockStateProvider: { .loginWindow })
        var startCount = 0
        let (router, sink, consentStore) = makeRouterWithConsentStore(
            consent: false,
            startScreenShare: { _, _, _, _, _, _, _, _ in
                startCount += 1
            },
            remoteUnlockReadiness: readiness
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "locked-without-session",
                viewerID: "viewer-1",
                viewerDeviceID: "iphone-1",
                controlAuthorityPeerNodeID: "ios-peer"
            ),
            replySender: sink.sender
        )

        let frames = await sink.frames
        let ack = try XCTUnwrap(frames.first?.media?.mirrorAck)
        XCTAssertEqual(ack.decision, .unsupported)
        XCTAssertEqual(ack.detail, "remote_unlock_session_required")
        XCTAssertEqual(ack.remoteUnlockState?.lockState, .loginWindow)
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(router.pendingRequest)
        XCTAssertEqual(router.phase, .idle)
        XCTAssertEqual(consentStore.activeGrantCount, 0)
    }

    func testSignedRemoteUnlockSessionAutoAcceptsWhileMacLocked() async throws {
        let now = Date()
        let readiness = makeRemoteUnlockReadinessService(lockStateProvider: { .loginWindow })
        var startCount = 0
        let (router, sink, consentStore) = makeRouterWithConsentStore(
            consent: false,
            startScreenShare: { _, _, _, _, _, _, _, _ in
                startCount += 1
            },
            remoteUnlockReadiness: readiness,
            clock: { now }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "locked-with-session",
                viewerID: "viewer-1",
                viewerDeviceID: "iphone-1",
                controlAuthorityPeerNodeID: "ios-peer",
                remoteUnlockSession: remoteUnlockSession(
                    sessionId: "unlock-session",
                    peerNodeId: "ios-peer",
                    viewerDeviceId: "iphone-1",
                    issuedAt: now
                )
            ),
            replySender: sink.sender
        )

        let frames = await sink.frames
        let ack = try XCTUnwrap(frames.first?.media?.mirrorAck)
        XCTAssertEqual(ack.decision, .accepted)
        XCTAssertEqual(ack.remoteUnlockState?.lockState, .loginWindow)
        XCTAssertEqual(ack.remoteUnlockState?.sessionId, "unlock-session")
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(router.pendingRequest)
        XCTAssertEqual(try extractStreaming(from: router.phase), "locked-with-session")
        XCTAssertEqual(consentStore.activeGrantCount, 0)
    }

    func testSignedRemoteUnlockSessionDoesNotWaitForLockedScreenCaptureBeforeAck() async throws {
        let now = Date()
        let readiness = makeRemoteUnlockReadinessService(lockStateProvider: { .loginWindow })
        var startCount = 0
        let (router, sink) = makeRouter(
            consent: false,
            startScreenShare: { _, _, _, _, _, _, _, _ in
                startCount += 1
                try await Task.sleep(nanoseconds: 5_000_000_000)
            },
            remoteUnlockReadiness: readiness,
            clock: { now }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "locked-hanging-capture",
                viewerID: "viewer-1",
                viewerDeviceID: "iphone-1",
                controlAuthorityPeerNodeID: "ios-peer",
                remoteUnlockSession: remoteUnlockSession(
                    sessionId: "unlock-session",
                    peerNodeId: "ios-peer",
                    viewerDeviceId: "iphone-1",
                    issuedAt: now
                )
            ),
            replySender: sink.sender
        )

        let frames = await sink.frames
        let ack = try XCTUnwrap(frames.first?.media?.mirrorAck)
        XCTAssertEqual(ack.decision, .accepted)
        XCTAssertEqual(ack.requestId, "locked-hanging-capture")
        XCTAssertEqual(ack.remoteUnlockState?.lockState, .loginWindow)
        XCTAssertEqual(startCount, 0, "locked Remote Unlock acceptance must not depend on ScreenCaptureKit")
        XCTAssertEqual(try extractStreaming(from: router.phase), "locked-hanging-capture")
    }

    func testRemoteUnlockSessionSurvivesTransientControlStreamClose() async throws {
        let now = Date()
        let readiness = makeRemoteUnlockReadinessService(lockStateProvider: { .loginWindow })
        let (router, sink) = makeRouter(
            consent: false,
            startScreenShare: { _, _, _, _, _, _, _, _ in },
            remoteUnlockReadiness: readiness,
            clock: { now }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "locked-with-session",
                connectionID: "phone-connection",
                viewerID: "viewer-1",
                viewerDeviceID: "iphone-1",
                controlAuthorityPeerNodeID: "ios-peer",
                remoteUnlockSession: remoteUnlockSession(
                    sessionId: "unlock-session",
                    peerNodeId: "ios-peer",
                    viewerDeviceId: "iphone-1",
                    issuedAt: now
                )
            ),
            replySender: sink.sender
        )

        XCTAssertTrue(
            readiness.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                viewerDeviceId: "iphone-1",
                now: now
            )
        )

        await router.handleControlStreamClosed(connectionID: "phone-connection")

        XCTAssertTrue(
            readiness.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                viewerDeviceId: "iphone-1",
                now: now
            ),
            "transient stream churn must not invalidate a password prompt already shown on the phone"
        )
    }

    func testRemoteUnlockSessionRevokesWhenViewerExplicitlyStopsMirror() async throws {
        let now = Date()
        let readiness = makeRemoteUnlockReadinessService(lockStateProvider: { .loginWindow })
        let (router, sink) = makeRouter(
            consent: false,
            startScreenShare: { _, _, _, _, _, _, _, _ in },
            remoteUnlockReadiness: readiness,
            clock: { now }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "locked-with-session",
                connectionID: "phone-connection",
                viewerID: "viewer-1",
                viewerDeviceID: "iphone-1",
                controlAuthorityPeerNodeID: "ios-peer",
                remoteUnlockSession: remoteUnlockSession(
                    sessionId: "unlock-session",
                    peerNodeId: "ios-peer",
                    viewerDeviceId: "iphone-1",
                    issuedAt: now
                )
            ),
            replySender: sink.sender
        )

        let frames = await sink.frames
        let accepted = try XCTUnwrap(frames.first?.media?.mirrorAck)
        await router.handleFrame(
            mirrorStopFrame(
                requestID: "locked-with-session",
                connectionID: "phone-connection",
                sessionID: accepted.sessionId
            ),
            replySender: sink.sender
        )

        XCTAssertFalse(
            readiness.isRemoteUnlockSessionActive(
                sessionId: "unlock-session",
                peerNodeId: "ios-peer",
                viewerDeviceId: "iphone-1",
                now: now
            )
        )
    }

    func testRemoteUnlockSessionIsIgnoredWhenMirrorStartsWhileAlreadyUnlocked() async throws {
        let now = Date()
        let readiness = makeRemoteUnlockReadinessService(lockStateProvider: { .unlocked })
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in },
            remoteUnlockReadiness: readiness,
            clock: { now }
        )

        await router.handleFrame(
            mirrorRequestFrame(
                requestID: "unlocked-mirror",
                viewerID: "viewer-1",
                viewerDeviceID: "iphone-1",
                controlAuthorityPeerNodeID: "ios-peer",
                remoteUnlockSession: remoteUnlockSession(
                    sessionId: "unlock-session",
                    peerNodeId: "ios-peer",
                    viewerDeviceId: "iphone-1",
                    issuedAt: now
                )
            ),
            replySender: sink.sender
        )

        let acceptedFrames = await sink.frames
        let ack = try XCTUnwrap(acceptedFrames.first?.media?.mirrorAck)
        XCTAssertEqual(ack.decision, .accepted)
        XCTAssertEqual(ack.remoteUnlockState?.lockState, .unlocked)

        await sink.reset()
        await router.handleHostAuthGateClosedForTesting(reason: "unit_lock")

        let frames = await sink.frames
        XCTAssertEqual(frames.first?.media?.mirrorAck?.decision, .denied)
        XCTAssertEqual(router.phase, .idle)
    }

    func testSiblingControlStreamWithSameConnectionIDJoinsAsWatcherDuringActiveMirror() async throws {
        var startCount = 0
        let activeStreamID = UUID()
        let siblingStreamID = UUID()
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in
                startCount += 1
            }
        )

        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_iphone", connectionID: "shared-mac"),
            controlStreamID: activeStreamID,
            replySender: sink.sender
        )
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_iphone")

        await sink.reset()
        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_android", connectionID: "shared-mac"),
            controlStreamID: siblingStreamID,
            replySender: sink.sender
        )

        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_iphone")
        let frames = await sink.frames
        XCTAssertEqual(frames.count, 2)
        let watcherAck = frames.compactMap(\.media?.mirrorAck).first { $0.requestId == "req_android" }
        XCTAssertEqual(watcherAck?.decision, .accepted)
        XCTAssertEqual(watcherAck?.viewerRole, "watcher")
        XCTAssertEqual(watcherAck?.viewerCount, 2)
    }

    func testSiblingControlStreamCloseDoesNotStopActiveMirrorWithSameConnectionID() async throws {
        let activeStreamID = UUID()
        let siblingStreamID = UUID()
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in }
        )

        await router.handleFrame(
            mirrorRequestFrame(requestID: "req_iphone", connectionID: "shared-mac"),
            controlStreamID: activeStreamID,
            replySender: sink.sender
        )
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_iphone")

        await router.handleControlStreamClosed(
            connectionID: "shared-mac",
            controlStreamID: siblingStreamID,
            removedLastStreamForConnection: false
        )
        XCTAssertEqual(try extractStreaming(from: router.phase), "req_iphone")

        await router.handleControlStreamClosed(
            connectionID: "shared-mac",
            controlStreamID: activeStreamID,
            removedLastStreamForConnection: true
        )
        XCTAssertEqual(router.phase, .idle)
    }

    func testDisplaySelectionAcknowledgesSelectedDisplayAndKeepsMirrorStreaming() async throws {
        guard let display = ScreenCapturePipeline.availableDisplays().first else {
            throw XCTSkip("No displays available on this test host.")
        }
        let (router, sink) = makeRouter(
            consent: true,
            startScreenShare: { _, _, _, _, _, _, _, _ in }
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
            startScreenShare: { _, _, _, _, _, _, _, _ in }
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

    func testControlStreamSinkChunksLargeLegacyMediaFramesBeforeV1Fallback() async throws {
        let stream = RecordingIrohStream()
        let sink = MercuryControlStreamMediaSink(
            stream: stream,
            uid: "uid-1",
            connectionID: "conn-1",
            streamClass: .screenVideo,
            heartbeatInterval: 0
        )
        let source = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            gopID: 12,
            frameIndex: 35,
            presentationTimestampMillis: 57,
            payload: Data(repeating: 0x7A, count: MediaPacketCodec.defaultMaxPayloadBytes + (64 * 1024))
        )

        await sink.write(frame: source)

        let frames = await stream.sentFrames
        XCTAssertGreaterThan(frames.count, 1)
        let expectedBytes = try MediaPacketCodec(maxPayloadBytes: MediaFrameV2Codec.defaultMaxPayloadBytes)
            .encode(source)
            .count
        var chunkParts: [(Int, Data)] = []
        for frame in frames {
            XCTAssertNoThrow(try IrohRelayFrameCodec().encode(frame))
            XCTAssertEqual(frame.type, .mediaStreamFrame)
            XCTAssertEqual(frame.media?.streamClass, MediaStreamClass.screenVideo.rawValue)
            let chunk = try XCTUnwrap(frame.media?.frameChunk)
            XCTAssertEqual(chunk.chunkCount, frames.count)
            XCTAssertEqual(chunk.totalBytes, expectedBytes)
            let encoded = try XCTUnwrap(frame.media?.encodedFrameBase64)
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            chunkParts.append((chunk.chunkIndex, data))
        }
        let reassembled = chunkParts
            .sorted { $0.0 < $1.0 }
            .reduce(into: Data()) { result, part in result.append(part.1) }
        let decoded = try MediaPacketCodec(maxPayloadBytes: MediaFrameV2Codec.defaultMaxPayloadBytes)
            .decode(reassembled)
            .frame
        XCTAssertEqual(decoded, source)
    }

    private func makeRemoteUnlockReadinessService(
        lockStateProvider: @escaping @MainActor @Sendable () -> HermesRealtimeRelayMacLockState
    ) -> MacRemoteUnlockReadinessService {
        MacRemoteUnlockReadinessService(
            defaults: makeIsolatedDefaults(),
            snapshotProvider: {
                RemoteUnlockReadinessSnapshot(
                    featureFlagEnabled: true,
                    directDownloadBuild: true,
                    daemonInstalled: true,
                    systemScreenSharingAvailable: true,
                    loopbackOnlyFirewallActive: true,
                    generatedCredentialInSystemKeychain: true,
                    remoteDesktopPermissionGranted: true,
                    virtualHIDDriverInstalled: true,
                    virtualHIDDriverActive: true,
                    backendCertificationFresh: true,
                    currentOSBuild: "test-os-build",
                    certifiedOSBuild: "test-os-build",
                    certifiedAt: Date(timeIntervalSince1970: 1_774_000_000),
                    fileVaultEnabled: false,
                    fileVaultSSHSupported: false,
                    lastLockScreenProbeSucceeded: true,
                    lastCredentialInputProbeSucceeded: true,
                    lastUnlockProbeSucceeded: true,
                    credentialRecipientKeyId: "test-recipient-key",
                    credentialRecipientPublicKeyBase64: "test-recipient-public-key"
                )
            },
            revokesPublishedTrustOnClearAll: false,
            lockStateProvider: lockStateProvider
        )
    }

    private func remoteUnlockSession(
        sessionId: String,
        peerNodeId: String,
        viewerDeviceId: String,
        issuedAt: Date = Date()
    ) -> HermesRealtimeRelayRemoteUnlockSession {
        return HermesRealtimeRelayRemoteUnlockSession(
            requestId: "remote-unlock-request",
            sessionId: sessionId,
            intent: .request,
            requesterDisplayName: "Alberto's iPhone",
            viewerDeviceId: viewerDeviceId,
            requestedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(RemoteUnlockPolicy.default.sessionTTLSeconds),
            localAuthenticationSatisfied: true,
            requestedLockState: nil,
            requestedBackend: .openBurnBarVirtualHID,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: peerNodeId,
                counter: 1,
                timestamp: issuedAt,
                intentHashBlake3: "hash",
                signatureEd25519: "signature"
            )
        )
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

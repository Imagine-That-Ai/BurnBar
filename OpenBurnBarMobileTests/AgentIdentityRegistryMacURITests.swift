import XCTest
import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBarMobile

/// Mercury Phase 8 — locks in the `device://paired-mac/<id>` URI
/// resolution path. The registry synthesizes a `AgentIdentity` for
/// the Mercury Live tile only when `pairedMacPeer` is set, and the
/// returned identity carries the silver palette + macbook glyph.
@MainActor
final class AgentIdentityRegistryMacURITests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testPairedMacURIResolvesToSynthesizedIdentity() {
        let registry = AgentIdentityRegistry(seed: [])
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "macbook-pro-alberto",
            displayName: "Alberto's MacBook",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: MercuryPeer.macFallbackCapabilities
        )

        let identity = registry.identity(for: "device://paired-mac/macbook-pro-alberto")
        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.displayName, "Alberto's MacBook")
        XCTAssertEqual(identity?.glyph, "🖥")
        XCTAssertEqual(identity?.paletteHex, "8B9DC3")
        XCTAssertEqual(identity?.availability, .online)
        XCTAssertEqual(identity?.tagline, "Mirror, call, or send a file")
    }

    func testPairedMacURIReturnsNilWhenPeerSourceEmpty() {
        let registry = AgentIdentityRegistry(seed: [])
        XCTAssertNil(registry.pairedMacPeer)
        XCTAssertNil(registry.identity(for: "device://paired-mac/anything"))
    }

    func testOfflinePeerYieldsOfflineAvailability() {
        let registry = AgentIdentityRegistry(seed: [])
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "mac-1",
            displayName: "Backup Mac",
            isOnline: false,
            lastSeenAt: referenceDate,
            capabilities: []
        )

        let identity = registry.identity(for: "device://paired-mac/mac-1")
        XCTAssertEqual(identity?.availability, .offline)
    }

    func testKnownBuiltInURIStillResolvesEvenWithMercuryPeerSet() {
        let registry = AgentIdentityRegistry()
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "mac-1",
            displayName: "Mac",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: []
        )
        // Built-in lookups must keep working alongside the new
        // device path.
        let builtIn = registry.identity(for: AgentIdentity.builtInURI(.hermes))
        XCTAssertNotNil(builtIn)
        XCTAssertEqual(builtIn?.runtimeID, .hermes)
    }

    func testPhoneControlSetupMessagePromptsForTrustedDeviceWhenAuthorityWriteIsDenied() {
        let error = NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.permissionDenied.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Missing or insufficient permissions."]
        )

        XCTAssertEqual(
            PhoneControlSetupMessage.message(for: error),
            PhoneControlSetupMessage.trustedDeviceRequired
        )
    }

    func testMercuryMirrorLifecycleOnlyExplicitStopsEndHostSession() {
        XCTAssertTrue(MercuryMirrorTeardownTrigger.explicitClose.shouldSendMirrorStop)
        XCTAssertTrue(MercuryMirrorTeardownTrigger.signOut.shouldSendMirrorStop)
        XCTAssertFalse(MercuryMirrorTeardownTrigger.sheetDisappear.shouldSendMirrorStop)
        XCTAssertFalse(MercuryMirrorTeardownTrigger.viewerDisappear.shouldSendMirrorStop)
        XCTAssertFalse(MercuryMirrorTeardownTrigger.sceneInactive.shouldSendMirrorStop)
    }

    func testPhoneControlSetupMessagePreservesSpecificNetworkFailure() {
        let error = CloudGatewayError.classified(.networkUnavailable)

        XCTAssertEqual(
            PhoneControlSetupMessage.message(for: error),
            "You appear to be offline. Reconnect, then try Mac control again."
        )
    }

    func testIPadSplitPinnedRouteOpensMercuryLiveForPairedMacURI() {
        let registry = AgentIdentityRegistry(seed: [])
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "mac-1",
            displayName: "Studio Mac",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: MercuryPeer.macFallbackCapabilities
        )

        let route = HermesSquarePinnedRoute.route(
            for: "device://paired-mac/mac-1",
            registry: registry,
            visibleTiles: [.hermes]
        )

        XCTAssertEqual(route, .mercuryLive("mac-1"))
    }

    func testIPadSplitPinnedRouteKeepsVisibleRuntimeNative() {
        let registry = AgentIdentityRegistry()

        let route = HermesSquarePinnedRoute.route(
            for: AgentIdentity.builtInURI(.hermes),
            registry: registry,
            visibleTiles: [.hermes, .pi]
        )

        XCTAssertEqual(route, .runtimeNative(.hermes))
    }

    func testIPadMercuryDetailRejectsStaleCoordinatorForDifferentRelay() {
        XCTAssertFalse(MercuryLiveCoordinatorSelection.shouldUse(
            activeConnectionID: "relay-old",
            requestedConnectionID: "relay-new",
            phase: .reconnecting(nextAttemptIn: 0.2)
        ))
    }

    func testIPadMercuryDetailRebootsStoppedCoordinatorForSameRelay() {
        XCTAssertFalse(MercuryLiveCoordinatorSelection.shouldUse(
            activeConnectionID: "relay-live",
            requestedConnectionID: "relay-live",
            phase: .stopped
        ))
        XCTAssertFalse(MercuryLiveCoordinatorSelection.shouldUse(
            activeConnectionID: "relay-live",
            requestedConnectionID: "relay-live",
            phase: .failed(reason: "Mac closed the control stream.")
        ))
    }

    func testIPadMercuryDetailKeepsHydratedRelayForVirtualPairedMacRoute() {
        XCTAssertTrue(MercuryLiveCoordinatorSelection.shouldUse(
            activeConnectionID: "relay-live",
            requestedConnectionID: "paired-mac:default",
            phase: .live
        ))
    }

    func testCompactNavigationRetargetUsesSingleStepForFreshRoute() {
        let requested = HermesSquareRoot.NavTarget.runtimeNative(.hermes)
        let sequence = HermesSquareNavigationRetarget.sequence(
            current: nil,
            requested: requested
        )

        XCTAssertEqual(sequence, [requested])
    }

    func testCompactNavigationRetargetClearsThenReappliesSameRoute() {
        let requested = HermesSquareRoot.NavTarget.runtimeNative(.hermes)
        let sequence = HermesSquareNavigationRetarget.sequence(
            current: requested,
            requested: requested
        )

        XCTAssertEqual(sequence.count, 2)
        XCTAssertNil(sequence[0])
        XCTAssertEqual(sequence[1], requested)
    }

    func testCompactNavigationRetargetReplacesDifferentRouteInSingleStep() {
        let current = HermesSquareRoot.NavTarget.brandZone(AgentIdentity.builtInURI(.claude))
        let requested = HermesSquareRoot.NavTarget.runtimeNative(.hermes)
        let sequence = HermesSquareNavigationRetarget.sequence(
            current: current,
            requested: requested
        )

        XCTAssertEqual(sequence, [requested])
    }
}

@MainActor
final class MediaControlStreamPresenceTests: XCTestCase {
    func testHeartbeatAdvertisesLiveV2ReceiverSupport() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)

        let sentFrames = await stream.sentFrames
        let heartbeat = try XCTUnwrap(sentFrames.first { $0.type == .mediaPresenceHeartbeat })
        let versions = try XCTUnwrap(heartbeat.media?.presence?.streamingCapabilities?.mediaFrameVersions)
        XCTAssertTrue(versions.supportsV1)
        XCTAssertTrue(versions.supportsV2)
        await coordinator.stop()
    }

    func testMacPresenceHeartbeatUpdatesControlRoundTripMillis() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)
        try await waitUntilHeartbeatCount(stream, count: 1)

        XCTAssertNil(coordinator.lastRoundTripMillis)
        await stream.pushInbound(macPresenceFrame(uid: "user-1", connectionID: "conn-1"))
        try await waitUntil { coordinator.lastRoundTripMillis != nil }

        XCTAssertGreaterThanOrEqual(coordinator.lastRoundTripMillis ?? -1, 0)
        await coordinator.stop()
    }

    func testReadLoopForwardsMacPresenceHeartbeatToInstalledHandler() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        let received = expectation(description: "presence heartbeat forwarded")
        coordinator.presenceHeartbeatHandler = { heartbeat in
            XCTAssertEqual(heartbeat.deviceDisplayName, "Alberto's Mac")
            XCTAssertEqual(heartbeat.capabilities, [
                MercuryPeer.Feature.mirrorHost.rawValue,
                MercuryPeer.Feature.fileReceive.rawValue
            ])
            received.fulfill()
        }

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)

        await stream.pushInbound(HermesRealtimeRelayFrame(
            type: .mediaPresenceHeartbeat,
            uid: "user-1",
            connectionId: "conn-1",
            media: HermesRealtimeRelayMediaPayload(
                presence: HermesRealtimeRelayPresenceHeartbeat(
                    sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                    deviceDisplayName: "Alberto's Mac",
                    capabilities: [
                        MercuryPeer.Feature.mirrorHost.rawValue,
                        MercuryPeer.Feature.fileReceive.rawValue
                    ]
                )
            )
        ))

        await fulfillment(of: [received], timeout: 1.0)
        XCTAssertNotNil(coordinator.lastInboundAt)
        await coordinator.stop()
    }

    func testReadLoopForwardsControlDeniedToInstalledHandler() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        let received = expectation(description: "control denial forwarded")
        coordinator.controlDeniedHandler = { denied in
            XCTAssertEqual(denied.reason, .unknown)
            XCTAssertEqual(denied.detail, ComputerUseDenyReason.accessibilityRevoked.rawValue)
            received.fulfill()
        }

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)

        await stream.pushInbound(HermesRealtimeRelayFrame(
            type: .controlDenied,
            uid: "user-1",
            connectionId: "conn-1",
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                denied: HermesRealtimeRelayControlDenied(
                    reason: .unknown,
                    detail: ComputerUseDenyReason.accessibilityRevoked.rawValue
                )
            )
        ))

        await fulfillment(of: [received], timeout: 1.0)
        XCTAssertNotNil(coordinator.lastInboundAt)
        await coordinator.stop()
    }

    func testEnsureResponsiveReturnsForFreshInboundFrame() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)
        await stream.pushInbound(macPresenceFrame(uid: "user-1", connectionID: "conn-1"))
        try await waitForInbound(coordinator)

        let sentBeforeProbe = await stream.sentFrames.count
        try await coordinator.ensureResponsive(
            uid: "user-1",
            connectionID: "conn-1",
            freshnessInterval: 10,
            probeTimeout: 0.05,
            restartTimeout: 0.5
        )

        let sentAfterProbe = await stream.sentFrames.count
        XCTAssertEqual(sentAfterProbe, sentBeforeProbe, "fresh Mac traffic should avoid an unnecessary probe send")
        await coordinator.stop()
    }

    func testEnsureResponsiveRestartsHalfStaleStreamBeforeMirrorTraffic() async throws {
        let firstStream = MediaControlFakeStream()
        let secondStream = MediaControlFakeStream()
        let receiver = makeReceiver()
        var dialCount = 0
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in
                dialCount += 1
                return dialCount == 1 ? firstStream : secondStream
            },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)

        let ensureTask = Task {
            try await coordinator.ensureResponsive(
                uid: "user-1",
                connectionID: "conn-1",
                freshnessInterval: 0,
                probeTimeout: 0.05,
                restartTimeout: 1.0
            )
        }

        try await waitUntil { dialCount >= 2 }
        try await waitUntilHeartbeatCount(secondStream, count: 2)
        await secondStream.pushInbound(macPresenceFrame(uid: "user-1", connectionID: "conn-1"))
        try await ensureTask.value

        let firstCloseCount = await firstStream.closeCount
        XCTAssertEqual(firstCloseCount, 1, "the half-stale stream must be closed before redial")
        XCTAssertEqual(coordinator.phase, .live)
        XCTAssertNotNil(coordinator.lastInboundAt)
        await coordinator.stop()
    }

    func testSendRetargetsStaleLiveStreamBeforePhoneControlTraffic() async throws {
        let staleStream = MediaControlFakeStream()
        let currentStream = MediaControlFakeStream()
        let receiver = makeReceiver()
        var dialedConnectionIDs: [String] = []
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, connectionID in
                dialedConnectionIDs.append(connectionID)
                return connectionID == "conn-current" ? currentStream : staleStream
            },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        coordinator.start(uid: "user-1", connectionID: "conn-stale")
        try await waitUntilLive(coordinator)

        let phoneControlFrame = HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: "user-1",
            connectionId: "conn-current",
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue
            )
        )
        try await coordinator.send(frame: phoneControlFrame, timeout: 1.0)

        let staleFrames = await staleStream.sentFrames
        let currentFrames = await currentStream.sentFrames
        let staleCloseCount = await staleStream.closeCount
        XCTAssertEqual(dialedConnectionIDs, ["conn-stale", "conn-current"])
        XCTAssertEqual(staleCloseCount, 1)
        XCTAssertFalse(
            staleFrames.contains { $0.type == .controlInputIntent },
            "phone-control input must not ride a stale media-control stream"
        )
        XCTAssertTrue(
            currentFrames.contains {
                $0.type == .controlInputIntent
                    && $0.connectionId == "conn-current"
            },
            "phone-control input must be sent after retargeting to the active Mac route"
        )
        await coordinator.stop()
    }

    func testReadLoopRoutesV2ScreenFramesToV2Handler() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        let expected = MediaFrameV2(
            kind: .videoNAL,
            flags: 0x0001,
            gopID: 41,
            frameIndex: 7,
            presentationTimestampMillis: 1_777,
            metadata: try MediaFrameV2Metadata(
                codec: .hevc,
                longTermReferenceToken: MercuryLTRToken(value: 12)
            ).encode(),
            payload: Data([0x01, 0x02, 0x03])
        )
        let encoded = try MediaFrameV2Codec().encode(expected, negotiatedVersion: .v2)

        let received = expectation(description: "v2 stream frame routed")
        coordinator.mirrorFrameV2Handler = { frame in
            XCTAssertEqual(frame, expected)
            received.fulfill()
        }
        coordinator.mirrorFrameHandler = { _ in
            XCTFail("v2 envelope must not be decoded by the v1 media packet path")
        }

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)
        await stream.pushInbound(screenVideoFrame(uid: "user-1", connectionID: "conn-1", encoded: encoded))

        await fulfillment(of: [received], timeout: 1.0)
        await coordinator.stop()
    }

    func testReadLoopKeepsRoutingLegacyScreenFramesToV1Handler() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        let expected = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            gopID: 42,
            frameIndex: 8,
            presentationTimestampMillis: 1_778,
            payload: Data([0x04, 0x05, 0x06])
        )
        let encoded = try MediaPacketCodec().encode(expected)

        let received = expectation(description: "v1 stream frame routed")
        coordinator.mirrorFrameV2Handler = { _ in
            XCTFail("v1 envelope must not be routed to the MediaFrame v2 path")
        }
        coordinator.mirrorFrameHandler = { frame in
            XCTAssertEqual(frame, expected)
            received.fulfill()
        }

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)
        await stream.pushInbound(screenVideoFrame(uid: "user-1", connectionID: "conn-1", encoded: encoded))

        await fulfillment(of: [received], timeout: 1.0)
        await coordinator.stop()
    }

    func testReadLoopReassemblesLargeLegacyScreenFramesToV1Handler() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        let expected = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            gopID: 43,
            frameIndex: 9,
            presentationTimestampMillis: 1_779,
            payload: Data(repeating: 0x7A, count: MediaPacketCodec.defaultMaxPayloadBytes + (64 * 1024))
        )
        let encoded = try MediaPacketCodec(maxPayloadBytes: MediaFrameV2Codec.defaultMaxPayloadBytes)
            .encode(expected)
        let chunkSize = 100_000
        let chunks = stride(from: 0, to: encoded.count, by: chunkSize).map { start -> Data in
            encoded.subdata(in: start..<min(start + chunkSize, encoded.count))
        }

        let received = expectation(description: "large v1 stream frame routed")
        coordinator.mirrorFrameV2Handler = { _ in
            XCTFail("legacy v1 envelope must not be routed to the MediaFrame v2 path")
        }
        coordinator.mirrorFrameHandler = { frame in
            XCTAssertEqual(frame, expected)
            received.fulfill()
        }

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)
        for (index, chunk) in chunks.enumerated() {
            await stream.pushInbound(screenVideoFrame(
                uid: "user-1",
                connectionID: "conn-1",
                encoded: chunk,
                frameChunk: HermesRealtimeRelayMediaFrameChunk(
                    chunkId: "large-v1-frame",
                    chunkIndex: index,
                    chunkCount: chunks.count,
                    totalBytes: encoded.count
                )
            ))
        }

        await fulfillment(of: [received], timeout: 1.0)
        await coordinator.stop()
    }

    func testSendMirrorStopEmitsCorrelatedMacTeardownFrame() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)

        try await coordinator.sendMirrorStop(
            requestId: "req-stop-1",
            reason: "viewer_closed",
            timeout: 1
        )

        let sentFrames = await stream.sentFrames
        let stop = try XCTUnwrap(sentFrames.first { $0.type == .mediaMirrorStop })
        XCTAssertEqual(stop.uid, "user-1")
        XCTAssertEqual(stop.connectionId, "conn-1")
        XCTAssertEqual(stop.requestId, "req-stop-1")
        XCTAssertEqual(stop.media?.mirrorStop?.requestId, "req-stop-1")
        XCTAssertEqual(stop.media?.mirrorStop?.reason, "viewer_closed")
        await coordinator.stop()
    }

    private func waitUntilLive(_ coordinator: MediaControlStreamCoordinator) async throws {
        let deadline = Date().addingTimeInterval(1.0)
        while coordinator.phase != .live {
            if Date() > deadline {
                XCTFail("media control stream did not become live")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForInbound(_ coordinator: MediaControlStreamCoordinator) async throws {
        let deadline = Date().addingTimeInterval(1.0)
        while coordinator.lastInboundAt == nil {
            if Date() > deadline {
                XCTFail("media control stream did not receive inbound traffic")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1.0)
        while !predicate() {
            if Date() > deadline {
                XCTFail("condition was not met before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntilHeartbeatCount(_ stream: MediaControlFakeStream, count: Int) async throws {
        let deadline = Date().addingTimeInterval(1.0)
        while await stream.sentFrames.filter({ $0.type == .mediaPresenceHeartbeat }).count < count {
            if Date() > deadline {
                XCTFail("expected \(count) heartbeat frame(s)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testLiveTransitionCapturesLastLiveAtAndClearsFailureReason() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)

        XCTAssertNotNil(coordinator.lastLiveAt, "lastLiveAt should be set on .live transition")
        XCTAssertNil(coordinator.lastFailureReason, "lastFailureReason should be nil on first .live")
        XCTAssertNil(coordinator.reconnectAttemptStartedAt, "reconnectAttemptStartedAt should be nil on .live")
        await coordinator.stop()
    }

    func testFailedDialPopulatesLastFailureReasonAndReconnectAnchor() async throws {
        struct DialFailure: LocalizedError {
            var errorDescription: String? { "Pairing key fetch timed out." }
        }

        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in throw DialFailure() },
            receiver: receiver,
            initialBackoff: 0.05,
            maxBackoff: 0.05
        )

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        // Wait for the first failure to land and the supervisor to
        // enter `.reconnecting`.
        let deadline = Date().addingTimeInterval(1.0)
        while coordinator.lastFailureReason == nil {
            if Date() > deadline {
                XCTFail("dial failure reason was never surfaced")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(coordinator.lastFailureReason, "Pairing key fetch timed out.")
        XCTAssertNotNil(coordinator.reconnectAttemptStartedAt,
                        "reconnectAttemptStartedAt anchors the ticking countdown — must be set on .reconnecting")
        await coordinator.stop()
    }

    func testStopClearsTransientReconnectMetadata() async throws {
        struct DialFailure: LocalizedError {
            var errorDescription: String? { "Boom." }
        }

        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in throw DialFailure() },
            receiver: receiver,
            initialBackoff: 0.05,
            maxBackoff: 0.05
        )

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        let deadline = Date().addingTimeInterval(1.0)
        while coordinator.reconnectAttemptStartedAt == nil {
            if Date() > deadline { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await coordinator.stop()
        XCTAssertNil(coordinator.reconnectAttemptStartedAt,
                     "stop() must clear the reconnect anchor so the UI does not animate a stale countdown")
        XCTAssertNil(coordinator.lastFailureReason,
                     "stop() must clear the last failure reason so the next start doesn't leak it")
    }

    private func screenVideoFrame(
        uid: String,
        connectionID: String,
        encoded: Data,
        frameChunk: HermesRealtimeRelayMediaFrameChunk? = nil
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaStreamFrame,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.screenVideo.rawValue,
                encodedFrameBase64: encoded.base64EncodedString(),
                frameChunk: frameChunk
            )
        )
    }

    private func macPresenceFrame(uid: String, connectionID: String) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaPresenceHeartbeat,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(
                presence: HermesRealtimeRelayPresenceHeartbeat(
                    sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                    deviceDisplayName: "Alberto's Mac",
                    capabilities: [
                        MercuryPeer.Feature.mirrorHost.rawValue,
                        MercuryPeer.Feature.fileReceive.rawValue
                    ]
                )
            )
        )
    }

    private func makeReceiver() -> iOSFileTransferService {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-mobile-tests-\(UUID().uuidString)", isDirectory: true)
        let service = MediaFileTransferService(
            backend: MediaControlFakeBlobBackend(),
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: temp.appendingPathComponent("inbox", isDirectory: true),
                secretKeyProvider: { Data(repeating: 0xAB, count: 32) }
            )
        )
        return iOSFileTransferService(service: service, settingsProvider: { true })
    }
}

private actor MediaControlFakeStream: IrohRelayStream {
    private var inboundFrames: [HermesRealtimeRelayFrame] = []
    private var outboundFrames: [HermesRealtimeRelayFrame] = []
    private var receiveWaiter: CheckedContinuation<HermesRealtimeRelayFrame?, Error>?
    private var isClosed = false
    private var closeCallCount = 0

    var sentFrames: [HermesRealtimeRelayFrame] { outboundFrames }
    var closeCount: Int { closeCallCount }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        outboundFrames.append(frame)
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        if !inboundFrames.isEmpty { return inboundFrames.removeFirst() }
        if isClosed { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiter = continuation
        }
    }

    func close() async {
        closeCallCount += 1
        isClosed = true
        receiveWaiter?.resume(returning: nil)
        receiveWaiter = nil
    }

    func pushInbound(_ frame: HermesRealtimeRelayFrame) {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: frame)
            return
        }
        inboundFrames.append(frame)
    }
}

private final class MediaControlFakeBlobBackend: IrohBlobBackend, @unchecked Sendable {
    func bootstrap(secret: Data, storeDirectoryPath: String, relayURL: String?) async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "fake-node", rawPublicKey: Data(secret.prefix(32)))
    }

    func publishBlob(localPath: String) async throws -> String {
        "blob1fake"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        BlobTransferStats(
            bytesTotal: 0,
            blake3Hash: "blake3:fake",
            durationMillis: 0,
            didResume: false
        )
    }

    func identity() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "fake-node", rawPublicKey: Data(repeating: 0, count: 32))
    }

    func shutdown() async {}
}

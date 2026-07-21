#if os(Linux)
import Foundation
import OpenBurnBarEngine
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBarDaemon
import XCTest

final class MercuryLinuxAudioPlaybackTests: XCTestCase {
    func testCapabilityAdvertisesInboundOpusPlaybackSeparately() {
        let capability = MercuryLinuxCapabilityProbe.snapshot(
            mediaSocketPath: "/run/user/1000/openburnbar-media.sock"
        )
        XCTAssertNotNil(capability.codecs["opusPlayback"])
    }

    func testRecordingPlaybackAdapterOwnsLifecycleAndPackets() throws {
        let adapter = RecordingMercuryLinuxAudioPlaybackAdapter()
        try adapter.startIfNeeded()
        try adapter.startIfNeeded()
        adapter.play(
            MediaFrame(
                kind: .audioOpus,
                presentationTimestampMillis: 20,
                payload: Data([0x01, 0x02])
            )
        )
        XCTAssertEqual(adapter.startCount, 1)
        XCTAssertEqual(adapter.frames.count, 1)
        adapter.stop()
        XCTAssertEqual(adapter.stopCount, 1)
    }

    func testInboundSealedOpusFrameIsPlayedBeforeShellForwarding() async throws {
        let channel = try MercuryLinuxMediaChannel(
            socketPath: "/tmp/obb-audio-playback-(UUID().uuidString).sock",
            maxQueuedFrames: 4
        )
        let key = PlatformSymmetricKey(size: .bits256)
        let playback = RecordingMercuryLinuxAudioPlaybackAdapter()
        let controller = MercuryLinuxMediaSessionController(
            channel: channel,
            captureAdapter: AudioPlaybackNoopCaptureAdapter(),
            audioPlaybackAdapter: playback,
            sealKeyOpener: AudioPlaybackStaticSealKeyOpener(key: key)
        )
        try await controller.start()
        defer { channel.stop() }

        await controller.ingestMercuryFrame(audioPlaybackMirrorRequest())
        let accepted = await controller.accept(
            DaemonMediaCallAcceptRequest(requestID: "audio-mirror", sessionID: "audio-session")
        )
        XCTAssertTrue(accepted.accepted)

        let frame = MediaFrame(
            kind: .audioOpus,
            gopID: 0,
            frameIndex: 0,
            presentationTimestampMillis: 20,
            payload: Data([0x91, 0x92, 0x93])
        )
        let packet = try MediaPacketCodec().encode(frame)
        let sealed = try MediaFrameAEAD().seal(
            plaintext: packet,
            key: key,
            streamClass: MediaStreamClass.audioIn.rawValue,
            kind: frame.kind.rawValue,
            gopID: frame.gopID,
            frameIndex: frame.frameIndex
        )
        await controller.ingestMercuryFrame(
            HermesRealtimeRelayFrame(
                type: .mediaStreamFrame,
                uid: "audio-uid",
                connectionId: "audio-connection",
                media: HermesRealtimeRelayMediaPayload(
                    streamClass: MediaStreamClass.audioIn.rawValue,
                    encodedFrameBase64: sealed.base64EncodedString(),
                    sealedFramePosition: HermesRealtimeRelaySealedMediaFramePosition(
                        kind: frame.kind.rawValue,
                        gopId: frame.gopID,
                        frameIndex: frame.frameIndex
                    )
                )
            )
        )

        XCTAssertEqual(playback.startCount, 1)
        XCTAssertEqual(playback.frames, [frame])
        let streamingSnapshot = await controller.sessionSnapshot()
        XCTAssertEqual(streamingSnapshot.phase, .streaming)
        XCTAssertEqual(streamingSnapshot.queuedFrameCount, 1)
        await controller.stop()
        XCTAssertEqual(playback.stopCount, 1)
    }

    func testPlaybackFailureFailsClosedAndTearsDownRoute() async throws {
        let playback = RecordingMercuryLinuxAudioPlaybackAdapter()
        playback.playError = MercuryLinuxAudioPlaybackError.pushFailed
        let key = PlatformSymmetricKey(size: .bits256)
        let controller = MercuryLinuxMediaSessionController(
            captureAdapter: AudioPlaybackNoopCaptureAdapter(),
            audioPlaybackAdapter: playback,
            sealKeyOpener: AudioPlaybackStaticSealKeyOpener(key: key)
        )
        await controller.ingestMercuryFrame(audioPlaybackMirrorRequest())
        let accepted = await controller.accept(
            DaemonMediaCallAcceptRequest(requestID: "audio-mirror", sessionID: "audio-failure")
        )
        XCTAssertTrue(accepted.accepted)
        let frame = MediaFrame(
            kind: .audioOpus,
            presentationTimestampMillis: 20,
            payload: Data([0xAA])
        )
        let packet = try MediaPacketCodec().encode(frame)
        let sealed = try MediaFrameAEAD().seal(
            plaintext: packet,
            key: key,
            streamClass: MediaStreamClass.audioIn.rawValue,
            kind: frame.kind.rawValue,
            gopID: frame.gopID,
            frameIndex: frame.frameIndex
        )
        await controller.ingestMercuryFrame(
            HermesRealtimeRelayFrame(
                type: .mediaStreamFrame,
                uid: "audio-uid",
                connectionId: "audio-connection",
                media: HermesRealtimeRelayMediaPayload(
                    streamClass: MediaStreamClass.audioIn.rawValue,
                    encodedFrameBase64: sealed.base64EncodedString(),
                    sealedFramePosition: HermesRealtimeRelaySealedMediaFramePosition(
                        kind: frame.kind.rawValue,
                        gopId: frame.gopID,
                        frameIndex: frame.frameIndex
                    )
                )
            )
        )
        XCTAssertEqual(playback.startCount, 1)
        XCTAssertEqual(playback.stopCount, 1)
        let cooldownSnapshot = await controller.sessionSnapshot()
        XCTAssertEqual(cooldownSnapshot.phase, .cooldown)
        await controller.stop()
    }

    func testRouteEndStopsAnActiveNativePlaybackPipeline() async throws {
        let playback = RecordingMercuryLinuxAudioPlaybackAdapter()
        let controller = MercuryLinuxMediaSessionController(
            captureAdapter: AudioPlaybackNoopCaptureAdapter(),
            audioPlaybackAdapter: playback,
            sealKeyOpener: AudioPlaybackStaticSealKeyOpener(
                key: PlatformSymmetricKey(size: .bits256)
            )
        )
        await controller.ingestMercuryFrame(
            audioPlaybackMirrorRequest(),
            remotePeerNodeID: "phone-node"
        )
        let accepted = await controller.accept(
            DaemonMediaCallAcceptRequest(requestID: "audio-mirror", sessionID: "audio-route")
        )
        XCTAssertTrue(accepted.accepted)
        try playback.startIfNeeded()

        await controller.routeEnded(
            uid: "audio-uid",
            connectionID: "audio-connection",
            remotePeerNodeID: "phone-node",
            reason: "controller_route_revoked"
        )

        XCTAssertEqual(playback.stopCount, 1)
        let snapshot = await controller.sessionSnapshot()
        XCTAssertEqual(snapshot.phase, .cooldown)
    }

    private func audioPlaybackMirrorRequest() -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: "audio-uid",
            connectionId: "audio-connection",
            requestId: "audio-mirror",
            media: HermesRealtimeRelayMediaPayload(
                mirrorRequest: HermesRealtimeRelayMirrorRequest(
                    requestId: "audio-mirror",
                    requestedAt: Date(),
                    requesterDisplayName: "iPad",
                    streamClass: MediaStreamClass.screenVideo.rawValue
                )
            )
        )
    }
}

private struct AudioPlaybackStaticSealKeyOpener: MercuryLinuxMediaSealKeyOpening {
    let key: PlatformSymmetricKey

    func openMediaFrameSealKey(
        for request: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame
    ) async throws -> PlatformSymmetricKey {
        _ = request
        _ = frame
        return key
    }

    func openMediaFrameSealKey(
        for invite: HermesRealtimeRelayCallInvite,
        frame: HermesRealtimeRelayFrame
    ) async throws -> PlatformSymmetricKey {
        _ = invite
        _ = frame
        return key
    }
}

private final class AudioPlaybackNoopCaptureAdapter:
    MercuryLinuxCaptureAdapterProtocol, @unchecked Sendable {
    func startOutboundCapture(
        targetBitrateBps: UInt32,
        codec: MercuryLinuxCaptureCodec,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = targetBitrateBps
        _ = codec
        _ = onFrame
        _ = onStopped
    }

    func stopOutboundCapture() {}

    func setOutboundCaptureBitrate(_ targetBitrateBps: UInt32) throws {
        _ = targetBitrateBps
    }
}
#endif

#if canImport(AppKit)
import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia
import XCTest
@testable import OpenBurnBar

/// F7 — Mac-side media frame sealing:
///  * `MacMediaSealKeyOpener` opens the phone-wrapped seal key from a mirror
///    request via the pinned-sender trust path, fails OPEN to the legacy
///    plaintext lane (nil) on any establishment failure, and returns nil when
///    no wrap is present.
///  * `MercuryControlStreamMediaSink` seals every encoded frame (v1 and v2)
///    with position-bound AAD when a seal key is present, attaches the
///    cleartext `sealedFramePosition`, and keeps the legacy plaintext wire
///    form byte-compatible when no key was negotiated.
final class MediaFrameSealLaneTests: XCTestCase {

    override func tearDown() {
        MacMediaSealKeyOpener.recipientPrivateKeyProvider = nil
        MacMediaSealKeyOpener.pinnedSenderKeyProvider = nil
        super.tearDown()
    }

    private func keyBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private func makeMirrorRequest(
        mediaSealKey: HermesRealtimeRelayControlSealKeyEnvelope?
    ) -> HermesRealtimeRelayMirrorRequest {
        HermesRealtimeRelayMirrorRequest(
            requestId: "mirror-seal-1",
            requestedAt: Date(),
            requesterDisplayName: "Test iPhone",
            streamClass: MediaStreamClass.screenVideo.rawValue,
            viewerId: "viewer-1",
            mediaSealKey: mediaSealKey
        )
    }

    private func makeFrame(control: HermesRealtimeRelayControlPayload? = nil) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: "uid-seal",
            connectionId: "conn-seal",
            control: control
        )
    }

    // MARK: - MacMediaSealKeyOpener

    func test_openerReturnsNilWhenRequestCarriesNoWrap() async {
        let key = await MacMediaSealKeyOpener.frameSealKey(
            for: makeMirrorRequest(mediaSealKey: nil),
            frame: makeFrame()
        )
        XCTAssertNil(key, "pre-F7 requests must stay on the legacy plaintext lane")
    }

    func test_openerDerivesTheSameSealKeyThePhoneEstablished() async throws {
        let macRelayKey = HermesRelayCrypto.generatePrivateKey()
        let phoneSenderKey = HermesRelayCrypto.generatePrivateKey()
        let (envelope, phoneKey) = try MediaFrameSealSession.establish(
            uid: "uid-seal",
            connectionID: "conn-seal",
            viewerId: "viewer-1",
            senderDeviceID: "iphone-1",
            senderPeerNodeID: "phone-relay-peer",
            senderKeyID: "key-1",
            senderCounter: 3,
            recipientPublicKeyBase64: macRelayKey.publicKeyBase64,
            senderPrivateKey: phoneSenderKey
        )

        MacMediaSealKeyOpener.recipientPrivateKeyProvider = { macRelayKey }
        MacMediaSealKeyOpener.pinnedSenderKeyProvider = { _, _, _ in phoneSenderKey.publicKeyBase64 }

        let macKey = await MacMediaSealKeyOpener.frameSealKey(
            for: makeMirrorRequest(mediaSealKey: envelope),
            frame: makeFrame()
        )
        XCTAssertEqual(macKey.map(keyBytes), keyBytes(phoneKey), "both peers must derive the identical AES-GCM seal key")
    }

    func test_openerFailsOpenToLegacyLaneOnWrongPinnedSender() async throws {
        let macRelayKey = HermesRelayCrypto.generatePrivateKey()
        let phoneSenderKey = HermesRelayCrypto.generatePrivateKey()
        let attackerKey = HermesRelayCrypto.generatePrivateKey()
        let (envelope, _) = try MediaFrameSealSession.establish(
            uid: "uid-seal",
            connectionID: "conn-seal",
            viewerId: "viewer-1",
            senderDeviceID: "iphone-1",
            senderPeerNodeID: "phone-relay-peer",
            senderKeyID: "key-1",
            senderCounter: 3,
            recipientPublicKeyBase64: macRelayKey.publicKeyBase64,
            senderPrivateKey: phoneSenderKey
        )

        MacMediaSealKeyOpener.recipientPrivateKeyProvider = { macRelayKey }
        // The pinned key (trusted source) disagrees with the actual sender —
        // an unauthenticated wrap must NOT establish a seal session.
        MacMediaSealKeyOpener.pinnedSenderKeyProvider = { _, _, _ in attackerKey.publicKeyBase64 }

        let macKey = await MacMediaSealKeyOpener.frameSealKey(
            for: makeMirrorRequest(mediaSealKey: envelope),
            frame: makeFrame()
        )
        XCTAssertNil(macKey, "establishment failure degrades to the plaintext-at-app-layer lane by design")
    }

    // MARK: - MercuryControlStreamMediaSink seal lane

    private final class FrameCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [HermesRealtimeRelayFrame] = []
        func record(_ frame: HermesRealtimeRelayFrame) {
            lock.lock(); defer { lock.unlock() }
            _frames.append(frame)
        }
        var frames: [HermesRealtimeRelayFrame] {
            lock.lock(); defer { lock.unlock() }
            return _frames.filter { $0.type == .mediaStreamFrame }
        }
    }

    private func makeSink(capture: FrameCapture, frameSealKey: SymmetricKey?) -> MercuryControlStreamMediaSink {
        MercuryControlStreamMediaSink(
            sender: { frame in capture.record(frame) },
            uid: "uid-seal",
            connectionID: "conn-seal",
            streamClass: .screenVideo,
            heartbeatInterval: 3_600,
            extraHeartbeatCapabilities: [],
            frameSealKey: frameSealKey
        )
    }

    func test_sinkSealsV1FramesWithPositionBoundAADAndCleartextPosition() async throws {
        let key = SymmetricKey(size: .bits256)
        let capture = FrameCapture()
        let sink = makeSink(capture: capture, frameSealKey: key)
        defer { Task { await sink.close() } }

        let frame = MediaFrame(kind: .videoNAL, gopID: 7, frameIndex: 21, payload: Data("nal-bytes".utf8))
        await sink.write(frame: frame)

        let sent = try XCTUnwrap(capture.frames.first)
        let media = try XCTUnwrap(sent.media)
        XCTAssertEqual(media.streamClass, MediaStreamClass.screenVideo.rawValue)

        // The cleartext position mirrors the frame's stream position exactly.
        let position = try XCTUnwrap(media.sealedFramePosition)
        XCTAssertEqual(position.kind, MediaFrame.Kind.videoNAL.rawValue)
        XCTAssertEqual(position.gopId, 7)
        XCTAssertEqual(position.frameIndex, 21)

        // The payload opens ONLY under the position-bound AAD…
        let sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(media.encodedFrameBase64)))
        let opened = try MediaFrameAEAD().open(
            envelope: sealed,
            key: key,
            streamClass: MediaStreamClass.screenVideo.rawValue,
            kind: position.kind,
            gopID: position.gopId,
            frameIndex: position.frameIndex
        )
        let decoded = try MediaPacketCodec(maxPayloadBytes: MediaFrameV2Codec.defaultMaxPayloadBytes).decode(opened)
        XCTAssertEqual(decoded.frame.payload, Data("nal-bytes".utf8))

        // …and a shifted position (replay into another slot) fails the tag.
        XCTAssertThrowsError(
            try MediaFrameAEAD().open(
                envelope: sealed,
                key: key,
                streamClass: MediaStreamClass.screenVideo.rawValue,
                kind: position.kind,
                gopID: position.gopId,
                frameIndex: position.frameIndex + 1
            )
        )
    }

    func test_sinkSealsV2FramesAndPositionSurvivesTheWireRoundTrip() async throws {
        let key = SymmetricKey(size: .bits256)
        let capture = FrameCapture()
        let sink = makeSink(capture: capture, frameSealKey: key)
        defer { Task { await sink.close() } }

        let frameV2 = MediaFrameV2(kind: .videoNAL, gopID: 2, frameIndex: 9, payload: Data("v2-bytes".utf8))
        await sink.write(frameV2: frameV2)

        let sent = try XCTUnwrap(capture.frames.first)
        // Wire round trip: the position must survive frame JSON coding.
        let rewired = try JSONDecoder().decode(
            HermesRealtimeRelayFrame.self,
            from: JSONEncoder().encode(sent)
        )
        let media = try XCTUnwrap(rewired.media)
        let position = try XCTUnwrap(media.sealedFramePosition)
        XCTAssertEqual(position.kind, MediaFrameV2.Kind.videoNAL.rawValue)
        XCTAssertEqual(position.gopId, 2)
        XCTAssertEqual(position.frameIndex, 9)

        let sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(media.encodedFrameBase64)))
        let opened = try MediaFrameAEAD().open(
            envelope: sealed,
            key: key,
            streamClass: MediaStreamClass.screenVideo.rawValue,
            kind: position.kind,
            gopID: position.gopId,
            frameIndex: position.frameIndex
        )
        let decoded = try MediaFrameV2Codec().decode(opened)
        XCTAssertEqual(decoded.frame.payload, Data("v2-bytes".utf8))
    }

    func test_sinkWithoutSealKeyKeepsLegacyPlaintextWireForm() async throws {
        let capture = FrameCapture()
        let sink = makeSink(capture: capture, frameSealKey: nil)
        defer { Task { await sink.close() } }

        await sink.write(frame: MediaFrame(kind: .videoNAL, gopID: 1, frameIndex: 1, payload: Data("plain".utf8)))

        let sent = try XCTUnwrap(capture.frames.first)
        let media = try XCTUnwrap(sent.media)
        XCTAssertNil(media.sealedFramePosition, "legacy lane must not advertise a seal position")

        // The encoded frame is directly decodable — no seal envelope.
        let encoded = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(media.encodedFrameBase64)))
        let decoded = try MediaPacketCodec(maxPayloadBytes: MediaFrameV2Codec.defaultMaxPayloadBytes).decode(encoded)
        XCTAssertEqual(decoded.frame.payload, Data("plain".utf8))
    }
}
#endif

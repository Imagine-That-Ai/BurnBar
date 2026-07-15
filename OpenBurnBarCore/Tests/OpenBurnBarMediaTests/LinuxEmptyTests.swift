import Foundation
import XCTest

import OpenBurnBarCore
@testable import OpenBurnBarMedia

/// Linux coverage for the platform-neutral Mercury media contract.
///
/// The other media test files exercise the same APIs on Apple hosts, but the
/// Linux SwiftPM graph historically removed this target and left only a
/// compile-only placeholder. Keep these checks in one source file so Linux
/// can opt into the target without pulling in Apple-only VideoToolbox and
/// CryptoKit fixtures.
final class LinuxMediaContractTests: XCTestCase {
    func testPacketCodecRoundTripPreservesCursorAndReportsConsumedPrefix() throws {
        let frame = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe, .hasCursorMetadata],
            gopID: 0x0102_0304,
            frameIndex: 7,
            presentationTimestampMillis: 1_700_000_123,
            cursor: MediaFrame.CursorMetadata(x: -321, y: 654),
            payload: Data([0x00, 0x01, 0x02, 0xFE, 0xFF])
        )
        let codec = MediaPacketCodec()
        let encoded = try codec.encode(frame)

        var streamBytes = encoded
        streamBytes.append(contentsOf: [0xA5, 0x5A])
        let decoded = try codec.decode(streamBytes)

        XCTAssertEqual(decoded.frame, frame)
        XCTAssertEqual(decoded.consumed, encoded.count)
        XCTAssertEqual(streamBytes.dropFirst(decoded.consumed), Data([0xA5, 0x5A]))
    }

    func testPacketCodecRejectsLengthsBelowFixedHeaderBeforeIndexing() throws {
        let codec = MediaPacketCodec(maxPayloadBytes: 128)

        // Keep enough bytes in the input to pass the initial envelope guard,
        // but advertise an impossible payload length. This used to reach a
        // backwards range in `subdata(in:)` and trap the process.
        var malformed = Data(repeating: 0, count: 4 + MediaFrame.headerByteCount)
        malformed.replaceSubrange(0..<4, with: [0, 0, 0, 0])

        XCTAssertThrowsError(try codec.decode(malformed)) { error in
            XCTAssertEqual(error as? MediaPacketCodec.CodecError, .headerTruncated)
        }
    }

    func testPacketCodecRejectsOversizedAndTruncatedFramesWithinBoundedWork() {
        let codec = MediaPacketCodec(maxPayloadBytes: 128)

        var oversized = Data(repeating: 0, count: 4 + MediaFrame.headerByteCount)
        oversized.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try codec.decode(oversized)) { error in
            guard case let .payloadTooLarge(actual, max) = error as? MediaPacketCodec.CodecError else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
            XCTAssertEqual(actual, Int(UInt32.max))
            XCTAssertEqual(max, 128)
        }

        var truncated = Data(repeating: 0, count: 4 + MediaFrame.headerByteCount)
        truncated.replaceSubrange(0..<4, with: [0, 0, 0, 64])
        truncated[4] = MediaFrame.Kind.videoNAL.rawValue
        XCTAssertThrowsError(try codec.decode(truncated)) { error in
            XCTAssertEqual(error as? MediaPacketCodec.CodecError, .headerTruncated)
        }
    }

    func testFrameAEADRoundTripAndPositionBinding() throws {
        let aead = MediaFrameAEAD()
        let key = aead.deriveSessionKey(
            sharedSecret: Data(repeating: 0xAB, count: 32),
            salt: Data("linux-media-session".utf8)
        )
        let plaintext = Data("encoded-linux-frame".utf8)
        let sealed = try aead.seal(
            plaintext: plaintext,
            key: key,
            streamClass: MediaStreamClass.screenVideo.rawValue,
            kind: MediaFrame.Kind.videoNAL.rawValue,
            gopID: 11,
            frameIndex: 3
        )

        XCTAssertTrue(MediaFrameAEAD.isSealedEnvelope(sealed))
        XCTAssertEqual(
            try aead.open(
                envelope: sealed,
                key: key,
                streamClass: MediaStreamClass.screenVideo.rawValue,
                kind: MediaFrame.Kind.videoNAL.rawValue,
                gopID: 11,
                frameIndex: 3
            ),
            plaintext
        )
        XCTAssertThrowsError(try aead.open(
            envelope: sealed,
            key: key,
            streamClass: MediaStreamClass.screenVideo.rawValue,
            kind: MediaFrame.Kind.videoNAL.rawValue,
            gopID: 11,
            frameIndex: 4
        )) { error in
            XCTAssertEqual(error as? MediaFrameAEAD.SealError, .openFailed)
        }

        var wrongMagic = sealed
        wrongMagic[wrongMagic.startIndex] ^= 0x01
        XCTAssertThrowsError(try aead.open(
            envelope: wrongMagic,
            key: key,
            streamClass: MediaStreamClass.screenVideo.rawValue,
            kind: MediaFrame.Kind.videoNAL.rawValue,
            gopID: 11,
            frameIndex: 3
        )) { error in
            XCTAssertEqual(error as? MediaFrameAEAD.SealError, .invalidMagic)
        }
    }

    func testCapabilityAndDegradedStatesAreExplicit() async throws {
        let gate = AlwaysAllowMediaCapabilityGate()
        let check = await gate.check(
            feature: .screenShare,
            sessionDurationLimitSeconds: 900,
            sessionByteBudget: 1_000_000
        )
        guard case let .allowed(envelope) = check else {
            return XCTFail("the platform-neutral test gate should allow the request")
        }
        XCTAssertTrue(check.isAllowed)
        XCTAssertEqual(envelope.feature, .screenShare)

        let noCodec = MercuryStreamingCapabilitySnapshot(codecCapabilities: [], source: "linux-test")
        let noRoute = MercuryCodecRouter.route(
            local: noCodec,
            remote: noCodec,
            timestampMillis: 42
        )
        XCTAssertEqual(noRoute.status, .noCompatibleCodec)
        XCTAssertNil(noRoute.codec)
        XCTAssertEqual(noRoute.wireVersion, .v1)
        XCTAssertNil(noRoute.datagramPayloadBudgetBytes)
        XCTAssertEqual(noRoute.stats.timestampMillis, 42)
    }

    func testAeadNegotiationFailsClosedExceptForScreenCompatibilityDegradation() {
        XCTAssertEqual(
            MediaFrameAeadNegotiation.resolveSealingDecision(
                streamClass: .screenVideo,
                localSupports: true,
                remoteSupports: false,
                sessionKeyAvailable: true
            ),
            .allowUnsealed
        )
        XCTAssertEqual(
            MediaFrameAeadNegotiation.resolveSealingDecision(
                streamClass: .audioOut,
                localSupports: true,
                remoteSupports: false,
                sessionKeyAvailable: true
            ),
            .refuseLane(reason: .remoteDoesNotSupportSealing)
        )
        XCTAssertEqual(
            MediaFrameAeadNegotiation.resolveSealingDecision(
                streamClass: .videoOut,
                localSupports: true,
                remoteSupports: true,
                sessionKeyAvailable: false
            ),
            .refuseLane(reason: .sessionKeyUnavailable)
        )
        XCTAssertEqual(
            MediaFrameAeadNegotiation.resolveSealingDecision(
                streamClass: .videoOut,
                localSupports: true,
                remoteSupports: true,
                sessionKeyAvailable: true
            ),
            .seal
        )
    }

    func testDatagramCapabilityDegradesToReliableDeliveryWhenUnsupported() {
        let frame = MediaFrame(kind: .videoNAL, payload: Data(repeating: 0x11, count: 32))
        let unavailable = MercuryVideoDatagramScheduler.schedule(
            frame: frame,
            datagramsEnabled: true,
            remoteCapability: MercuryDatagramCapability(maxPayloadBytes: nil)
        )
        XCTAssertEqual(unavailable.delivery, .reliableStream)
        XCTAssertNil(unavailable.payloadBudgetBytes)

        let tooSmall = MercuryVideoDatagramScheduler.schedule(
            frame: frame,
            datagramsEnabled: true,
            remoteCapability: MercuryDatagramCapability(maxPayloadBytes: 64)
        )
        XCTAssertEqual(tooSmall.delivery, .reliableStream)
        XCTAssertNil(tooSmall.payloadBudgetBytes)
    }

    func testMediaSealSessionBindsViewerAndDerivesCompatibleFrameKeys() throws {
        let macKey = HermesRelayCrypto.generatePrivateKey()
        let phoneKey = HermesRelayCrypto.generatePrivateKey()
        let (envelope, phoneSideKey) = try MediaFrameSealSession.establish(
            uid: "linux-user",
            connectionID: "linux-connection",
            viewerId: "linux-viewer",
            senderDeviceID: "linux-phone",
            senderPeerNodeID: "linux-phone-node",
            senderKeyID: "relay-v3-linux",
            senderCounter: 1,
            recipientPublicKeyBase64: macKey.publicKeyBase64,
            senderPrivateKey: phoneKey
        )
        let macSideKey = try MediaFrameSealSession.open(
            envelope: envelope,
            uid: "linux-user",
            connectionID: "linux-connection",
            viewerId: "linux-viewer",
            recipientPrivateKey: macKey,
            pinnedSenderPublicKeyBase64: phoneKey.publicKeyBase64
        )

        let aead = MediaFrameAEAD()
        let sealed = try aead.seal(
            plaintext: Data("session-bound-frame".utf8),
            key: macSideKey,
            streamClass: MediaStreamClass.screenVideo.rawValue,
            kind: MediaFrame.Kind.videoNAL.rawValue,
            gopID: 1,
            frameIndex: 1
        )
        XCTAssertEqual(
            try aead.open(
                envelope: sealed,
                key: phoneSideKey,
                streamClass: MediaStreamClass.screenVideo.rawValue,
                kind: MediaFrame.Kind.videoNAL.rawValue,
                gopID: 1,
                frameIndex: 1
            ),
            Data("session-bound-frame".utf8)
        )
        XCTAssertThrowsError(try MediaFrameSealSession.open(
            envelope: envelope,
            uid: "linux-user",
            connectionID: "linux-connection",
            viewerId: "other-viewer",
            recipientPrivateKey: macKey,
            pinnedSenderPublicKeyBase64: phoneKey.publicKeyBase64
        ))
    }
}

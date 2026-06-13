import XCTest
import CryptoKit
@testable import OpenBurnBarMedia

/// F7 — per-frame media AEAD.
final class MediaFrameAEADTests: XCTestCase {
    private let aead = MediaFrameAEAD()

    private func key() -> SymmetricKey {
        aead.deriveSessionKey(sharedSecret: Data(repeating: 0xAB, count: 32), salt: Data("session-7".utf8))
    }

    func testRoundTripOpensToOriginalPlaintext() throws {
        let k = key()
        let plaintext = Data("an encoded H.264 NAL frame".utf8)
        let sealed = try aead.seal(plaintext: plaintext, key: k, streamClass: "media.screen.video", kind: 0x01, gopID: 4, frameIndex: 9)
        XCTAssertTrue(MediaFrameAEAD.isSealedEnvelope(sealed))
        XCTAssertFalse(sealed.contains(Data("encoded H.264".utf8)), "frame bytes must not appear in cleartext")
        let opened = try aead.open(envelope: sealed, key: k, streamClass: "media.screen.video", kind: 0x01, gopID: 4, frameIndex: 9)
        XCTAssertEqual(opened, plaintext)
    }

    func testSlicedEnvelopeWithNonZeroStartIndexOpens() throws {
        // The open path deliberately avoids a defensive whole-envelope copy
        // (a per-frame cost at 30-60fps), so it must handle Data SLICES whose
        // startIndex is non-zero — the shape a framing/transport layer hands us.
        let k = key()
        let plaintext = Data("an encoded H.264 NAL frame".utf8)
        let sealed = try aead.seal(plaintext: plaintext, key: k, streamClass: "media.screen.video", kind: 0x01, gopID: 4, frameIndex: 9)
        var framed = Data("12-byte-pad!".utf8)
        framed.append(sealed)
        let slice = framed.suffix(from: framed.startIndex + 12)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertTrue(MediaFrameAEAD.isSealedEnvelope(slice))
        let opened = try aead.open(envelope: slice, key: k, streamClass: "media.screen.video", kind: 0x01, gopID: 4, frameIndex: 9)
        XCTAssertEqual(opened, plaintext)
    }

    func testTamperedFrameIndexFailsToOpen() throws {
        let k = key()
        let sealed = try aead.seal(plaintext: Data("frame".utf8), key: k, streamClass: "media.screen.video", kind: 0x01, gopID: 4, frameIndex: 9)
        // A frame replayed in a different position must not open (AAD binds index).
        XCTAssertThrowsError(try aead.open(envelope: sealed, key: k, streamClass: "media.screen.video", kind: 0x01, gopID: 4, frameIndex: 10))
    }

    func testTamperedStreamClassFailsToOpen() throws {
        let k = key()
        let sealed = try aead.seal(plaintext: Data("frame".utf8), key: k, streamClass: "media.screen.video", kind: 0x01, gopID: 0, frameIndex: 0)
        XCTAssertThrowsError(try aead.open(envelope: sealed, key: k, streamClass: "control.surface.frame", kind: 0x01, gopID: 0, frameIndex: 0))
    }

    func testWrongKeyFailsToOpen() throws {
        let sealed = try aead.seal(plaintext: Data("frame".utf8), key: key(), streamClass: "media.screen.video", kind: 0x01, gopID: 0, frameIndex: 0)
        let other = aead.deriveSessionKey(sharedSecret: Data(repeating: 0x01, count: 32), salt: Data("session-7".utf8))
        XCTAssertThrowsError(try aead.open(envelope: sealed, key: other, streamClass: "media.screen.video", kind: 0x01, gopID: 0, frameIndex: 0))
    }

    func testCiphertextTamperFailsToOpen() throws {
        let k = key()
        var sealed = try aead.seal(plaintext: Data("frame-payload".utf8), key: k, streamClass: "media.screen.video", kind: 0x01, gopID: 0, frameIndex: 0)
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try aead.open(envelope: sealed, key: k, streamClass: "media.screen.video", kind: 0x01, gopID: 0, frameIndex: 0))
    }

    func testDerivedKeyIsDeterministicAndSaltSeparated() {
        let a = aead.deriveSessionKey(sharedSecret: Data(repeating: 7, count: 32), salt: Data("s1".utf8))
        let b = aead.deriveSessionKey(sharedSecret: Data(repeating: 7, count: 32), salt: Data("s1".utf8))
        let c = aead.deriveSessionKey(sharedSecret: Data(repeating: 7, count: 32), salt: Data("s2".utf8))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testIsSealedEnvelopeRejectsNonSealed() {
        XCTAssertFalse(MediaFrameAEAD.isSealedEnvelope(Data("plain".utf8)))
        XCTAssertFalse(MediaFrameAEAD.isSealedEnvelope(Data()))
    }

    func testNegotiationRequiresBothPeers() {
        XCTAssertTrue(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports: true, remoteSupports: true))
        XCTAssertFalse(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports: true, remoteSupports: false))
        XCTAssertFalse(MediaFrameAeadNegotiation.resolveSealingEnabled(localSupports: false, remoteSupports: true))
        XCTAssertEqual(MediaFrameAeadNegotiation.capability, "media_frame_aead_v1")
    }

    // MARK: RR-9 — F7 negotiation fail-closed for non-screen lanes

    func testSealingExpectedForAudioCameraAndFileLanes() {
        XCTAssertTrue(MediaFrameAeadNegotiation.sealingExpected(for: .audioOut))
        XCTAssertTrue(MediaFrameAeadNegotiation.sealingExpected(for: .audioIn))
        XCTAssertTrue(MediaFrameAeadNegotiation.sealingExpected(for: .videoOut))
        XCTAssertTrue(MediaFrameAeadNegotiation.sealingExpected(for: .videoIn))
        XCTAssertTrue(MediaFrameAeadNegotiation.sealingExpected(for: .blobAdvertise))
        XCTAssertTrue(MediaFrameAeadNegotiation.sealingExpected(for: .blobFetch))
    }

    func testSealingNotExpectedForScreenAndAgentWatchLanes() {
        // Screen-video / agent-watch keep interoperating with pre-F7 viewers.
        XCTAssertFalse(MediaFrameAeadNegotiation.sealingExpected(for: .screenVideo))
        XCTAssertFalse(MediaFrameAeadNegotiation.sealingExpected(for: .controlSurfaceFrame))
        // Pure control / classify carry no payload.
        XCTAssertFalse(MediaFrameAeadNegotiation.sealingExpected(for: .control))
        XCTAssertFalse(MediaFrameAeadNegotiation.sealingExpected(for: .classify))
    }

    func testNonScreenLaneRefusesWhenRemotePeerCannotSeal() {
        let decision = MediaFrameAeadNegotiation.resolveSealingDecision(
            streamClass: .audioOut,
            localSupports: true,
            remoteSupports: false,
            sessionKeyAvailable: true
        )
        XCTAssertEqual(decision, .refuseLane(reason: .remoteDoesNotSupportSealing))
        XCTAssertTrue(decision.isRefusal)
    }

    func testNonScreenLaneRefusesWhenSessionKeyMissing() {
        let decision = MediaFrameAeadNegotiation.resolveSealingDecision(
            streamClass: .blobFetch,
            localSupports: true,
            remoteSupports: true,
            sessionKeyAvailable: false
        )
        XCTAssertEqual(decision, .refuseLane(reason: .sessionKeyUnavailable))
    }

    func testNonScreenLaneSealsWhenBothSupportAndKeyPresent() {
        let decision = MediaFrameAeadNegotiation.resolveSealingDecision(
            streamClass: .videoOut,
            localSupports: true,
            remoteSupports: true,
            sessionKeyAvailable: true
        )
        XCTAssertEqual(decision, .seal)
    }

    func testScreenLaneDegradesToUnsealedInsteadOfRefusing() {
        // Screen-video stays soft: a pre-F7 viewer keeps getting frames over the
        // iroh transport seal rather than having the lane refused.
        let degraded = MediaFrameAeadNegotiation.resolveSealingDecision(
            streamClass: .screenVideo,
            localSupports: true,
            remoteSupports: false,
            sessionKeyAvailable: true
        )
        XCTAssertEqual(degraded, .allowUnsealed)
        XCTAssertFalse(degraded.isRefusal)

        let sealed = MediaFrameAeadNegotiation.resolveSealingDecision(
            streamClass: .screenVideo,
            localSupports: true,
            remoteSupports: true,
            sessionKeyAvailable: true
        )
        XCTAssertEqual(sealed, .seal)
    }
}

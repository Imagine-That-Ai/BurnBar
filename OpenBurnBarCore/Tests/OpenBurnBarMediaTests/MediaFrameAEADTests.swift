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
}

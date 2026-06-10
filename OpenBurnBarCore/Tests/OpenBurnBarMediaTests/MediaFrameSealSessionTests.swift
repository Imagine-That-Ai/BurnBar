import XCTest
import CryptoKit
import OpenBurnBarCore
@testable import OpenBurnBarMedia

/// F7 — media-seal session lifecycle (establish → open → frame seal round trip).
final class MediaFrameSealSessionTests: XCTestCase {
    private let uid = "uid-f7"
    private let connectionID = "conn-f7"
    private let viewerId = "viewer-f7"

    func testEstablishOpenDeriveSameFrameKey() throws {
        let macKey = HermesRelayCrypto.generatePrivateKey()
        let phoneKey = HermesRelayCrypto.generatePrivateKey()
        let (envelope, phoneSide) = try MediaFrameSealSession.establish(
            uid: uid,
            connectionID: connectionID,
            viewerId: viewerId,
            senderDeviceID: "iphone-f7",
            senderPeerNodeID: "iphone-f7",
            senderKeyID: "relay-v3-f7",
            senderCounter: 5,
            recipientPublicKeyBase64: macKey.publicKeyBase64,
            senderPrivateKey: phoneKey
        )
        let macSide = try MediaFrameSealSession.open(
            envelope: envelope,
            uid: uid,
            connectionID: connectionID,
            viewerId: viewerId,
            recipientPrivateKey: macKey,
            pinnedSenderPublicKeyBase64: phoneKey.publicKeyBase64
        )

        // The derived keys agree: a Mac-sealed frame opens on the phone with
        // full position binding intact.
        let aead = MediaFrameAEAD()
        let plaintext = Data("encoded video frame bytes".utf8)
        let sealed = try aead.seal(
            plaintext: plaintext,
            key: macSide,
            streamClass: "media.screen.video",
            kind: 1,
            gopID: 7,
            frameIndex: 42
        )
        XCTAssertTrue(MediaFrameAEAD.isSealedEnvelope(sealed))
        let opened = try aead.open(
            envelope: sealed,
            key: phoneSide,
            streamClass: "media.screen.video",
            kind: 1,
            gopID: 7,
            frameIndex: 42
        )
        XCTAssertEqual(opened, plaintext)
        // Position binding still enforced under the session key.
        XCTAssertThrowsError(try aead.open(
            envelope: sealed,
            key: phoneSide,
            streamClass: "media.screen.video",
            kind: 1,
            gopID: 7,
            frameIndex: 43
        ))
    }

    func testOpenWithWrongPinnedSenderOrViewerFailsClosed() throws {
        let macKey = HermesRelayCrypto.generatePrivateKey()
        let phoneKey = HermesRelayCrypto.generatePrivateKey()
        let attacker = HermesRelayCrypto.generatePrivateKey()
        let (envelope, _) = try MediaFrameSealSession.establish(
            uid: uid,
            connectionID: connectionID,
            viewerId: viewerId,
            senderDeviceID: "iphone-f7",
            senderPeerNodeID: "iphone-f7",
            senderKeyID: "relay-v3-f7",
            senderCounter: 1,
            recipientPublicKeyBase64: macKey.publicKeyBase64,
            senderPrivateKey: phoneKey
        )
        XCTAssertThrowsError(try MediaFrameSealSession.open(
            envelope: envelope,
            uid: uid,
            connectionID: connectionID,
            viewerId: viewerId,
            recipientPrivateKey: macKey,
            pinnedSenderPublicKeyBase64: attacker.publicKeyBase64
        ))
        // A wrap minted for one viewer cannot key a different viewer's mirror.
        XCTAssertThrowsError(try MediaFrameSealSession.open(
            envelope: envelope,
            uid: uid,
            connectionID: connectionID,
            viewerId: "viewer-other",
            recipientPrivateKey: macKey,
            pinnedSenderPublicKeyBase64: phoneKey.publicKeyBase64
        ))
    }

    /// Cross-lane separation: an F10 control-seal wrap cannot be opened as a
    /// media-seal wrap even with identical identities (distinct AAD domains).
    func testControlSealWrapDoesNotOpenAsMediaSealWrap() throws {
        let macKey = HermesRelayCrypto.generatePrivateKey()
        let phoneKey = HermesRelayCrypto.generatePrivateKey()
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let controlWrap = try HermesRelayCrypto.sealKeyV3(
            keyData,
            recipientPublicKeyBase64: macKey.publicKeyBase64,
            senderPrivateKey: phoneKey,
            aad: HermesRelayCrypto.controlSealKeyAAD(
                uid: uid,
                connectionID: connectionID,
                peerNodeId: viewerId,
                senderDeviceID: "iphone-f7",
                senderKeyID: "relay-v3-f7",
                senderCounter: 1
            )
        )
        let envelope = HermesRealtimeRelayControlSealKeyEnvelope(
            encBase64: controlWrap.enc.base64EncodedString(),
            wrappedKeyBase64: controlWrap.wrappedKey.base64EncodedString(),
            senderDeviceId: "iphone-f7",
            senderPeerNodeId: "iphone-f7",
            senderKeyId: "relay-v3-f7",
            senderCounter: 1,
            relayKeyVersion: HermesRelayCrypto.gatewayRelayKeyVersionV3
        )
        XCTAssertThrowsError(try MediaFrameSealSession.open(
            envelope: envelope,
            uid: uid,
            connectionID: connectionID,
            viewerId: viewerId,
            recipientPrivateKey: macKey,
            pinnedSenderPublicKeyBase64: phoneKey.publicKeyBase64
        ))
    }

    /// Pre-F7 wire safety: a mirror request without the new field encodes to
    /// JSON without it, and legacy JSON still decodes.
    func testLegacyMirrorRequestEncodingGainsNoNewKeys() throws {
        let legacy = HermesRealtimeRelayMirrorRequest(
            requestId: "req-legacy",
            requestedAt: Date(),
            requesterDisplayName: "Alberto's iPhone",
            streamClass: "media.screen.video"
        )
        let json = String(data: try JSONEncoder().encode(legacy), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("mediaSealKey"))
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayMirrorRequest.self,
            from: Data(#"{"requestId":"r","requestedAt":"2026-06-10T00:00:00.000Z","requesterDisplayName":"d","streamClass":"media.screen.video"}"#.utf8)
        )
        XCTAssertNil(decoded.mediaSealKey)
    }
}

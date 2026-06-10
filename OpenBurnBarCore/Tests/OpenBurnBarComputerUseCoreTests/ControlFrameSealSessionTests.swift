import XCTest
import CryptoKit
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore

/// F10 — control-seal session lifecycle (establish → open → seal → unseal).
final class ControlFrameSealSessionTests: XCTestCase {
    private let uid = "uid-f10"
    private let connectionID = "conn-f10"
    private let peerNodeId = "ios-phone-aabbccddeeff001122334455"

    private func establishBothSides() throws -> (phone: SymmetricKey, mac: SymmetricKey, envelope: HermesRealtimeRelayControlSealKeyEnvelope) {
        let macKey = HermesRelayCrypto.generatePrivateKey()
        let phoneKey = HermesRelayCrypto.generatePrivateKey()
        let (envelope, phoneSide) = try ControlFrameSealSession.establish(
            uid: uid,
            connectionID: connectionID,
            peerNodeId: peerNodeId,
            senderDeviceID: "iphone-1",
            senderPeerNodeID: "iphone-1",
            senderKeyID: "relay-v3-abc",
            senderCounter: 7,
            recipientPublicKeyBase64: macKey.publicKeyBase64,
            senderPrivateKey: phoneKey
        )
        let macSide = try ControlFrameSealSession.open(
            envelope: envelope,
            uid: uid,
            connectionID: connectionID,
            peerNodeId: peerNodeId,
            recipientPrivateKey: macKey,
            pinnedSenderPublicKeyBase64: phoneKey.publicKeyBase64
        )
        return (phoneSide, macSide, envelope)
    }

    func testEstablishOpenDeriveSameKeyAndSealRoundTrips() throws {
        let session = try establishBothSides()

        let inner = HermesRealtimeRelayControlPayload(
            streamClass: "control.clipboard",
            clipboardRequest: HermesRealtimeRelayClipboardRequest(
                requestId: "req-1",
                action: .pasteToMac,
                contentType: "text/plain",
                text: "the secret clipboard text",
                maxBytes: 65_536,
                clientIntentId: "intent-1",
                authority: HermesRealtimeRelayAuthorityEnvelope(
                    peerNodeId: peerNodeId,
                    counter: 9,
                    timestamp: Date(),
                    intentHashBlake3: String(repeating: "ab", count: 32),
                    signatureEd25519: Data(repeating: 1, count: 64).base64EncodedString()
                )
            )
        )
        let shell = try ControlFrameSealSession.sealPayload(
            inner,
            key: session.phone,
            peerNodeId: peerNodeId,
            frameType: "control.clipboard.request"
        )
        // The shell leaks routing only.
        XCTAssertEqual(shell.streamClass, "control.clipboard")
        XCTAssertNil(shell.clipboardRequest)
        XCTAssertNotNil(shell.sealedFrameBase64)
        XCTAssertFalse(shell.sealedFrameBase64!.contains("secret"))

        let opened = try ControlFrameSealSession.openPayload(
            shell,
            key: session.mac,
            peerNodeId: peerNodeId,
            frameType: "control.clipboard.request"
        )
        XCTAssertEqual(opened.clipboardRequest?.text, "the secret clipboard text")
        XCTAssertEqual(opened.clipboardRequest?.authority.counter, 9)
    }

    func testOpenWithWrongPinnedSenderFailsClosed() throws {
        let macKey = HermesRelayCrypto.generatePrivateKey()
        let phoneKey = HermesRelayCrypto.generatePrivateKey()
        let attacker = HermesRelayCrypto.generatePrivateKey()
        let (envelope, _) = try ControlFrameSealSession.establish(
            uid: uid,
            connectionID: connectionID,
            peerNodeId: peerNodeId,
            senderDeviceID: "iphone-1",
            senderPeerNodeID: "iphone-1",
            senderKeyID: "relay-v3-abc",
            senderCounter: 1,
            recipientPublicKeyBase64: macKey.publicKeyBase64,
            senderPrivateKey: phoneKey
        )
        XCTAssertThrowsError(try ControlFrameSealSession.open(
            envelope: envelope,
            uid: uid,
            connectionID: connectionID,
            peerNodeId: peerNodeId,
            recipientPrivateKey: macKey,
            pinnedSenderPublicKeyBase64: attacker.publicKeyBase64
        ))
    }

    func testOpenWithMismatchedAADContextFailsClosed() throws {
        let macKey = HermesRelayCrypto.generatePrivateKey()
        let phoneKey = HermesRelayCrypto.generatePrivateKey()
        let (envelope, _) = try ControlFrameSealSession.establish(
            uid: uid,
            connectionID: connectionID,
            peerNodeId: peerNodeId,
            senderDeviceID: "iphone-1",
            senderPeerNodeID: "iphone-1",
            senderKeyID: "relay-v3-abc",
            senderCounter: 1,
            recipientPublicKeyBase64: macKey.publicKeyBase64,
            senderPrivateKey: phoneKey
        )
        // Different controller identity ⇒ different AAD ⇒ refuse.
        XCTAssertThrowsError(try ControlFrameSealSession.open(
            envelope: envelope,
            uid: uid,
            connectionID: connectionID,
            peerNodeId: "android-phone-attacker000000000000000000",
            recipientPrivateKey: macKey,
            pinnedSenderPublicKeyBase64: phoneKey.publicKeyBase64
        ))
    }

    func testSealedShellCannotBeRetypedOrCrossPeer() throws {
        let session = try establishBothSides()
        let inner = HermesRealtimeRelayControlPayload(streamClass: "control.input")
        let shell = try ControlFrameSealSession.sealPayload(
            inner,
            key: session.phone,
            peerNodeId: peerNodeId,
            frameType: "control.input.intent"
        )
        XCTAssertThrowsError(try ControlFrameSealSession.openPayload(
            shell,
            key: session.mac,
            peerNodeId: peerNodeId,
            frameType: "control.clipboard.request"
        ))
        XCTAssertThrowsError(try ControlFrameSealSession.openPayload(
            shell,
            key: session.mac,
            peerNodeId: "ios-phone-someoneelse0000000000000000",
            frameType: "control.input.intent"
        ))
    }

    /// Pre-F10 wire safety: a payload built without the new fields encodes to
    /// JSON containing neither new key, so pre-F10 peers see today's bytes.
    func testLegacyPayloadEncodingGainsNoNewKeys() throws {
        let legacy = HermesRealtimeRelayControlPayload(
            streamClass: "control.input",
            authorityPeerNodeId: peerNodeId
        )
        let json = String(data: try JSONEncoder().encode(legacy), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("controlSealKey"))
        XCTAssertFalse(json.contains("sealedFrameBase64"))
        // And a legacy JSON document (no new fields) still decodes.
        let decoded = try JSONDecoder().decode(
            HermesRealtimeRelayControlPayload.self,
            from: Data(#"{"streamClass":"control.input","authorityPeerNodeId":"x"}"#.utf8)
        )
        XCTAssertNil(decoded.controlSealKey)
        XCTAssertNil(decoded.sealedFrameBase64)
    }
}

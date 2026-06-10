import Foundation
import CryptoKit
import OpenBurnBarCore

/// F7 — media-seal session lifecycle, the F10 control-seal pattern applied to
/// the media lane:
///
///  1. The phone generates a fresh 32-byte session secret when it builds its
///     mirror request and wraps it with `HermesRelayCrypto.sealKeyV3`
///     (RFC 9180 Auth-mode P-256 to the Mac's pinned relay key,
///     sender-authenticated by the phone's relay sender key) under
///     `mediaSealKeyAAD`, bound to the mirror `viewerId`. The wrap rides
///     `HermesRealtimeRelayMirrorRequest.mediaSealKey`.
///  2. The Mac opens it through the SAME pinned relay-sender trust path as the
///     chat opener and both sides derive the AES-256-GCM frame key with
///     `MediaFrameAEAD.deriveSessionKey`, salted by the connection id.
///  3. The Mac seals every encoded media frame (`MediaFrameAEAD`, OBMFA1,
///     position-bound AAD) before chunking; the phone opens after reassembly.
public enum MediaFrameSealSession {
    /// Phone side: wrap a fresh session secret for the Mac and derive the
    /// local frame key.
    public static func establish(
        uid: String,
        connectionID: String,
        viewerId: String,
        senderDeviceID: String,
        senderPeerNodeID: String,
        senderKeyID: String,
        senderCounter: Int64,
        recipientPublicKeyBase64: String,
        senderPrivateKey: HermesRelayPrivateKey
    ) throws -> (envelope: HermesRealtimeRelayControlSealKeyEnvelope, key: SymmetricKey) {
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let wrap = try HermesRelayCrypto.sealKeyV3(
            keyData,
            recipientPublicKeyBase64: recipientPublicKeyBase64,
            senderPrivateKey: senderPrivateKey,
            aad: HermesRelayCrypto.mediaSealKeyAAD(
                uid: uid,
                connectionID: connectionID,
                viewerId: viewerId,
                senderDeviceID: senderDeviceID,
                senderKeyID: senderKeyID,
                senderCounter: senderCounter
            )
        )
        let envelope = HermesRealtimeRelayControlSealKeyEnvelope(
            encBase64: wrap.enc.base64EncodedString(),
            wrappedKeyBase64: wrap.wrappedKey.base64EncodedString(),
            senderDeviceId: senderDeviceID,
            senderPeerNodeId: senderPeerNodeID,
            senderKeyId: senderKeyID,
            senderCounter: senderCounter,
            relayKeyVersion: HermesRelayCrypto.gatewayRelayKeyVersionV3
        )
        return (envelope, deriveKey(sessionSecret: keyData, connectionID: connectionID))
    }

    /// Mac side: open the wrapped session secret. `pinnedSenderPublicKeyBase64`
    /// MUST come from the pinned relay-sender-key source — never the frame.
    public static func open(
        envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        uid: String,
        connectionID: String,
        viewerId: String,
        recipientPrivateKey: HermesRelayPrivateKey,
        pinnedSenderPublicKeyBase64: String
    ) throws -> SymmetricKey {
        guard let enc = Data(base64Encoded: envelope.encBase64),
              let wrappedKey = Data(base64Encoded: envelope.wrappedKeyBase64) else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        let keyData = try HermesRelayCrypto.openKeyV3(
            enc: enc,
            wrappedKey: wrappedKey,
            privateKey: recipientPrivateKey,
            pinnedSenderPublicKeyBase64: pinnedSenderPublicKeyBase64,
            aad: HermesRelayCrypto.mediaSealKeyAAD(
                uid: uid,
                connectionID: connectionID,
                viewerId: viewerId,
                senderDeviceID: envelope.senderDeviceId,
                senderKeyID: envelope.senderKeyId,
                senderCounter: envelope.senderCounter
            )
        )
        return deriveKey(sessionSecret: keyData, connectionID: connectionID)
    }

    private static func deriveKey(sessionSecret: Data, connectionID: String) -> SymmetricKey {
        MediaFrameAEAD().deriveSessionKey(
            sharedSecret: sessionSecret,
            salt: Data(connectionID.utf8)
        )
    }
}

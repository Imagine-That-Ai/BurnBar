import Foundation
import CryptoKit
import OpenBurnBarCore

/// F10 — one shared implementation of the control-seal session lifecycle so
/// the phone (establish + seal) and the Mac (open + unseal) cannot drift:
///
///  1. At `control.classify` time the phone generates a fresh 32-byte session
///     secret and wraps it with the tested relay primitive
///     (`HermesRelayCrypto.sealKeyV3` — RFC 9180 Auth-mode P-256 to the Mac's
///     pinned relay key, sender-authenticated by the phone's relay sender
///     key) under `controlSealKeyAAD`. The wrap rides the classify frame as
///     `HermesRealtimeRelayControlSealKeyEnvelope`.
///  2. Both sides derive the AES-256-GCM seal key with
///     `ControlFrameSeal.deriveSessionKey(hpkeSessionKey:salt:)`, salted by
///     the connection id.
///  3. Every subsequent control payload is replaced by a routing shell
///     (`streamClass` only) carrying `sealedFrameBase64` — a `ControlFrameSeal`
///     envelope over the inner payload JSON, AAD-bound to (controller
///     peerNodeId, frame type).
public enum ControlFrameSealSession {
    public enum SessionError: Error, Equatable, Sendable {
        case sealedPayloadMissing
        case innerPayloadUndecodable
    }

    /// Phone side: wrap a fresh session secret for the Mac and derive the
    /// local seal key. `recipientPublicKeyBase64` is the Mac relay key the
    /// phone already pins/verifies; `senderPrivateKey` is the phone's relay
    /// sender key (the same identity the chat lane authenticates with).
    public static func establish(
        uid: String,
        connectionID: String,
        peerNodeId: String,
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
            aad: HermesRelayCrypto.controlSealKeyAAD(
                uid: uid,
                connectionID: connectionID,
                peerNodeId: peerNodeId,
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
    /// MUST come from the same pinned relay-sender-key source the chat opener
    /// uses — never from the frame itself.
    public static func open(
        envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        uid: String,
        connectionID: String,
        peerNodeId: String,
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
            aad: HermesRelayCrypto.controlSealKeyAAD(
                uid: uid,
                connectionID: connectionID,
                peerNodeId: peerNodeId,
                senderDeviceID: envelope.senderDeviceId,
                senderKeyID: envelope.senderKeyId,
                senderCounter: envelope.senderCounter
            )
        )
        return deriveKey(sessionSecret: keyData, connectionID: connectionID)
    }

    /// Replace `payload` with its sealed shell: `streamClass` stays visible for
    /// routing, everything else rides inside the OBCFS1 envelope.
    public static func sealPayload(
        _ payload: HermesRealtimeRelayControlPayload,
        key: SymmetricKey,
        peerNodeId: String,
        frameType: String
    ) throws -> HermesRealtimeRelayControlPayload {
        let plaintext = try canonicalEncoder().encode(payload)
        let sealed = try ControlFrameSeal().seal(
            plaintext: plaintext,
            key: key,
            peerNodeId: peerNodeId,
            frameType: frameType
        )
        return HermesRealtimeRelayControlPayload(
            streamClass: payload.streamClass,
            sealedFrameBase64: sealed.base64EncodedString()
        )
    }

    /// Open a sealed shell back into the inner payload. Fail-closed: any
    /// decode/AAD/tag failure throws and the frame must be dropped, never
    /// dispatched.
    public static func openPayload(
        _ payload: HermesRealtimeRelayControlPayload,
        key: SymmetricKey,
        peerNodeId: String,
        frameType: String
    ) throws -> HermesRealtimeRelayControlPayload {
        guard let sealedBase64 = payload.sealedFrameBase64,
              let sealed = Data(base64Encoded: sealedBase64) else {
            throw SessionError.sealedPayloadMissing
        }
        let plaintext = try ControlFrameSeal().open(
            envelope: sealed,
            key: key,
            peerNodeId: peerNodeId,
            frameType: frameType
        )
        do {
            return try canonicalDecoder().decode(HermesRealtimeRelayControlPayload.self, from: plaintext)
        } catch {
            throw SessionError.innerPayloadUndecodable
        }
    }

    private static func deriveKey(sessionSecret: Data, connectionID: String) -> SymmetricKey {
        ControlFrameSeal().deriveSessionKey(
            hpkeSessionKey: sessionSecret,
            salt: Data(connectionID.utf8)
        )
    }

    /// ISO8601-fractional dates to match the relay frame coding used on the
    /// wire (`HermesRealtimeRelayFrame` codecs) so inner payload timestamps
    /// survive the seal round trip byte-exactly.
    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormatter.string(from: date))
        }
        return encoder
    }

    private static func canonicalDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = Self.dateFormatter.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unparseable control-seal date: \(raw)"
                ))
            }
            return date
        }
        return decoder
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

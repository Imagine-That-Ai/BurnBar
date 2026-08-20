import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Hermes Gateway attachment records
//
// Split out of `HermesGatewayAPI.swift` (audit wave 4, item 14 structural
// decomposition). Pure move — no behavior change.

/// The opened content of an agent→phone sealed gateway attachment: the manifest
/// (filename / size / content type) plus the decrypted file bytes.
struct HermesGatewayOpenedAttachment: Hashable, Sendable {
    let attachmentId: String
    let fileName: String
    let byteCount: Int
    let contentType: String?
    let data: Data
}

/// An agent→phone sealed gateway attachment as stored in
/// `hermes_gateway_attachments`. The agent seals the file with a per-attachment
/// symmetric key wrapped to this phone's relay pubkey, stores the sealed
/// *manifest* (`{fileName, byteCount, contentType, destinationId}`) in `payloadCiphertext`, and
/// uploads the sealed *body* bytes to Cloud Storage at `bodyStoragePath`. The
/// phone unwraps the body key once and opens both the manifest and the body,
/// each bound to a distinct AAD label so a relay cannot swap one slot for the
/// other. Mirrors the Python adapter `seal_attachment` wire format.
///
/// The gateway settings store fetches only the attachment ids referenced by the
/// selected reply, downloads their sealed body blobs, calls these open
/// primitives, and renders the resulting `HermesAttachment` records through the
/// normal chat bubble strip. No bulk attachment download is needed.
struct HermesGatewayAttachmentRecord: Identifiable, Hashable, Sendable {
    let id: String
    let clientId: String
    let destinationId: String?
    let bodyStoragePath: String?
    let payloadCiphertext: String?
    let wrappedKey: String?
    let enc: String?
    let relayEncryption: String?
    let relayKeyVersion: Int?
    let ratchetEnvelopeCiphertextBase64: String?
    let ratchetEnvelopeAlgorithm: String?
    let createdAt: String?

    init?(documentID: String, data: [String: Any]) {
        guard
            let id = HermesGatewayMessageRecord.string(data["id"]) ?? HermesGatewayMessageRecord.string(data["attachmentId"]) ?? documentID.nilIfEmpty,
            let clientId = HermesGatewayMessageRecord.string(data["clientId"])
        else { return nil }
        self.id = id
        self.clientId = clientId
        self.destinationId = HermesGatewayMessageRecord.string(data["destinationId"])
        self.bodyStoragePath =
            HermesGatewayMessageRecord.string(data["bodyStoragePath"])
            ?? HermesGatewayMessageRecord.string(data["storagePath"])
        let relayEnvelope = HermesGatewayMessageRecord.dictionary(data["relayEnvelope"])
        self.payloadCiphertext =
            HermesGatewayMessageRecord.string(relayEnvelope?["payloadCiphertext"])
            ?? HermesGatewayMessageRecord.string(data["payloadCiphertext"])
        self.wrappedKey =
            HermesGatewayMessageRecord.string(relayEnvelope?["wrappedKey"])
            ?? HermesGatewayMessageRecord.string(data["wrappedKey"])
        self.enc =
            HermesGatewayMessageRecord.string(relayEnvelope?["enc"])
            ?? HermesGatewayMessageRecord.string(data["enc"])
        self.relayEncryption =
            HermesGatewayMessageRecord.string(relayEnvelope?["relayEncryption"])
            ?? HermesGatewayMessageRecord.string(data["relayEncryption"])
        self.relayKeyVersion =
            (relayEnvelope?["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (relayEnvelope?["relayKeyVersion"] as? Int)
            ?? (data["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (data["relayKeyVersion"] as? Int)
        let ratchetEnvelope = HermesGatewayMessageRecord.dictionary(data["ratchetEnvelope"])
        let ratchetHeader = HermesGatewayMessageRecord.dictionary(ratchetEnvelope?["header"])
        self.ratchetEnvelopeCiphertextBase64 = HermesGatewayMessageRecord.string(ratchetEnvelope?["ciphertextBase64"])
        self.ratchetEnvelopeAlgorithm = HermesGatewayMessageRecord.string(ratchetHeader?["algorithm"])
        self.createdAt = HermesGatewayMessageRecord.string(data["createdAt"])
    }

    /// True when this attachment carries a sealed body the phone must open with
    /// its relay key (vs. a legacy plaintext attachment).
    var isSealed: Bool {
        isRelaySealed || isRatchetSealed
    }

    private var isRelaySealed: Bool {
        (relayEncryption == HermesRelayCrypto.algorithm || relayEncryption == HermesRelayCrypto.relayEncryptionV3)
            && (payloadCiphertext?.isEmpty == false)
            && (wrappedKey?.isEmpty == false)
    }

    private var isRatchetSealed: Bool {
        ratchetEnvelopeAlgorithm == HermesRatchetCrypto.algorithm
            && (ratchetEnvelopeCiphertextBase64?.isEmpty == false)
    }

    /// Unwrap the per-attachment body key with this phone's relay key, binding
    /// the *key* AAD (`gatewayAttachmentKey`). Returns `nil` when the attachment
    /// is unsealed or the wrap was sealed for another device. This is the open
    /// primitive shared by the manifest-only and full-body paths.
    func unwrapBodyKey(using keypair: HermesGatewayRelayKeypair, uid: String, pinnedSenderKey: String?) -> Data? {
        guard isRelaySealed, let wrappedKey, let pinnedSenderKey else { return nil }
        guard let keyAAD = try? HermesRelayCrypto.gatewayAttachmentKeyAAD(
            uid: uid,
            clientId: clientId,
            attachmentId: id
        ) else { return nil }
        if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersion {
            guard relayEncryption == HermesRelayCrypto.algorithm else { return nil }
            return try? HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKey,
                privateKey: keypair.privateKey,
                aad: keyAAD,
                senderPublicKeyBase64: pinnedSenderKey
            )
        }
        if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3 {
            guard relayEncryption == HermesRelayCrypto.relayEncryptionV3,
                  let enc,
                  !enc.isEmpty else { return nil }
            return try? HermesRelayCrypto.openKeyV3(
                encBase64: enc,
                wrappedKeyBase64: wrappedKey,
                privateKey: keypair.privateKey,
                pinnedSenderPublicKeyBase64: pinnedSenderKey,
                aad: keyAAD
            )
        }
        return nil
    }

    /// Open the sealed manifest (`{fileName, byteCount, contentType, destinationId}`) with the
    /// already-unwrapped body key, binding the *manifest* AAD. Throws on a
    /// cross-slot swap (the body ciphertext fails the manifest tag) or malformed
    /// manifest JSON.
    func openManifest(bodyKey: Data, uid: String) throws -> HermesGatewayAttachmentManifest {
        guard let payloadCiphertext else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        let manifestData = try HermesRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: bodyKey,
            aad: try HermesRelayCrypto.gatewayAttachmentManifestAAD(uid: uid, clientId: clientId, attachmentId: id)
        )
        guard let manifest = HermesGatewayAttachmentManifest(jsonData: manifestData) else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        if let destinationId, !destinationId.isEmpty, manifest.destinationId != destinationId {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        return manifest
    }

    /// Open the sealed body bytes with the already-unwrapped body key, binding
    /// the *body* AAD. `downloadedBody` is the raw blob fetched from
    /// `bodyStoragePath`; the agent uploads the base64 of the sealed body, so the
    /// blob is the ASCII base64 string of the ciphertext (matching the Python
    /// `seal_attachment` wire). Throws on a wrong-device key or a tampered body.
    func openBody(downloadedBody: Data, bodyKey: Data, uid: String) throws -> Data {
        guard let ciphertextBase64 = String(data: downloadedBody, encoding: .utf8),
              !ciphertextBase64.isEmpty else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        return try HermesRelayCrypto.openBase64(
            ciphertext: ciphertextBase64,
            keyData: bodyKey,
            aad: try HermesRelayCrypto.gatewayAttachmentBodyAAD(uid: uid, clientId: clientId, attachmentId: id)
        )
    }

    /// Full open: unwrap the body key, open the manifest for the filename, and
    /// open the body bytes — returning the rendered attachment. `downloadedBody`
    /// is the blob fetched from `bodyStoragePath` by the caller (the network
    /// download is the caller's responsibility so this stays pure/testable).
    /// Returns `nil` when this device cannot open the attachment (sealed for
    /// another device), so the caller can show the same calm re-pair state as a
    /// sealed reply.
    func opened(
        downloadedBody: Data,
        using keypair: HermesGatewayRelayKeypair,
        uid: String,
        pinnedSenderKey: String?
    ) -> HermesGatewayOpenedAttachment? {
        guard let bodyKey = unwrapBodyKey(using: keypair, uid: uid, pinnedSenderKey: pinnedSenderKey) else { return nil }
        do {
            let manifest = try openManifest(bodyKey: bodyKey, uid: uid)
            let body = try openBody(downloadedBody: downloadedBody, bodyKey: bodyKey, uid: uid)
            return HermesGatewayOpenedAttachment(
                attachmentId: id,
                fileName: manifest.fileName,
                byteCount: manifest.byteCount,
                contentType: manifest.contentType,
                data: body
            )
        } catch {
            // Sealed for another device (or tampered) — nil drives the calm
            // re-pair state documented above, so no logging here.
            return nil
        }
    }
}

/// Decoded gateway-attachment manifest. The agent seals exactly
/// `{fileName, byteCount, contentType, destinationId}` so the phone can name,
/// size, and route the file without ever exposing that to the server.
struct HermesGatewayAttachmentManifest: Hashable, Sendable {
    let fileName: String
    let byteCount: Int
    let contentType: String?
    let destinationId: String

    init?(jsonData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let fileName = HermesGatewayMessageRecord.string(object["fileName"]),
              let destinationId = HermesGatewayMessageRecord.string(object["destinationId"])
        else { return nil }
        self.fileName = fileName
        self.byteCount =
            (object["byteCount"] as? NSNumber)?.intValue
            ?? (object["byteCount"] as? Int)
            ?? 0
        self.contentType = HermesGatewayMessageRecord.string(object["contentType"])
        self.destinationId = destinationId
    }
}

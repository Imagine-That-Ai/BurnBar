import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore

enum MacCloudVaultSignalPayloadError: LocalizedError {
    case signalIdentityUnavailable(domainID: String)
    case invalidSignalEnvelope
    case signalBindingMismatch
    case trustedDeviceMissingSignalIdentity(deviceId: String, keyVersion: Int)
    case trustedDeviceSignalIdentityMismatch(deviceId: String, keyVersion: Int)

    var errorDescription: String? {
        switch self {
        case .signalIdentityUnavailable(let domainID):
            return "Signal identity is unavailable for \(domainID)."
        case .invalidSignalEnvelope:
            return "Signal envelope is invalid."
        case .signalBindingMismatch:
            return "Signal envelope binding does not match the Firestore path."
        case .trustedDeviceMissingSignalIdentity(let deviceId, let keyVersion):
            return "Trusted device \(deviceId)_\(keyVersion) has no Signal identity public key."
        case .trustedDeviceSignalIdentityMismatch(let deviceId, let keyVersion):
            return "Trusted device \(deviceId)_\(keyVersion) has an invalid Signal identity public key."
        }
    }
}

/// macOS counterpart of iOS `MobileCloudVaultSignalPayloads` — produces + opens at-rest
/// Signal `signalEnvelope` payloads for the AgentLens (Mac) chat/conversation write/read
/// paths. Gated on the data-domain `sealingScheme`, so it is fully inert in production
/// until the registry is flipped (item 5). Mirrors the already-shipped Pensieve seal path
/// in `KnowledgeSyncService` (Firestore resolved via `Firestore.firestore()` directly).
enum MacCloudVaultSignalPayloads {
    static func signalSealingIsEnabled(domainID: String) -> Bool {
        DataDomains.domain(domainID)?.sealingScheme == CloudVaultCrypto.signalAtRestEncryption
    }

    /// Seal `plaintext` to the local identity + every trusted device, returning the Firestore
    /// map, or nil when the domain's Signal gate is OFF (caller keeps the legacy AES-GCM seal).
    static func signalEnvelopeIfEnabled(
        domainID: String,
        uid: String,
        firestore: Firestore,
        collection: String,
        docId: String,
        field: String = "signalEnvelope",
        plaintext: Data,
        resolvedKey: CloudVaultResolvedKey
    ) async throws -> [String: Any]? {
        guard signalSealingIsEnabled(domainID: domainID) else { return nil }
        guard let signalIdentity = resolvedKey.signalIdentity else {
            throw MacCloudVaultSignalPayloadError.signalIdentityUnavailable(domainID: domainID)
        }
        let binding = CloudVaultSignalBinding(uid: uid, collection: collection, docId: docId, field: field)
        let recipients = try await atRestRecipients(uid: uid, firestore: firestore, localIdentity: signalIdentity)
        // Sender authentication: sign with THIS device's identity private key so a reader
        // can prove the envelope was produced by a trusted device, not forged by the server.
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            plaintext,
            recipients: recipients,
            binding: binding,
            senderIdentityKeyId: signalIdentity.identityKeyId,
            senderIdentityPrivateKey: signalIdentity.privateKeyData
        )
        return try CloudVaultCrypto.signalEnvelopeDictionary(envelope)
    }

    /// Signal-first open with a relocation guard; nil when no envelope present (caller falls
    /// back to the legacy AES-GCM opener). Throws on invalid/relocated envelope or missing identity.
    /// `trustedSenderPublicKeys` are PINNED identity public keys (resolved out-of-band
    /// from the trusted-device set) used to verify the envelope's sender signature. The
    /// local identity is always added, so a self-authored doc (the common case) is fully
    /// sender-auth-verified with no extra I/O; a cross-device doc whose sender is not in
    /// the provided set throws `senderNotTrusted` and the caller falls back to the
    /// (non-forgeable) legacy sealedPayload.
    static func openSignalPayloadIfPresent(
        _ data: [String: Any],
        uid: String,
        collection: String,
        docId: String,
        field: String = "signalEnvelope",
        bindingField: String? = nil,
        signalIdentity: OpenBurnBarSignalIdentityKeypair?,
        trustedSenderPublicKeys: [String: Data] = [:]
    ) throws -> Data? {
        guard data[field] != nil else { return nil }
        guard let envelope = CloudVaultCrypto.signalEnvelope(from: data[field]) else {
            throw MacCloudVaultSignalPayloadError.invalidSignalEnvelope
        }
        let expectedBinding = CloudVaultSignalBinding(
            uid: uid, collection: collection, docId: docId, field: bindingField ?? field
        )
        guard envelope.binding == expectedBinding else {
            throw MacCloudVaultSignalPayloadError.signalBindingMismatch
        }
        guard let signalIdentity else {
            throw MacCloudVaultSignalPayloadError.signalIdentityUnavailable(domainID: collection)
        }
        var trustedSenders = trustedSenderPublicKeys
        trustedSenders[signalIdentity.identityKeyId] = signalIdentity.atRestRecipient().publicKeyData
        return try OpenBurnBarSignalAtRest.openPayload(
            envelope,
            recipientIdentityKeyId: signalIdentity.identityKeyId,
            recipientIdentityPrivateKey: signalIdentity.privateKeyData,
            expectedBinding: expectedBinding,
            trustedSenderPublicKeys: trustedSenders
        )
    }

    /// Local identity + every trusted escrow device's published Signal identity. Fail-closed:
    /// throws on a missing/invalid trusted-device identity (matches iOS + the Android producer).
    static func atRestRecipients(
        uid: String,
        firestore: Firestore,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async throws -> [OpenBurnBarSignalAtRestRecipient] {
        let userRef = firestore.collection("users").document(uid)
        let trustedDevices = try await userRef.collection("escrow_devices")
            .whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue)
            .getDocuments()

        var recipientsByIdentityKeyId: [String: OpenBurnBarSignalAtRestRecipient] = [
            localIdentity.identityKeyId: localIdentity.atRestRecipient()
        ]

        for document in trustedDevices.documents {
            let data = document.data()
            let rawDeviceId = (data["deviceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceId = (rawDeviceId?.isEmpty == false ? rawDeviceId! : document.documentID)
            guard let keyVersion = data["keyVersion"] as? Int else {
                throw MacCloudVaultSignalPayloadError.trustedDeviceSignalIdentityMismatch(deviceId: deviceId, keyVersion: 0)
            }
            let identityKeyId = OpenBurnBarSignalIdentityKeyStore.identityKeyId(deviceId: deviceId, keyVersion: keyVersion)
            if identityKeyId == localIdentity.identityKeyId { continue }
            let identityDoc = try await userRef.collection("signal_identity_public_keys")
                .document(identityKeyId)
                .getDocument()
            guard let identityData = identityDoc.data() else {
                throw MacCloudVaultSignalPayloadError.trustedDeviceMissingSignalIdentity(deviceId: deviceId, keyVersion: keyVersion)
            }
            guard identityData["deviceId"] as? String == deviceId,
                  identityData["identityKeyId"] as? String == identityKeyId,
                  identityData["keyVersion"] as? Int == keyVersion,
                  identityData["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption,
                  let publicKeyBase64 = identityData["publicKeyData"] as? String,
                  let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
                throw MacCloudVaultSignalPayloadError.trustedDeviceSignalIdentityMismatch(deviceId: deviceId, keyVersion: keyVersion)
            }
            recipientsByIdentityKeyId[identityKeyId] = OpenBurnBarSignalAtRestRecipient(
                recipientKind: "device",
                recipientIdentityKeyId: identityKeyId,
                publicKeyData: publicKeyData
            )
        }

        return recipientsByIdentityKeyId.values.sorted { $0.recipientIdentityKeyId < $1.recipientIdentityKeyId }
    }
}

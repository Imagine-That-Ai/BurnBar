import FirebaseFirestore
import FirebaseRemoteConfig
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore

enum MobileCloudVaultSignalPayloadError: LocalizedError {
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

enum MobileCloudVaultSignalPayloads {
    static func signalEnvelopeIfEnabled(
        domainID: String,
        uid: String,
        firestore: Firestore,
        collection: String,
        docId: String,
        field: String = "signalEnvelope",
        plaintext: Data,
        resolvedKey: MobileCloudVaultResolvedKey
    ) async throws -> [String: Any]? {
        guard signalSealingIsEnabled(domainID: domainID) else { return nil }
        guard let signalIdentity = resolvedKey.signalIdentity else {
            throw MobileCloudVaultSignalPayloadError.signalIdentityUnavailable(domainID: domainID)
        }

        let binding = CloudVaultSignalBinding(
            uid: uid,
            collection: collection,
            docId: docId,
            field: field
        )
        let recipients = try await atRestRecipients(
            uid: uid,
            firestore: firestore,
            localIdentity: signalIdentity
        )
        // Sender authentication: sign with THIS device's identity private key.
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            plaintext,
            recipients: recipients,
            binding: binding,
            senderIdentityKeyId: signalIdentity.identityKeyId,
            senderIdentityPrivateKey: signalIdentity.privateKeyData
        )
        return try CloudVaultCrypto.signalEnvelopeDictionary(envelope)
    }

    /// `trustedSenderPublicKeys` are PINNED identity public keys used to verify the
    /// envelope's sender signature. The local identity is always added, so a self-authored
    /// doc is fully verified with no extra I/O; an envelope whose sender is not in the set
    /// throws and the caller falls back to the non-forgeable legacy sealedPayload.
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
            throw MobileCloudVaultSignalPayloadError.invalidSignalEnvelope
        }
        let expectedBinding = CloudVaultSignalBinding(
            uid: uid,
            collection: collection,
            docId: docId,
            field: bindingField ?? field
        )
        guard envelope.binding == expectedBinding else {
            throw MobileCloudVaultSignalPayloadError.signalBindingMismatch
        }
        guard let signalIdentity else {
            throw MobileCloudVaultSignalPayloadError.signalIdentityUnavailable(domainID: collection)
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

    static func signalSealingIsEnabled(domainID: String) -> Bool {
        guard DataDomains.domain(domainID)?.sealingScheme == CloudVaultCrypto.signalAtRestEncryption else {
            return false
        }
        // Kill switch: even when the registry scheme is set, at-rest sealing stays OFF until
        // the per-domain Remote Config flag is enabled — enabling staged % rollout and an
        // instant server-side revert without an app release. Defaults false (RC boolValue
        // default), so a deployed-but-unramped flip is inert.
        return RemoteConfig.remoteConfig()
            .configValue(forKey: "signal_at_rest_\(domainID)_enabled")
            .boolValue
    }

    /// Best-effort PINNED trusted-sender public keys for READ-time sender-auth verification:
    /// local identity + every trusted escrow device's published identity. Never blocks a read
    /// — if the full set cannot resolve it returns just the local identity, so cross-device
    /// envelopes from unresolved senders fall back to the legacy payload. After the readiness
    /// gate (all trusted devices published) this returns the full set, activating cross-device
    /// sender-auth verification.
    static func trustedSenderPublicKeys(
        uid: String,
        firestore: Firestore,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async -> [String: Data] {
        var map: [String: Data] = [localIdentity.identityKeyId: localIdentity.atRestRecipient().publicKeyData]
        if let recipients = try? await atRestRecipients(uid: uid, firestore: firestore, localIdentity: localIdentity) {
            for recipient in recipients { map[recipient.recipientIdentityKeyId] = recipient.publicKeyData }
        }
        return map
    }

    private static func atRestRecipients(
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
            let verified = try await MobileCloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
                uid: uid,
                userRef: userRef,
                deviceDocument: document,
                localIdentity: localIdentity
            )
            if verified.signalIdentityKeyId == localIdentity.identityKeyId { continue }
            recipientsByIdentityKeyId[verified.signalIdentityKeyId] = OpenBurnBarSignalAtRestRecipient(
                recipientKind: "device",
                recipientIdentityKeyId: verified.signalIdentityKeyId,
                publicKeyData: verified.signalIdentityPublicKeyData
            )
        }

        return recipientsByIdentityKeyId.values.sorted {
            $0.recipientIdentityKeyId < $1.recipientIdentityKeyId
        }
    }
}

import FirebaseCore
import FirebaseFirestore
import FirebaseRemoteConfig
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore

enum MobileCloudVaultSignalPayloadError: LocalizedError {
    case signalIdentityUnavailable(domainID: String)
    case signalEnvelopeRequired(domainID: String)
    case invalidSignalEnvelope
    case signalBindingMismatch
    case trustedDeviceMissingSignalIdentity(deviceId: String, keyVersion: Int)
    case trustedDeviceSignalIdentityMismatch(deviceId: String, keyVersion: Int)

    var errorDescription: String? {
        switch self {
        case .signalIdentityUnavailable(let domainID):
            return "Signal identity is unavailable for \(domainID)."
        case .signalEnvelopeRequired(let domainID):
            return "Signal envelope is required for \(domainID)."
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
    enum ActivationState: Equatable {
        case off
        case enabled
        case required
    }

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
        let state = signalActivationState(domainID: domainID)
        guard state != .off else { return nil }
        guard let signalIdentity = resolvedKey.signalIdentity else {
            if state == .required {
                throw MobileCloudVaultSignalPayloadError.signalIdentityUnavailable(domainID: domainID)
            }
            return nil
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
        signalActivationState(domainID: domainID) != .off
    }

    static func signalSealingIsRequired(domainID: String) -> Bool {
        signalActivationState(domainID: domainID) == .required
    }

    /// Required-mode producer guard. The activation state can change between
    /// the caller's first read and the sealing helper's read (for example while
    /// Remote Config is refreshing). A nil result must never turn that race into
    /// a legacy write.
    static func requireEnvelopeIfRequired(
        payload: [String: Any],
        state: ActivationState,
        domainID: String
    ) throws {
        guard state != .required || payload["signalEnvelope"] != nil else {
            throw MobileCloudVaultSignalPayloadError.signalEnvelopeRequired(domainID: domainID)
        }
    }

    static func signalActivationState(domainID: String) -> ActivationState {
        guard DataDomains.domain(domainID)?.sealingScheme == CloudVaultCrypto.signalAtRestEncryption else {
            return .off
        }
        guard FirebaseApp.app() != nil else { return .off }
        let remoteConfig = RemoteConfig.remoteConfig()
        if remoteConfig.configValue(forKey: "signal_at_rest_v1_hard_kill").boolValue
            || remoteConfig.configValue(forKey: "signal_at_rest_\(domainID)_hard_kill").boolValue {
            return .off
        }
        // Kill switch: even when the registry scheme is set, at-rest sealing stays OFF until
        // the per-domain Remote Config flag is enabled — enabling staged % rollout and an
        // instant server-side revert without an app release. Defaults false (RC boolValue
        // default), so a deployed-but-unramped flip is inert.
        guard remoteConfig.configValue(forKey: "signal_at_rest_\(domainID)_enabled").boolValue else {
            return .off
        }
        return remoteConfig.configValue(forKey: "signal_at_rest_\(domainID)_required").boolValue
            ? .required
            : .enabled
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

        let verifiedDevices = try await MobileCloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevices(
            uid: uid,
            userRef: userRef,
            deviceDocuments: trustedDevices.documents,
            localIdentity: localIdentity
        )
        for verified in verifiedDevices {
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

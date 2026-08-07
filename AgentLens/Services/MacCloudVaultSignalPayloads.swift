import FirebaseCore
import FirebaseFirestore
import FirebaseRemoteConfig
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

enum MacCloudVaultSignalActivationState: Equatable {
    case off
    case enabled
    case required
}

/// macOS counterpart of iOS `MobileCloudVaultSignalPayloads` — produces + opens at-rest
/// Signal `signalEnvelope` payloads for the AgentLens (Mac) chat/conversation write/read
/// paths. Gated on the data-domain `sealingScheme`, so it is fully inert in production
/// until the registry is flipped (item 5). Mirrors the already-shipped Pensieve seal path
/// in `KnowledgeSyncService` (Firestore resolved via `Firestore.firestore()` directly).
enum MacCloudVaultSignalPayloads {
    static func activationState(
        hasSignalScheme: Bool,
        enabled: Bool,
        required: Bool,
        hardKill: Bool
    ) -> MacCloudVaultSignalActivationState {
        guard hasSignalScheme, enabled, !hardKill else { return .off }
        return required ? .required : .enabled
    }

    static func activationState(domainID: String) -> MacCloudVaultSignalActivationState {
        guard FirebaseApp.app() != nil else { return .off }
        let config = RemoteConfig.remoteConfig()
        let hardKill = config.configValue(forKey: "signal_at_rest_v1_hard_kill").boolValue
            || config.configValue(forKey: "signal_at_rest_\(domainID)_hard_kill").boolValue
        return activationState(
            hasSignalScheme: DataDomains.domain(domainID)?.sealingScheme == CloudVaultCrypto.signalAtRestEncryption,
            enabled: config.configValue(forKey: "signal_at_rest_\(domainID)_enabled").boolValue,
            required: config.configValue(forKey: "signal_at_rest_\(domainID)_required").boolValue,
            hardKill: hardKill
        )
    }

    static func signalSealingIsEnabled(domainID: String) -> Bool {
        activationState(domainID: domainID) != .off
    }

    static func signalSealingIsRequired(domainID: String) -> Bool {
        activationState(domainID: domainID) == .required
    }

    /// Seal `plaintext` to the local identity + every trusted device, returning the Firestore
    /// map, or nil when the domain's Signal gate is OFF (caller keeps the legacy AES-GCM seal).
    static func signalEnvelopeIfEnabled(
        domainID: String,
        uid: String,
        firestore: @autoclosure () throws -> Firestore,
        collection: String,
        docId: String,
        field: String = "signalEnvelope",
        plaintext: Data,
        resolvedKey: CloudVaultResolvedKey
    ) async throws -> NSDictionary? {
        guard signalSealingIsEnabled(domainID: domainID) else { return nil }
        guard let signalIdentity = resolvedKey.signalIdentity else {
            throw MacCloudVaultSignalPayloadError.signalIdentityUnavailable(domainID: domainID)
        }
        let binding = CloudVaultSignalBinding(uid: uid, collection: collection, docId: docId, field: field)
        let recipients = try await atRestRecipients(uid: uid, firestore: try firestore(), localIdentity: signalIdentity)
        // Sender authentication: sign with THIS device's identity private key so a reader
        // can prove the envelope was produced by a trusted device, not forged by the server.
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            plaintext,
            recipients: recipients,
            binding: binding,
            senderIdentityKeyId: signalIdentity.identityKeyId,
            senderIdentityPrivateKey: signalIdentity.privateKeyData
        )
        return try NSDictionary(dictionary: CloudVaultCrypto.signalEnvelopeDictionary(envelope))
    }

    /// `firestore` is a lazy autoclosure (matching `signalEnvelopeIfEnabled`) so callers can
    /// pass `Firestore.firestore()` without resolving the SDK singleton when the domain's
    /// Signal gate is OFF: unit tests never configure `FirebaseApp`, and an eager argument
    /// would throw `FIRIllegalStateException` before the gate check runs.
    static func applyingSignalEnvelope(
        to legacyPayload: NSDictionary,
        domainID: String,
        uid: String,
        firestore: @autoclosure () throws -> Firestore,
        collection: String,
        docId: String,
        field: String = "signalEnvelope",
        plaintext: Data,
        resolvedKey: CloudVaultResolvedKey,
        legacyPrivateFields: Set<String>,
        mergeWrite: Bool
    ) async throws -> NSDictionary {
        let payload = NSMutableDictionary(dictionary: legacyPayload)
        let state = activationState(domainID: domainID)
        guard state != .off else {
            if mergeWrite {
                payload[field] = FieldValue.delete()
            } else {
                payload.removeObject(forKey: field)
            }
            return payload
        }

        let envelope: NSDictionary
        do {
            guard let sealed = try await signalEnvelopeIfEnabled(
                domainID: domainID,
                uid: uid,
                firestore: try firestore(), // cov:ignore -- reachable only past the .off activation guard, which requires a configured FirebaseApp + Remote Config; the OFF path never resolves the autoclosure and is unit-tested.
                collection: collection,
                docId: docId,
                field: field,
                plaintext: plaintext,
                resolvedKey: resolvedKey
            ) else {
                throw MacCloudVaultSignalPayloadError.signalIdentityUnavailable(domainID: domainID)
            }
            envelope = sealed
        } catch {
            guard state == .required else {
                if mergeWrite {
                    payload[field] = FieldValue.delete()
                } else {
                    payload.removeObject(forKey: field)
                }
                return payload
            }
            throw error
        }

        payload[field] = envelope
        if state == .required {
            for legacyField in legacyPrivateFields {
                if mergeWrite {
                    payload[legacyField] = FieldValue.delete()
                } else {
                    payload.removeObject(forKey: legacyField)
                }
            }
        }
        return payload
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

    /// H2 — at-rest sender-auth downgrade classification. Given an error thrown
    /// while opening a PRESENT `signalEnvelope`, decide whether the reader may
    /// safely fall back to the unauthenticated legacy `sealedPayload`. A
    /// forged/stripped/relocated sender block fails CLOSED (returns `false`);
    /// structural / readiness-gap / cannot-verify errors stay legacy-eligible
    /// (the legacy payload is still AES-GCM under the symmetric vault key, which
    /// the server does not hold, so it is non-forgeable — only the
    /// sender-authentication proof is being deferred). This centralizes the
    /// `OpenBurnBarSignalCoreError` policy AND the wrapper's own binding/identity
    /// errors so every Mac at-rest reader behaves identically.
    static func allowsLegacyAtRestFallback(for error: Error, senderSetComplete: Bool) -> Bool {
        if let coreError = error as? OpenBurnBarSignalCoreError {
            return coreError.allowsLegacyAtRestFallback(senderSetComplete: senderSetComplete)
        }
        if let wrapError = error as? MacCloudVaultSignalPayloadError {
            switch wrapError {
            case .signalBindingMismatch, .trustedDeviceSignalIdentityMismatch:
                // Relocated/replayed envelope, or a trusted device whose published
                // identity does not match — treat as an attack, never downgrade.
                return false
            case .invalidSignalEnvelope, .signalIdentityUnavailable, .trustedDeviceMissingSignalIdentity:
                // Structural / cannot-verify / readiness gap — legacy remains safe.
                return true
            }
        }
        return true
    }

    /// Best-effort PINNED trusted-sender public keys for READ-time sender-auth verification:
    /// the local identity plus every trusted escrow device's published identity. Unlike the
    /// fail-closed producer resolver, a read is never blocked — if the trusted set cannot be
    /// fully resolved (e.g. a peer hasn't published yet) it returns just the local identity,
    /// so cross-device envelopes from unresolved senders fall back to the (non-forgeable)
    /// legacy payload. After the readiness gate (every trusted device published) this returns
    /// the full set, so cross-device sender-auth verification is active.
    static func trustedSenderPublicKeys(
        uid: String,
        firestore: Firestore,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async -> [String: Data] {
        var map: [String: Data] = [localIdentity.identityKeyId: localIdentity.atRestRecipient().publicKeyData]
        if let recipients = try? await atRestRecipients(uid: uid, firestore: firestore, localIdentity: localIdentity) { // try?-ok(fail-safe read fallback)
            for recipient in recipients { map[recipient.recipientIdentityKeyId] = recipient.publicKeyData }
        }
        return map
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
            let verified = try await CloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
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

        return recipientsByIdentityKeyId.values.sorted { $0.recipientIdentityKeyId < $1.recipientIdentityKeyId }
    }
}

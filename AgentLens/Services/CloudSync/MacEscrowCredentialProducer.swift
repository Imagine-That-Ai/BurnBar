#if canImport(AppKit)
import CryptoKit
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import OpenBurnBarCore

// MARK: - Escrow seal (producer side)

/// Ephemeral-static P-256 ECIES seal for the Mac→phone escrow producer.
///
/// The byte layout is **identical** to the iOS import path
/// (`iOSDeviceKeypair.encrypt` / `.decrypt`) and to
/// ``CloudVaultCrypto/wrapVaultKey(_:recipientPublicKey:)``:
///
///   ephemeralPublicKey (65-byte X9.63) || AES.GCM combined (nonce||ct||tag)
///
/// with `HKDF<SHA256>` using an empty salt, `sharedInfo` =
/// `"OpenBurnBar-Escrow-v1"`, and a 32-byte derived key. `wrapVaultKey`
/// only accepts a 32-byte vault key, so the producer cannot reuse it for
/// arbitrary-length provider credentials — this helper mirrors the exact
/// same construction for a variable-length plaintext so the phone's
/// `iOSDeviceKeypair.decrypt` reads it back byte-for-byte.
enum MacEscrowSeal {
    /// Seals `plaintext` to the recipient's escrow public key (raw X9.63 bytes).
    static func seal(_ plaintext: Data, recipientPublicKey: Data) throws -> Data {
        let recipientKey: P256.KeyAgreement.PublicKey
        do {
            recipientKey = try P256.KeyAgreement.PublicKey(x963Representation: recipientPublicKey)
        } catch {
            throw MacEscrowProducerError.invalidRecipientPublicKey
        }

        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: recipientKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("OpenBurnBar-Escrow-v1".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey)
        guard let combined = sealed.combined else {
            throw MacEscrowProducerError.encryptionFailed
        }
        // ephemeral_pub (65) || sealed_box — matches iOSDeviceKeypair.decrypt.
        return ephemeralKey.publicKey.x963Representation + combined
    }
}

// MARK: - Producer inputs

/// The resolved credential secret that the producer seals for transfer.
struct MacEscrowCredentialSecret: Equatable, Sendable {
    let secret: String
    let credentialKind: EscrowCredentialKind
    let accountLabel: String?
}

/// The recipient device's verified escrow public key, resolved from
/// `escrow_devices` + `escrow_public_keys` with the fingerprint bound to the
/// published key bytes (so the server cannot swap in an attacker key).
struct MacEscrowRecipientKey: Equatable, Sendable {
    let deviceId: String
    let keyVersion: Int
    let publicKeyData: Data
    let publicKeyFingerprint: String
}

/// The Firestore writes the producer performs, surfaced as plain dictionaries
/// so the envelope/grant shape can be asserted against the import expectations
/// (`LiveCloudReader.loadAvailableEnvelopes` / `LiveEscrowGateway.runImport`)
/// in unit tests without a live Firestore.
struct MacEscrowEnvelopePlan: Equatable {
    let grantId: String
    let envelopeId: String
    let grant: [String: Any]
    let envelope: [String: Any]
    let auditEvent: [String: Any]

    static func == (lhs: MacEscrowEnvelopePlan, rhs: MacEscrowEnvelopePlan) -> Bool {
        lhs.grantId == rhs.grantId
            && lhs.envelopeId == rhs.envelopeId
            && NSDictionary(dictionary: lhs.grant).isEqual(to: rhs.grant)
            && NSDictionary(dictionary: lhs.envelope).isEqual(to: rhs.envelope)
            && NSDictionary(dictionary: lhs.auditEvent).isEqual(to: rhs.auditEvent)
    }
}

enum MacEscrowProducerError: LocalizedError, Equatable {
    case notAuthenticated
    case noTransferableCredential(provider: String)
    case noRecipientDevice
    case recipientKeyUnavailable(deviceId: String)
    case recipientKeyUntrusted(deviceId: String)
    case invalidRecipientPublicKey
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in before transferring an encrypted credential."
        case .noTransferableCredential(let provider):
            return "No transferable \(provider) credential was found on this Mac. Nothing was read, uploaded, or granted."
        case .noRecipientDevice:
            return "No trusted companion device is available to receive the encrypted credential."
        case .recipientKeyUnavailable(let deviceId):
            return "The companion device \(deviceId) has not published an escrow key yet."
        case .recipientKeyUntrusted(let deviceId):
            return "The companion device \(deviceId) is not a trusted escrow device."
        case .invalidRecipientPublicKey:
            return "The companion device's escrow public key is invalid."
        case .encryptionFailed:
            return "The credential could not be encrypted for the companion device."
        }
    }
}

// MARK: - Injectable collaborators

/// Resolves the recipient device's verified escrow public key.
@MainActor
protocol MacEscrowRecipientKeyResolver {
    func recipientKey(uid: String, destinationDeviceID: String) async throws -> MacEscrowRecipientKey
}

/// Reads the transferable provider credential the producer should seal.
@MainActor
protocol MacEscrowCredentialSecretReader {
    func credentialSecret(for provider: AgentProvider) async -> MacEscrowCredentialSecret?
}

/// Persists the grant/envelope/audit writes for one transfer.
@MainActor
protocol MacEscrowEnvelopeWriter {
    func write(uid: String, plan: MacEscrowEnvelopePlan) async throws
}

// MARK: - Producer

/// Mac→phone escrow PRODUCER consumed by the iOS import path.
///
/// Enumerates the transferable provider credential, ECIES-seals it to the
/// recipient device's escrow public key (see ``MacEscrowSeal``), and writes
/// the `escrow_grants` + `escrow_envelopes` docs the phone import reads. It
/// emits honest progress stages tied to real work and fails closed (no
/// envelope, no grant) whenever a step cannot complete.
@MainActor
struct MacEscrowCredentialProducer {
    let sourceDeviceID: String
    let recipientKeyResolver: MacEscrowRecipientKeyResolver
    let secretReader: MacEscrowCredentialSecretReader
    let writer: MacEscrowEnvelopeWriter
    /// Injectable id factories keep the produced plan deterministic in tests.
    var grantIdFactory: () -> String = { UUID().uuidString }
    var envelopeIdFactory: () -> String = { UUID().uuidString }
    var now: () -> Date = { Date() }

    func startExport(
        uid: String?,
        provider: AgentProvider,
        destinationDeviceID: String,
        onStage: @escaping @MainActor (MacExportStage) -> Void
    ) async {
        guard let uid, !uid.isEmpty else {
            onStage(.failed(message: MacEscrowProducerError.notAuthenticated.localizedDescription))
            return
        }
        guard !destinationDeviceID.isEmpty, destinationDeviceID != "pending-device" else {
            onStage(.failed(message: MacEscrowProducerError.noRecipientDevice.localizedDescription))
            return
        }

        // Enumerate: read the transferable source credential. Fail closed when
        // none is available so we never emit an empty/fake envelope.
        guard let credential = await secretReader.credentialSecret(for: provider),
              !credential.secret.isEmpty,
              credential.credentialKind != .unknown else {
            onStage(.failed(message: MacEscrowProducerError.noTransferableCredential(provider: provider.displayName).localizedDescription))
            return
        }

        // Encrypt: resolve the recipient's verified escrow key, then seal.
        onStage(.encrypting)
        let recipient: MacEscrowRecipientKey
        do {
            recipient = try await recipientKeyResolver.recipientKey(uid: uid, destinationDeviceID: destinationDeviceID)
        } catch {
            onStage(.failed(message: error.localizedDescription))
            return
        }

        let plan: MacEscrowEnvelopePlan
        do {
            plan = try Self.buildEnvelopePlan(
                provider: provider,
                credential: credential,
                sourceDeviceID: sourceDeviceID,
                recipient: recipient,
                grantId: grantIdFactory(),
                envelopeId: envelopeIdFactory(),
                createdAt: now()
            )
        } catch {
            onStage(.failed(message: error.localizedDescription))
            return
        }

        // Upload: write the grant + envelope + audit event together.
        onStage(.uploading)
        do {
            try await writer.write(uid: uid, plan: plan)
        } catch {
            onStage(.failed(message: error.localizedDescription))
            return
        }

        onStage(.done)
    }

    /// Pure envelope builder — the load-bearing shape the phone import reads.
    ///
    /// Field names mirror `LiveCloudReader.loadAvailableEnvelopes` (which keys
    /// off `grantId`, `providerId`, `credentialKind`, `accountLabel`,
    /// `sourceDeviceId`, `targetDeviceId`, `createdAt`) and
    /// `LiveEscrowGateway.runImport` (which reads `ciphertext` + `keyVersion`
    /// and re-checks the grant `status` before decrypting).
    static func buildEnvelopePlan(
        provider: AgentProvider,
        credential: MacEscrowCredentialSecret,
        sourceDeviceID: String,
        recipient: MacEscrowRecipientKey,
        grantId: String,
        envelopeId: String,
        createdAt: Date
    ) throws -> MacEscrowEnvelopePlan {
        let ciphertext = try MacEscrowSeal.seal(
            Data(credential.secret.utf8),
            recipientPublicKey: recipient.publicKeyData
        )
        let providerId = provider.persistedToken
        let timestamp = Timestamp(date: createdAt)

        let grant: [String: Any] = [
            "sourceDeviceId": sourceDeviceID,
            "targetDeviceId": recipient.deviceId,
            "providerId": providerId,
            "credentialKind": credential.credentialKind.rawValue,
            "status": EscrowGrantStatus.granted.rawValue,
            "grantedAt": timestamp
        ]

        let envelope: [String: Any] = [
            "grantId": grantId,
            "sourceDeviceId": sourceDeviceID,
            "targetDeviceId": recipient.deviceId,
            "providerId": providerId,
            "credentialKind": credential.credentialKind.rawValue,
            "accountLabel": credential.accountLabel ?? provider.displayName,
            "ciphertext": ciphertext.base64EncodedString(),
            "keyVersion": recipient.keyVersion,
            "envelopeVersion": 1,
            "createdAt": timestamp
        ]

        let auditEvent: [String: Any] = [
            "eventType": "envelope_created",
            "actorDeviceId": sourceDeviceID,
            "targetDeviceId": recipient.deviceId,
            "providerId": providerId,
            "grantId": grantId,
            "envelopeId": envelopeId,
            "timestamp": timestamp,
            "metadata": ["credentialKind": credential.credentialKind.rawValue]
        ]

        return MacEscrowEnvelopePlan(
            grantId: grantId,
            envelopeId: envelopeId,
            grant: grant,
            envelope: envelope,
            auditEvent: auditEvent
        )
    }
}

// MARK: - Live collaborators

/// Resolves the recipient escrow key from Firestore, binding the published
/// fingerprint to the actual key bytes the same way the trust UX and the
/// Cloud Vault chain verifier do (so a malicious backend cannot substitute an
/// attacker key while keeping a legitimately-signed fingerprint string).
@MainActor
struct MacLiveEscrowRecipientKeyResolver: MacEscrowRecipientKeyResolver {
    var firestore: Firestore = Firestore.firestore()

    func recipientKey(uid: String, destinationDeviceID: String) async throws -> MacEscrowRecipientKey {
        let userRef = firestore.collection("users").document(uid)
        let deviceSnapshot = try await userRef.collection("escrow_devices")
            .document(destinationDeviceID)
            .getDocument()
        guard let deviceData = deviceSnapshot.data(),
              deviceData["trustState"] as? String == EscrowDeviceTrustState.trusted.rawValue,
              let keyVersion = deviceData["keyVersion"] as? Int,
              let fingerprint = deviceData["publicKeyFingerprint"] as? String else {
            throw MacEscrowProducerError.recipientKeyUntrusted(deviceId: destinationDeviceID)
        }

        let keySnapshot = try await userRef.collection("escrow_public_keys")
            .document("\(destinationDeviceID)_\(keyVersion)")
            .getDocument()
        guard let keyData = keySnapshot.data(),
              keyData["deviceId"] as? String == destinationDeviceID,
              keyData["keyVersion"] as? Int == keyVersion,
              let publicKeyBase64 = keyData["publicKeyData"] as? String,
              let publicKeyBytes = Data(base64Encoded: publicKeyBase64),
              EscrowDeviceSafetyCode.isFingerprint(fingerprint, boundTo: publicKeyBase64) else {
            throw MacEscrowProducerError.recipientKeyUnavailable(deviceId: destinationDeviceID)
        }

        return MacEscrowRecipientKey(
            deviceId: destinationDeviceID,
            keyVersion: keyVersion,
            publicKeyData: publicKeyBytes,
            publicKeyFingerprint: fingerprint
        )
    }
}

/// Reads the transferable provider credential from the switcher Keychain store.
///
/// The active switcher profile context the secret is keyed by is not threaded
/// into the credential-transfer sheet today, so this live reader resolves the
/// provider's stored OAuth token (keyed by `profileID` + provider token) and
/// API key (keyed by `profileID` + CLI type) best-effort, scoping the profile
/// to this Mac's stable install id. It returns `nil` when no real secret is
/// found — which makes the producer fail closed rather than emit an empty
/// envelope. Wiring the user-selected profile/account is tracked in residual.
@MainActor
struct MacLiveEscrowCredentialSecretReader: MacEscrowCredentialSecretReader {
    private let transferabilityFor: (AgentProvider) -> MacCredentialTransferability
    private let authStore: SwitcherAuthStore
    private let profileIDProvider: () -> String

    init(
        transferabilityFor: @escaping (AgentProvider) -> MacCredentialTransferability,
        authStore: SwitcherAuthStore = SwitcherAuthStore(),
        profileIDProvider: @escaping () -> String = { Self.installProfileID() }
    ) {
        self.transferabilityFor = transferabilityFor
        self.authStore = authStore
        self.profileIDProvider = profileIDProvider
    }

    func credentialSecret(for provider: AgentProvider) async -> MacEscrowCredentialSecret? {
        let transferability = transferabilityFor(provider)
        guard transferability.isTransferable else { return nil }
        let credentialKind = transferability.credentialKind
        let profileID = profileIDProvider()
        let secret: String?
        switch credentialKind {
        case .oauthToken, .bearerToken:
            secret = authStore.oauthToken(forProfileID: profileID, provider: provider.persistedToken)
        case .apiKey:
            // Only providers with a clean CLI-profile mapping are resolvable
            // without the selected profile context; others fail closed below.
            secret = Self.cliType(for: provider).flatMap {
                authStore.apiKey(forProfileID: profileID, cliType: $0)
            }
        case .unknown:
            secret = nil
        }
        guard let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return MacEscrowCredentialSecret(
            secret: secret,
            credentialKind: credentialKind,
            accountLabel: provider.displayName
        )
    }

    /// Maps a provider to its switcher CLI profile type where the mapping is
    /// unambiguous (the API-key store is keyed by CLI type, not provider).
    private static func cliType(for provider: AgentProvider) -> SwitcherCLIProfileType? {
        switch provider {
        case .codex: return .codex
        case .claudeCode: return .claude
        case .openCode: return .opencode
        case .forgeDev: return .forge
        case .antigravity: return .antigravity
        case .cursorAgent: return .cursorAgent
        default: return nil
        }
    }

    /// This Mac's stable install id, used as the switcher profile scope. Mirrors
    /// `MacLiveDeviceTrustGateway.loadOrCreateDeviceId`.
    static func installProfileID(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: OpenBurnBarIdentity.deviceIDKey), !stored.isEmpty {
            return stored
        }
        for legacyKey in OpenBurnBarIdentity.legacyDeviceIDKeys {
            if let stored = defaults.string(forKey: legacyKey), !stored.isEmpty {
                return stored
            }
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: OpenBurnBarIdentity.deviceIDKey)
        return created
    }
}

/// Writes the grant/envelope/audit docs to Firestore.
@MainActor
struct MacLiveEscrowEnvelopeWriter: MacEscrowEnvelopeWriter {
    var firestore: Firestore = Firestore.firestore()

    func write(uid: String, plan: MacEscrowEnvelopePlan) async throws {
        let userRef = firestore.collection("users").document(uid)
        try await userRef.collection("escrow_grants").document(plan.grantId).setData(plan.grant)
        try await userRef.collection("escrow_envelopes").document(plan.envelopeId).setData(plan.envelope)
        try await userRef.collection("escrow_audit_events").document(UUID().uuidString).setData(plan.auditEvent)
    }
}
#endif

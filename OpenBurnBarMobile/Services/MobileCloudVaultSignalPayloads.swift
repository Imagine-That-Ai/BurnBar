import FirebaseFirestore
import FirebaseCore
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
    static let globalSignalAtRestRemoteConfigKey = "signal_at_rest_enabled"
    static let signalAtRestDisabledRemoteConfigKey = "signal_at_rest_disabled"

    /// Test hook for deterministic activation checks without Firebase Remote Config.
    static var signalSealingOverrideProvider: ((String) -> Bool?)?

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
        await refreshSignalRemoteConfigIfAvailable()
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
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            plaintext,
            recipients: recipients,
            binding: binding
        )
        return try CloudVaultCrypto.signalEnvelopeDictionary(envelope)
    }

    static func openSignalPayloadIfPresent(
        _ data: [String: Any],
        uid: String,
        collection: String,
        docId: String,
        field: String = "signalEnvelope",
        bindingField: String? = nil,
        signalIdentity: OpenBurnBarSignalIdentityKeypair?
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
        return try OpenBurnBarSignalAtRest.openPayload(
            envelope,
            recipientIdentityKeyId: signalIdentity.identityKeyId,
            recipientIdentityPrivateKey: signalIdentity.privateKeyData,
            expectedBinding: expectedBinding
        )
    }

    static func signalSealingIsEnabled(domainID: String) -> Bool {
        if let override = signalSealingOverrideProvider?(domainID) {
            return override
        }
        if remoteConfigSignalAtRestIsDisabled() {
            return false
        }
        if DataDomains.domain(domainID)?.sealingScheme == CloudVaultCrypto.signalAtRestEncryption {
            return true
        }
        return remoteConfigSignalSealingIsEnabled(domainID: domainID)
    }

    static func signalAtRestRemoteConfigKey(domainID: String) -> String {
        let safe = domainID
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "_" ? character : "_"
            }
        return "signal_at_rest_\(String(safe))_enabled"
    }

    private static func remoteConfigSignalSealingIsEnabled(domainID: String) -> Bool {
        guard FirebaseApp.app() != nil else { return false }
        let remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.setDefaults([
            globalSignalAtRestRemoteConfigKey: NSNumber(value: false),
            signalAtRestDisabledRemoteConfigKey: NSNumber(value: false),
            signalAtRestRemoteConfigKey(domainID: domainID): NSNumber(value: false)
        ])
        return remoteConfig.configValue(forKey: globalSignalAtRestRemoteConfigKey).boolValue
            || remoteConfig.configValue(forKey: signalAtRestRemoteConfigKey(domainID: domainID)).boolValue
    }

    private static func remoteConfigSignalAtRestIsDisabled() -> Bool {
        guard FirebaseApp.app() != nil else { return false }
        let remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.setDefaults([signalAtRestDisabledRemoteConfigKey: NSNumber(value: false)])
        return remoteConfig.configValue(forKey: signalAtRestDisabledRemoteConfigKey).boolValue
    }

    private static func refreshSignalRemoteConfigIfAvailable() async {
        guard FirebaseApp.app() != nil else { return }
        await withCheckedContinuation { continuation in
            RemoteConfig.remoteConfig().fetchAndActivate { _, _ in
                continuation.resume()
            }
        }
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
            let data = document.data()
            let rawDeviceId = (data["deviceId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceId: String
            if let rawDeviceId, !rawDeviceId.isEmpty {
                deviceId = rawDeviceId
            } else {
                deviceId = document.documentID
            }
            guard let keyVersion = data["keyVersion"] as? Int else {
                throw MobileCloudVaultSignalPayloadError.trustedDeviceSignalIdentityMismatch(
                    deviceId: deviceId,
                    keyVersion: 0
                )
            }
            let identityKeyId = OpenBurnBarSignalIdentityKeyStore.identityKeyId(
                deviceId: deviceId,
                keyVersion: keyVersion
            )
            let identityDoc = try await userRef.collection("signal_identity_public_keys")
                .document(identityKeyId)
                .getDocument()
            guard let identityData = identityDoc.data() else {
                throw MobileCloudVaultSignalPayloadError.trustedDeviceMissingSignalIdentity(
                    deviceId: deviceId,
                    keyVersion: keyVersion
                )
            }
            guard identityData["deviceId"] as? String == deviceId,
                  identityData["identityKeyId"] as? String == identityKeyId,
                  identityData["keyVersion"] as? Int == keyVersion,
                  identityData["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption,
                  let publicKeyBase64 = identityData["publicKeyData"] as? String,
                  let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
                throw MobileCloudVaultSignalPayloadError.trustedDeviceSignalIdentityMismatch(
                    deviceId: deviceId,
                    keyVersion: keyVersion
                )
            }
            recipientsByIdentityKeyId[identityKeyId] = OpenBurnBarSignalAtRestRecipient(
                recipientKind: "device",
                recipientIdentityKeyId: identityKeyId,
                publicKeyData: publicKeyData
            )
        }

        return recipientsByIdentityKeyId.values.sorted {
            $0.recipientIdentityKeyId < $1.recipientIdentityKeyId
        }
    }
}

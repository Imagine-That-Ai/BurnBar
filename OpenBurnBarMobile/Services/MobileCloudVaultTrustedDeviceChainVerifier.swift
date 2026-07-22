import CryptoKit
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import OSLog

struct MobileCloudVaultVerifiedTrustedDevice: Sendable {
    let deviceId: String
    let keyVersion: Int
    let escrowPublicKeyFingerprint: String
    let escrowPublicKeyData: Data
    let signalIdentityKeyId: String
    let signalIdentityPublicKeyFingerprint: String
    let signalIdentityPublicKeyData: Data
}

enum MobileCloudVaultTrustChainVerificationError: LocalizedError {
    case invalidTrustedDevice(deviceId: String)
    case missingEscrowPublicKey(deviceId: String, keyVersion: Int)
    case missingSignalIdentity(deviceId: String, keyVersion: Int)
    case missingTrustChain(deviceId: String)
    case invalidTrustChain(deviceId: String)

    var errorDescription: String? {
        switch self {
        case .invalidTrustedDevice(let deviceId):
            return "Trusted device \(deviceId) is malformed."
        case .missingEscrowPublicKey(let deviceId, let keyVersion):
            return "Trusted device \(deviceId)_\(keyVersion) has no escrow public key."
        case .missingSignalIdentity(let deviceId, let keyVersion):
            return "Trusted device \(deviceId)_\(keyVersion) has no Signal identity."
        case .missingTrustChain(let deviceId):
            return "Trusted device \(deviceId) is missing a verifiable trust chain."
        case .invalidTrustChain(let deviceId):
            return "Trusted device \(deviceId) has an invalid trust chain."
        }
    }
}

enum MobileCloudVaultTrustedDeviceChainVerifier {
    @MainActor
    private static let verificationCache = MobileCloudVaultTrustedDeviceVerificationCache()
    private static let logger = Logger(
        subsystem: "com.openburnbar.app",
        category: "cloud-vault-trust"
    )

    static func boundDeviceID(documentID: String, storedDeviceID: String?) throws -> String {
        let normalizedDocumentID = documentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDocumentID.isEmpty else {
            throw MobileCloudVaultTrustChainVerificationError.invalidTrustedDevice(deviceId: documentID)
        }

        if let storedDeviceID {
            guard storedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedDocumentID else {
                throw MobileCloudVaultTrustChainVerificationError.invalidTrustedDevice(deviceId: documentID)
            }
        }
        return normalizedDocumentID
    }

    @MainActor
    static func retainingCryptographicallyValidDevices<Source>(
        _ sources: [Source],
        verify: @MainActor (Source) async throws -> MobileCloudVaultVerifiedTrustedDevice,
        onRejected: @MainActor (Source, MobileCloudVaultTrustChainVerificationError) -> Void = { _, _ in }
    ) async throws -> [MobileCloudVaultVerifiedTrustedDevice] {
        var verified: [MobileCloudVaultVerifiedTrustedDevice] = []
        verified.reserveCapacity(sources.count)
        for source in sources {
            do {
                verified.append(try await verify(source))
            } catch let error as MobileCloudVaultTrustChainVerificationError {
                onRejected(source, error)
            } catch {
                throw error
            }
        }
        return verified
    }

    @MainActor
    static func verifiedTrustedDevices(
        uid: String,
        userRef: DocumentReference,
        deviceDocuments: [QueryDocumentSnapshot],
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async throws -> [MobileCloudVaultVerifiedTrustedDevice] {
        let cacheKey = MobileCloudVaultTrustedDeviceVerificationCache.Key(
            uid: uid,
            localIdentityKeyID: localIdentity.identityKeyId,
            localIdentityFingerprint: localIdentity.publicKeyFingerprint,
            trustSnapshotDigest: trustSnapshotDigest(deviceDocuments)
        )
        return try await verificationCache.value(for: cacheKey) {
            try await retainingCryptographicallyValidDevices(
                deviceDocuments,
                verify: { document in
                    try await verifiedTrustedDevice(
                        uid: uid,
                        userRef: userRef,
                        deviceDocument: document,
                        localIdentity: localIdentity
                    )
                },
                onRejected: { document, error in
                    logger.error(
                        "Ignoring unverified legacy trusted-device record id=\(document.documentID, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            )
        }
    }

    private static func trustSnapshotDigest(_ documents: [QueryDocumentSnapshot]) -> String {
        let fields = [
            "deviceId",
            "trustState",
            "keyVersion",
            "publicKeyFingerprint",
            "trustChainVersion",
            "trustChainAlgorithm",
            "targetSignalIdentityKeyId",
            "targetSignalIdentityPublicKeyFingerprint",
            "approvedByDeviceId",
            "approvedBySignalIdentityKeyId",
            "approvedBySignalIdentityPublicKeyFingerprint",
            "trustChainSignature"
        ]
        let canonical = documents
            .sorted { $0.documentID < $1.documentID }
            .map { document in
                let data = document.data()
                let values = fields.map { field -> String in
                    if let value = data[field] as? String { return value }
                    if let value = data[field] as? Int { return String(value) }
                    if let value = data[field] as? NSNumber { return value.stringValue }
                    return ""
                }
                return ([document.documentID] + values)
                    .map { "\(Data($0.utf8).count):\($0)" }
                    .joined(separator: "|")
            }
            .joined(separator: "\n")
        return Data(SHA256.hash(data: Data(canonical.utf8))).base64EncodedString()
    }

    static func verifiedTrustedDevice(
        uid: String,
        userRef: DocumentReference,
        deviceDocument: QueryDocumentSnapshot,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async throws -> MobileCloudVaultVerifiedTrustedDevice {
        let deviceID = try boundDeviceID(
            documentID: deviceDocument.documentID,
            storedDeviceID: deviceDocument.data()["deviceId"] as? String
        )
        return try await verifiedTrustedDevice(
            uid: uid,
            userRef: userRef,
            deviceId: deviceID,
            localIdentity: localIdentity,
            visited: []
        )
    }

    static func verifiedTrustedDevice(
        uid: String,
        userRef: DocumentReference,
        deviceId: String,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async throws -> MobileCloudVaultVerifiedTrustedDevice {
        try await verifiedTrustedDevice(
            uid: uid,
            userRef: userRef,
            deviceId: deviceId,
            localIdentity: localIdentity,
            visited: []
        )
    }

    private static func verifiedTrustedDevice(
        uid: String,
        userRef: DocumentReference,
        deviceId rawDeviceId: String,
        localIdentity: OpenBurnBarSignalIdentityKeypair,
        visited: Set<String>
    ) async throws -> MobileCloudVaultVerifiedTrustedDevice {
        let deviceId = rawDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty, !visited.contains(deviceId) else {
            throw MobileCloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: rawDeviceId)
        }
        let deviceSnapshot = try await userRef.collection("escrow_devices").document(deviceId).getDocument()
        guard let deviceData = deviceSnapshot.data(),
              deviceData["trustState"] as? String == EscrowDeviceTrustState.trusted.rawValue,
              let keyVersion = deviceData["keyVersion"] as? Int,
              let escrowFingerprint = deviceData["publicKeyFingerprint"] as? String else {
            throw MobileCloudVaultTrustChainVerificationError.invalidTrustedDevice(deviceId: deviceId)
        }

        let publicKeySnapshot = try await userRef.collection("escrow_public_keys")
            .document("\(deviceId)_\(keyVersion)")
            .getDocument()
        guard let publicKeyData = publicKeySnapshot.data(),
              publicKeyData["deviceId"] as? String == deviceId,
              publicKeyData["keyVersion"] as? Int == keyVersion,
              publicKeyData["publicKeyFingerprint"] as? String == escrowFingerprint,
              let escrowPublicKeyBase64 = publicKeyData["publicKeyData"] as? String,
              let escrowPublicKey = Data(base64Encoded: escrowPublicKeyBase64) else {
            throw MobileCloudVaultTrustChainVerificationError.missingEscrowPublicKey(deviceId: deviceId, keyVersion: keyVersion)
        }

        // H1: bind the server fingerprint to the actual escrow key bytes so a
        // backend byte-swap (invisible to the fingerprint-only trust-chain
        // signature) cannot get the vault key wrapped to an attacker key.
        guard EscrowDeviceSafetyCode.isFingerprint(escrowFingerprint, boundTo: escrowPublicKeyBase64) else {
            throw MobileCloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }

        let signalIdentityKeyId = OpenBurnBarSignalIdentityKeyStore.identityKeyId(
            deviceId: deviceId,
            keyVersion: keyVersion
        )
        let signalSnapshot = try await userRef.collection("signal_identity_public_keys")
            .document(signalIdentityKeyId)
            .getDocument()
        guard let signalData = signalSnapshot.data(),
              signalData["deviceId"] as? String == deviceId,
              signalData["identityKeyId"] as? String == signalIdentityKeyId,
              signalData["keyVersion"] as? Int == keyVersion,
              signalData["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption,
              let signalFingerprint = signalData["publicKeyFingerprint"] as? String,
              let signalPublicKeyBase64 = signalData["publicKeyData"] as? String,
              let signalPublicKey = Data(base64Encoded: signalPublicKeyBase64) else {
            throw MobileCloudVaultTrustChainVerificationError.missingSignalIdentity(deviceId: deviceId, keyVersion: keyVersion)
        }

        // H1: bind the Signal identity fingerprint to its actual key bytes.
        guard Data(SHA256.hash(data: signalPublicKey)).base64EncodedString() == signalFingerprint else {
            throw MobileCloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }

        let verified = MobileCloudVaultVerifiedTrustedDevice(
            deviceId: deviceId,
            keyVersion: keyVersion,
            escrowPublicKeyFingerprint: escrowFingerprint,
            escrowPublicKeyData: escrowPublicKey,
            signalIdentityKeyId: signalIdentityKeyId,
            signalIdentityPublicKeyFingerprint: signalFingerprint,
            signalIdentityPublicKeyData: signalPublicKey
        )

        if signalIdentityKeyId == localIdentity.identityKeyId {
            guard signalPublicKey == localIdentity.publicKeyData else {
                throw MobileCloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
            }
            return verified
        }

        guard deviceData["trustChainVersion"] as? Int == CloudVaultDeviceTrustChain.version,
              deviceData["trustChainAlgorithm"] as? String == CloudVaultDeviceTrustChain.algorithm,
              deviceData["targetSignalIdentityKeyId"] as? String == signalIdentityKeyId,
              deviceData["targetSignalIdentityPublicKeyFingerprint"] as? String == signalFingerprint,
              let approvedByDeviceId = deviceData["approvedByDeviceId"] as? String,
              let approvedBySignalIdentityKeyId = deviceData["approvedBySignalIdentityKeyId"] as? String,
              let approvedBySignalFingerprint = deviceData["approvedBySignalIdentityPublicKeyFingerprint"] as? String,
              let signature = deviceData["trustChainSignature"] as? String else {
            throw MobileCloudVaultTrustChainVerificationError.missingTrustChain(deviceId: deviceId)
        }

        let approver = try await verifiedTrustedDevice(
            uid: uid,
            userRef: userRef,
            deviceId: approvedByDeviceId,
            localIdentity: localIdentity,
            visited: visited.union([deviceId])
        )
        guard approver.signalIdentityKeyId == approvedBySignalIdentityKeyId,
              approver.signalIdentityPublicKeyFingerprint == approvedBySignalFingerprint else {
            throw MobileCloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }

        let payload = CloudVaultDeviceTrustChainPayload(
            uid: uid,
            targetDeviceId: deviceId,
            targetEscrowPublicKeyFingerprint: escrowFingerprint,
            targetKeyVersion: keyVersion,
            targetSignalIdentityKeyId: signalIdentityKeyId,
            targetSignalIdentityPublicKeyFingerprint: signalFingerprint,
            approverDeviceId: approver.deviceId,
            approverSignalIdentityKeyId: approver.signalIdentityKeyId,
            approverSignalIdentityPublicKeyFingerprint: approver.signalIdentityPublicKeyFingerprint
        )
        guard CloudVaultDeviceTrustChain.verify(
            payload,
            signatureBase64: signature,
            approverPublicKeyData: approver.signalIdentityPublicKeyData
        ) else {
            throw MobileCloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }
        return verified
    }
}

@MainActor
final class MobileCloudVaultTrustedDeviceVerificationCache {
    struct Key: Hashable, Sendable {
        let uid: String
        let localIdentityKeyID: String
        let localIdentityFingerprint: String
        let trustSnapshotDigest: String
    }

    private struct Entry {
        let devices: [MobileCloudVaultVerifiedTrustedDevice]
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private var completed: [Key: Entry] = [:]
    private var inFlight: [Key: Task<[MobileCloudVaultVerifiedTrustedDevice], Error>] = [:]

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    func value(
        for key: Key,
        now: Date = Date(),
        loader: @escaping @MainActor () async throws -> [MobileCloudVaultVerifiedTrustedDevice]
    ) async throws -> [MobileCloudVaultVerifiedTrustedDevice] {
        completed = completed.filter { $0.value.expiresAt > now }
        if let entry = completed[key] {
            return entry.devices
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task { @MainActor in
            try await loader()
        }
        inFlight[key] = task
        do {
            let devices = try await task.value
            inFlight[key] = nil
            completed[key] = Entry(
                devices: devices,
                expiresAt: Date().addingTimeInterval(ttl)
            )
            return devices
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}

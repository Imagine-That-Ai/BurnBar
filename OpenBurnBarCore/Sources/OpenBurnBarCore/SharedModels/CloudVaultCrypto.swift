import Foundation
#if canImport(Security)
import Security
#endif

public enum CloudVaultCryptoError: LocalizedError, Sendable {
    case invalidKeyLength
    case sealedBoxUnavailable
    case invalidEnvelope
    case invalidPublicKey
    case keychainError(Int)
    case keychainDataMissing

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength:
            return "Cloud vault keys must be 32 bytes."
        case .sealedBoxUnavailable:
            return "Cloud vault encryption did not produce a combined sealed box."
        case .invalidEnvelope:
            return "The encrypted cloud vault envelope is invalid."
        case .invalidPublicKey:
            return "The device public key is invalid."
        case .keychainError(let status):
            return "Cloud vault Keychain operation failed with status \(status)."
        case .keychainDataMissing:
            return "The cloud vault key is missing from the Keychain."
        }
    }
}

public struct CloudVaultAADContext: Codable, Hashable, Sendable {
    public let uid: String
    public let collection: String
    public let docID: String
    public let field: String
    public let schemaVersion: Int
    public let purpose: String

    public init(
        uid: String,
        collection: String,
        docID: String,
        field: String,
        schemaVersion: Int = 2,
        purpose: String? = nil
    ) throws {
        self.uid = try Self.validatedPart(uid)
        self.collection = try Self.validatedPart(collection)
        self.docID = try Self.validatedPart(docID)
        let validatedField = try Self.validatedPart(field)
        self.field = validatedField
        guard schemaVersion >= 2 else { throw CloudVaultCryptoError.invalidEnvelope }
        self.schemaVersion = schemaVersion
        self.purpose = try Self.validatedPart(purpose ?? validatedField)
    }

    public var stringValue: String {
        "\(CloudVaultCrypto.aadContextPrefix)|\(uid)|\(collection)|\(docID)|\(field)|\(schemaVersion)|\(purpose)"
    }

    public var legacyV1StringValue: String {
        "\(CloudVaultCrypto.legacyAADContextPrefix)|\(uid)|\(collection)|\(docID)|\(field)"
    }

    public var data: Data {
        Data(stringValue.utf8)
    }

    public var legacyV1Data: Data {
        Data(legacyV1StringValue.utf8)
    }

    private static func validatedPart(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7f && scalar != "|"
              }) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        return value
    }
}

/// Post-backfill cutover gate for the weaker v1 (global) AAD path.
///
/// **Why it exists.** v2 envelopes bind the ciphertext to the full
/// `uid|collection|docID|field|schemaVersion|purpose` context
/// (``CloudVaultAADContext/stringValue``). The legacy v1 path
/// (``CloudVaultAADContext/legacyV1StringValue``) only binds
/// `uid|collection|docID|field` — weaker domain separation that a backend able to
/// move sealed blobs between schema-equivalent slots could exploit. Reads still
/// accept v1 by default so a pre-backfill migration does not regress.
///
/// **Cutover.** Once the backfill has re-sealed every at-rest record to v2, an
/// operator enables this flag and ``CloudVaultCrypto/aadData(matching:context:)``
/// **refuses** any envelope still carrying the v1 AAD — removing the weaker path
/// for good. Default **off** (accept v1) so it cannot brick pre-backfill reads; a
/// `UserDefaults` override flips it without a code change, exactly like
/// ``ControllerKeyPinEnforcementFlag``.
public enum CloudVaultV1AADRejectionFlag {
    public static let userDefaultsKey = "openburnbar.cloudVault.rejectLegacyV1AAD.enabled"

    /// On by default after the RR-8 cutover; set the UserDefaults key to false
    /// only as an emergency rollback for legacy v1 ciphertext recovery.
    public nonisolated(unsafe) static var defaultEnabled = true

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: userDefaultsKey) != nil {
            return defaults.bool(forKey: userDefaultsKey)
        }
        return defaultEnabled
    }
}

public struct CloudVaultSealedText: Codable, Hashable, Sendable {
    public let schemaVersion: Int?
    public let algorithm: String
    public let keyVersion: Int
    public let nonce: String
    public let ciphertext: String
    public let tag: String
    public let aad: String?

    public init(
        schemaVersion: Int? = nil,
        algorithm: String,
        keyVersion: Int,
        nonce: String,
        ciphertext: String,
        tag: String,
        aad: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyVersion = keyVersion
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.aad = aad
    }
}

public struct CloudVaultBlobEnvelope: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let algorithm: String
    public let keyVersion: Int
    public let plaintextSHA256: String?
    public let plaintextHMAC: String?
    public let integrityHashVersion: Int?
    public let sealedBoxBase64: String
    public let createdAt: Date
    public let aad: String?

    public init(
        schemaVersion: Int = CloudVaultCrypto.currentBlobEnvelopeSchemaVersion,
        algorithm: String = CloudVaultCrypto.aesGCMAlgorithm,
        keyVersion: Int,
        plaintextSHA256: String? = nil,
        plaintextHMAC: String? = nil,
        integrityHashVersion: Int? = CloudVaultCrypto.blobIntegrityHashVersion,
        sealedBoxBase64: String,
        createdAt: Date = Date(),
        aad: String? = CloudVaultCrypto.blobEnvelopeAADContext
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyVersion = keyVersion
        self.plaintextSHA256 = plaintextSHA256
        self.plaintextHMAC = plaintextHMAC
        self.integrityHashVersion = integrityHashVersion
        self.sealedBoxBase64 = sealedBoxBase64
        self.createdAt = createdAt
        self.aad = aad
    }
}

public struct CloudVaultSealedPayload: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let algorithm: String
    public let keyVersion: Int
    public let vaultKeyID: String
    public let sealedBoxBase64: String
    public let aad: String?

    public init(
        schemaVersion: Int = CloudVaultCrypto.currentSealedPayloadSchemaVersion,
        algorithm: String = CloudVaultCrypto.aesGCMAlgorithm,
        keyVersion: Int,
        vaultKeyID: String,
        sealedBoxBase64: String,
        aad: String? = CloudVaultCrypto.sealedPayloadAADContext
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyVersion = keyVersion
        self.vaultKeyID = vaultKeyID
        self.sealedBoxBase64 = sealedBoxBase64
        self.aad = aad
    }
}

public struct CloudVaultDocumentRewrapResult {
    public let data: [String: Any]
    public let changedFields: [String]

    public var changed: Bool {
        changedFields.isEmpty == false
    }

    public init(data: [String: Any], changedFields: [String]) {
        self.data = data
        self.changedFields = changedFields
    }
}

public enum CloudVaultCrypto {
    public static let aesGCMAlgorithm = "AES-256-GCM"
    /// At-rest Signal-envelope constants — the Swift mirror of the shared TS
    /// contract (`SIGNAL_*` in `packages/signal-envelope-contracts`). These name
    /// the Signal HPKE identity seal described by ``CloudVaultSignalEnvelope``.
    /// Production CloudVault writes do not use this scheme yet; the real sealer is
    /// isolated in `OpenBurnBarSignalCore` and remains behind migration flags.
    public static let signalEnvelopeFormatVersion = CloudVaultSignalEnvelopeContract.signalEnvelopeFormatVersion
    public static let signalAtRestMode = CloudVaultSignalEnvelopeContract.signalAtRestMode
    public static let signalAtRestScope = CloudVaultSignalEnvelopeContract.signalAtRestScope
    public static let signalAtRestEncryption = CloudVaultSignalEnvelopeContract.signalAtRestEncryption
    public static let signalAtRestContentKeyLength = CloudVaultSignalEnvelopeContract.signalAtRestContentKeyLength
    /// Version of the at-rest sender-authentication signature construction
    /// (``CloudVaultSignalSenderAuth``). The signed message + domain separator are
    /// defined in `OpenBurnBarSignalAtRest`; bump only on a breaking change.
    public static let signalAtRestSenderAuthVersion = CloudVaultSignalEnvelopeContract.signalAtRestSenderAuthVersion
    public static let signalAtRestSenderAuthDomain = CloudVaultSignalEnvelopeContract.signalAtRestSenderAuthDomain
    public static let aadContextPrefix = "OpenBurnBar-CloudVault-aad-v2"
    public static let legacyAADContextPrefix = "OpenBurnBar-CloudVault-aad-v1"
    public static let currentSealedTextSchemaVersion = 2
    public static let currentBlobEnvelopeSchemaVersion = 2
    public static let blobEnvelopeAADContext = "OpenBurnBar-CloudVaultBlob-v2"
    public static let blobIntegrityHashVersion = 1
    public static let sessionBodyHashVersion = 2
    public static let sessionChunkHashVersion = 2
    public static let projectMemoryContentHashVersion = 2
    public static let currentSealedPayloadSchemaVersion = 2
    public static let sealedPayloadAADContext = "OpenBurnBar-CloudVaultSealedPayload-v2"
    public static let roamingProfileAADDomain = "OpenBurnBar-RoamingProfile-v1"
    public static let tokenHashVersion = 1
    public static let semanticHashVersion = 1
    public static let currentKeyVersion = 1
    public static let recoverySalt = Data("OpenBurnBar-Recovery-Salt-v1".utf8)
    public static let recoveryWrapInfo = Data("OpenBurnBar-Recovery-Wrap-v1".utf8)

    #if canImport(Security)
    // Test-only injection seam: production never reassigns this (stays the pure C `SecRandomCopyBytes`); only one XCTest swaps a stub in and restores the original via `defer` within a single synchronous test, so there is no concurrent mutation.
    nonisolated(unsafe) internal static var secureRandomCopyBytes: (SecRandomRef?, Int, UnsafeMutableRawPointer) -> OSStatus = SecRandomCopyBytes
    #endif

    private static func randomBytes(count: Int) throws -> [UInt8] {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return secureRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else { throw CloudVaultCryptoError.keychainError(Int(status)) }
        return bytes
        #else
        do {
            return Array(try PlatformCrypto.secureRandomBytes(count: count))
        } catch {
            throw CloudVaultCryptoError.keychainError(-1)
        }
        #endif
    }

    public static func generateVaultKey() throws -> Data {
        Data(try randomBytes(count: 32))
    }

    static func generateDocumentRewrapNonce() throws -> Data {
        Data(try randomBytes(count: 12))
    }

    public static func vaultKeyID(for keyData: Data) throws -> String {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return "v1_" + String(sha256Hex(keyData).prefix(32))
    }

    public static func roamingProfileAADContext(uid: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: uid,
            collection: "roaming_profile",
            docID: "current",
            field: "sealedPayload",
            schemaVersion: currentSealedPayloadSchemaVersion,
            purpose: roamingProfileAADDomain
        )
    }

    public static func generateRecoveryKey() throws -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")
        let bytes = try randomBytes(count: 35)
        let characters = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: characters.count, by: 7)
            .map { String(characters[$0..<min($0 + 7, characters.count)]) }
            .joined(separator: "-")
    }

    public static func sealText(
        _ text: String,
        keyData: Data,
        keyVersion: Int = currentKeyVersion,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> CloudVaultSealedText {
        let plaintext = Data(text.utf8)
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: plaintext,
            keyData: keyData,
            authenticating: aadContext?.data ?? Data()
        )
        return try sealedText(from: sealed, keyVersion: keyVersion, aadContext: aadContext)
    }

    public static func openText(
        _ envelope: CloudVaultSealedText,
        keyData: Data,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> String {
        let data = try open(envelope, keyData: keyData, aadContext: aadContext)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        return text
    }

    public static func sealBlob(
        _ data: Data,
        keyData: Data,
        keyVersion: Int = currentKeyVersion,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> CloudVaultBlobEnvelope {
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: data,
            keyData: keyData,
            authenticating: aadContext?.data ?? Data()
        )
        return CloudVaultBlobEnvelope(
            schemaVersion: currentBlobEnvelopeSchemaVersion,
            keyVersion: keyVersion,
            plaintextHMAC: try blobPlaintextHMAC(data, keyData: keyData),
            integrityHashVersion: blobIntegrityHashVersion,
            sealedBoxBase64: sealed.combined.base64EncodedString(),
            aad: aadContext?.stringValue ?? blobEnvelopeAADContext
        )
    }

    public static func openBlob(
        _ envelope: CloudVaultBlobEnvelope,
        keyData: Data,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> Data {
        guard envelope.algorithm == aesGCMAlgorithm else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        guard let combined = Data(base64Encoded: envelope.sealedBoxBase64) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        let plaintext: Data
        switch envelope.schemaVersion {
        case 1:
            plaintext = try PlatformCrypto.openAESGCM(combined: combined, keyData: keyData)
            guard let plaintextSHA256 = envelope.plaintextSHA256,
                  sha256Hex(plaintext) == plaintextSHA256 else {
                throw CloudVaultCryptoError.invalidEnvelope
            }
        case currentBlobEnvelopeSchemaVersion:
            if envelope.aad == blobEnvelopeAADContext {
                plaintext = try PlatformCrypto.openAESGCM(combined: combined, keyData: keyData)
            } else {
                guard let aadContext else {
                    throw CloudVaultCryptoError.invalidEnvelope
                }
                plaintext = try PlatformCrypto.openAESGCM(
                    combined: combined,
                    keyData: keyData,
                    authenticating: try aadData(matching: envelope.aad, context: aadContext)
                )
            }
            guard envelope.integrityHashVersion == blobIntegrityHashVersion,
                  let plaintextHMAC = envelope.plaintextHMAC,
                  try blobPlaintextHMAC(plaintext, keyData: keyData) == plaintextHMAC else {
                throw CloudVaultCryptoError.invalidEnvelope
            }
        default:
            throw CloudVaultCryptoError.invalidEnvelope
        }
        return plaintext
    }

    public static func blobPlaintextHMAC(_ data: Data, keyData: Data) throws -> String {
        try keyedHMACHex(data, keyData: keyData, purpose: "blob-integrity")
    }

    public static func sessionBodyHash(_ data: Data, keyData: Data) throws -> String {
        try keyedHMACHex(data, keyData: keyData, purpose: "session-body")
    }

    public static func sessionBodyHash(_ text: String, keyData: Data) throws -> String {
        try sessionBodyHash(Data(text.utf8), keyData: keyData)
    }

    public static func expectedSessionBodyHash(_ data: Data, keyData: Data, bodyHashVersion: Int) throws -> String {
        switch bodyHashVersion {
        case sessionBodyHashVersion:
            return try sessionBodyHash(data, keyData: keyData)
        case 0, 1:
            return sha256Hex(data)
        default:
            throw CloudVaultCryptoError.invalidEnvelope
        }
    }

    public static func sessionChunkHash(_ chunk: String, keyData: Data) throws -> String {
        try keyedHMACHex(Data(chunk.utf8), keyData: keyData, purpose: "session-chunk")
    }

    public static func projectMemoryContentHash(_ data: Data, keyData: Data) throws -> String {
        try keyedHMACHex(data, keyData: keyData, purpose: "project-memory-content")
    }

    public static func expectedBlobIntegrityHash(_ data: Data, envelope: CloudVaultBlobEnvelope, keyData: Data) throws -> String {
        if envelope.schemaVersion >= currentBlobEnvelopeSchemaVersion {
            return try blobPlaintextHMAC(data, keyData: keyData)
        }
        return sha256Hex(data)
    }

    public static func sealPayload(
        _ data: Data,
        keyData: Data,
        vaultKeyID: String,
        keyVersion: Int = currentKeyVersion,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> CloudVaultSealedPayload {
        let draft = CloudVaultSealedPayload(
            keyVersion: keyVersion,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: "",
            aad: aadContext?.stringValue ?? sealedPayloadAADContext
        )
        let combined = try PlatformCrypto.sealAESGCM(
            plaintext: data,
            keyData: keyData,
            authenticating: sealedPayloadAAD(for: draft, aadContext: aadContext)
        )
        return CloudVaultSealedPayload(
            schemaVersion: currentSealedPayloadSchemaVersion,
            keyVersion: keyVersion,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: combined.base64EncodedString(),
            aad: draft.aad
        )
    }

    public static func openPayload(
        _ envelope: CloudVaultSealedPayload,
        keyData: Data,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> Data {
        guard envelope.algorithm == aesGCMAlgorithm,
              envelope.vaultKeyID == (try vaultKeyID(for: keyData)),
              let combined = Data(base64Encoded: envelope.sealedBoxBase64) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        switch envelope.schemaVersion {
        case 1:
            return try PlatformCrypto.openAESGCM(combined: combined, keyData: keyData)
        case currentSealedPayloadSchemaVersion:
            if envelope.aad == sealedPayloadAADContext {
                return try PlatformCrypto.openAESGCM(
                    combined: combined,
                    keyData: keyData,
                    authenticating: sealedPayloadAAD(for: envelope, aadContext: nil)
                )
            }
            guard let aadContext else {
                throw CloudVaultCryptoError.invalidEnvelope
            }
            return try PlatformCrypto.openAESGCM(
                combined: combined,
                keyData: keyData,
                authenticating: try aadData(matching: envelope.aad, context: aadContext)
            )
        default:
            throw CloudVaultCryptoError.invalidEnvelope
        }
    }

    public static func sealRoamingProfile(
        _ payload: RoamingProfilePayload,
        keyData: Data,
        uid: String,
        keyVersion: Int = currentKeyVersion
    ) throws -> CloudVaultSealedPayload {
        let validated = try payload.validatedForCloudVaultSeal()
        let data = try CloudVaultJSON.roamingProfileEncoder.encode(validated)
        return try sealPayload(
            data,
            keyData: keyData,
            vaultKeyID: vaultKeyID(for: keyData),
            keyVersion: keyVersion,
            aadContext: roamingProfileAADContext(uid: uid)
        )
    }

    public static func openRoamingProfile(
        _ envelope: CloudVaultSealedPayload,
        keyData: Data,
        uid: String
    ) throws -> RoamingProfilePayload {
        let data = try openPayload(
            envelope,
            keyData: keyData,
            aadContext: roamingProfileAADContext(uid: uid)
        )
        let payload = try CloudVaultJSON.roamingProfileDecoder.decode(RoamingProfilePayload.self, from: data)
        return try payload.validatedForCloudVaultSeal()
    }

    public static func roamingProfileCloudDocument(
        payload: RoamingProfilePayload,
        sealedPayload: CloudVaultSealedPayload,
        uid: String
    ) -> [String: Any] {
        [
            "uid": uid,
            "schemaVersion": 1,
            "payloadSchemaVersion": payload.schemaVersion,
            "sourceDeviceID": payload.sourceDeviceID,
            "updatedAt": payload.updatedAt,
            "sealedPayload": sealedPayloadDictionary(sealedPayload)
        ]
    }

    public static func sealedPayloadDictionary(_ envelope: CloudVaultSealedPayload) -> [String: Any] {
        var dict: [String: Any] = [
            "schemaVersion": envelope.schemaVersion,
            "algorithm": envelope.algorithm,
            "keyVersion": envelope.keyVersion,
            "vaultKeyID": envelope.vaultKeyID,
            "sealedBoxBase64": envelope.sealedBoxBase64
        ]
        if let aad = envelope.aad {
            dict["aad"] = aad
        }
        return dict
    }

    public static func sealedPayload(from raw: Any?) -> CloudVaultSealedPayload? {
        guard let dict = raw as? [String: Any],
              let schemaVersion = dict["schemaVersion"] as? Int,
              let algorithm = dict["algorithm"] as? String,
              let keyVersion = dict["keyVersion"] as? Int,
              let vaultKeyID = dict["vaultKeyID"] as? String,
              let sealedBoxBase64 = dict["sealedBoxBase64"] as? String else {
            return nil
        }
        return CloudVaultSealedPayload(
            schemaVersion: schemaVersion,
            algorithm: algorithm,
            keyVersion: keyVersion,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: sealedBoxBase64,
            aad: dict["aad"] as? String
        )
    }

    public static func firestoreDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        return dict
    }

    public static func decodeSealedText(from raw: Any?) -> CloudVaultSealedText? {
        decodeEnvelope(raw, as: CloudVaultSealedText.self)
    }

    public static func decodeBlobEnvelope(from raw: Any?) -> CloudVaultBlobEnvelope? {
        decodeEnvelope(raw, as: CloudVaultBlobEnvelope.self)
    }

    static func decodeBlobEnvelopeForDocumentRewrap(_ raw: [String: Any]) -> CloudVaultBlobEnvelope? {
        var cryptographicMembers = raw
        if cryptographicMembers["createdAt"] != nil {
            // Firestore Timestamp is intentionally opaque to the crypto layer.
            // Supply a decode-only placeholder; the caller reapplies the exact
            // original object after resealing.
            cryptographicMembers["createdAt"] = 0
        }
        return decodeBlobEnvelope(from: cryptographicMembers)
    }

    public static func rewrapCloudVaultDocument(
        _ data: [String: Any],
        uid: String,
        collection: String,
        docID: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int? = nil,
        rotationJobId: String? = nil
    ) throws -> CloudVaultDocumentRewrapResult {
        guard try vaultKeyID(for: newKeyData) == newVaultKeyID else {
            throw CloudVaultCryptoError.invalidEnvelope
        }

        return try CloudVaultDocumentRewrapDomainCoreAdapter.rewrap(
            data: data,
            uid: uid,
            collection: collection,
            docID: docID,
            oldKeyData: oldKeyData,
            newKeyData: newKeyData,
            newVaultKeyID: newVaultKeyID,
            vaultGeneration: vaultGeneration,
            rotationJobID: rotationJobId
        ) { noncePlan in
            try rewrapCloudVaultDocumentLegacy(
                data,
                uid: uid,
                collection: collection,
                docID: docID,
                oldKeyData: oldKeyData,
                newKeyData: newKeyData,
                newVaultKeyID: newVaultKeyID,
                vaultGeneration: vaultGeneration,
                rotationJobID: rotationJobId,
                noncePlan: noncePlan
            )
        }
    }

    private static func rewrapCloudVaultDocumentLegacy(
        _ data: [String: Any],
        uid: String,
        collection: String,
        docID: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int?,
        rotationJobID: String?,
        noncePlan: [CloudVaultDocumentRewrapNonce]
    ) throws -> CloudVaultDocumentRewrapResult {

        var updated = data
        var changedFields: [String] = []
        var nonceIndex = 0

        func nextNonce(for field: String) throws -> Data {
            guard nonceIndex < noncePlan.count,
                  noncePlan[nonceIndex].fieldName == field else {
                throw CloudVaultCryptoError.invalidEnvelope
            }
            defer { nonceIndex += 1 }
            return noncePlan[nonceIndex].bytes
        }

        for field in data.keys.sorted() {
            guard let rawMap = data[field] as? [String: Any] else { continue }
            let context = try CloudVaultAADContext(uid: uid, collection: collection, docID: docID, field: field)

            if let envelope = sealedPayload(from: rawMap) {
                guard envelope.vaultKeyID != newVaultKeyID else { continue }
                let plaintext = try openPayloadForRewrap(envelope, keyData: oldKeyData, aadContext: context)
                let resealed = try sealPayload(
                    plaintext,
                    keyData: newKeyData,
                    vaultKeyID: newVaultKeyID,
                    aadContext: context,
                    nonce: try nextNonce(for: field)
                )
                updated[field] = try firestoreDictionary(resealed)
                applyVaultKeyCompanionUpdates(
                    to: &updated,
                    field: field,
                    newVaultKeyID: newVaultKeyID
                )
                changedFields.append(field)
                continue
            }

            if let envelope = decodeSealedText(from: rawMap) {
                let plaintext = try openTextForRewrap(envelope, keyData: oldKeyData, aadContext: context)
                let resealed = try sealText(
                    plaintext,
                    keyData: newKeyData,
                    aadContext: context,
                    nonce: try nextNonce(for: field)
                )
                updated[field] = try firestoreDictionary(resealed)
                changedFields.append(field)
                continue
            }

            if let envelope = decodeBlobEnvelopeForDocumentRewrap(rawMap) {
                let plaintext = try openBlobForRewrap(envelope, keyData: oldKeyData, aadContext: context)
                let resealed = try sealBlob(
                    plaintext,
                    keyData: newKeyData,
                    aadContext: context,
                    nonce: try nextNonce(for: field)
                )
                var resealedMap = try firestoreDictionary(resealed)
                if rawMap.keys.contains("createdAt") {
                    resealedMap["createdAt"] = rawMap["createdAt"]
                }
                updated[field] = resealedMap
                changedFields.append(field)
            }
        }

        guard nonceIndex == noncePlan.count else {
            throw CloudVaultCryptoError.invalidEnvelope
        }

        if changedFields.isEmpty == false {
            if let vaultGeneration {
                updated["vaultGeneration"] = vaultGeneration
            }
            if let rotationJobID {
                updated["rewrapJobId"] = rotationJobID
            }
        }

        return CloudVaultDocumentRewrapResult(data: updated, changedFields: changedFields)
    }

    public static func signalEnvelopeDictionary(_ envelope: CloudVaultSignalEnvelope) throws -> [String: Any] {
        let data = try JSONEncoder().encode(envelope)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        return dict
    }

    public static func signalEnvelope(from raw: Any?) -> CloudVaultSignalEnvelope? {
        guard let dict = raw as? [String: Any],
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return nil
        }
        return try? JSONDecoder().decode(CloudVaultSignalEnvelope.self, from: data)
    }

    public static func tokenHashes(for text: String, keyData: Data, limit: Int = 250) throws -> [String] {
        let key = try searchKey(from: keyData)
        let terms = normalizedTokens(from: text)
        return tokenHashes(forTerms: terms, key: key, limit: limit)
    }

    public static func searchIndexTokenHashes(for text: String, keyData: Data, limit: Int = 250) throws -> [String] {
        let key = try searchKey(from: keyData)
        let tokens = uniqueNormalizedTokens(from: text)
        var terms = tokens
        terms.append(contentsOf: searchIndexPrefixTerms(from: tokens))
        terms.append(contentsOf: exactPhraseTerms(from: text))
        return tokenHashes(forTerms: terms, key: key, limit: limit)
    }

    public static func searchQueryTokenHashes(for text: String, keyData: Data, limit: Int = 250) throws -> [String] {
        let key = try searchKey(from: keyData)
        let tokens = uniqueNormalizedTokens(from: text)
        var terms = tokens
        terms.append(contentsOf: tokens.compactMap(searchQueryPrefixTerm))
        terms.append(contentsOf: exactPhraseTerms(from: text))
        return tokenHashes(forTerms: terms, key: key, limit: limit)
    }

    /// Deterministic, opaque Firestore document id for a project-memory snapshot.
    ///
    /// Replaces the name-derived slug doc id so the server (and anyone with raw
    /// Firestore read) learns nothing about the project: it stores only ciphertext
    /// plus this trapdoor. Same slug + same vault key always hash to the same id, so
    /// upsert/get idempotency is preserved; a different vault key yields a different
    /// id. The `pm_` + 32-hex output satisfies the server's `requiredIdentifier`
    /// `[a-z0-9_-]` filter unchanged. Mirrors the `tokenHashes`/`searchKey`
    /// HKDF<SHA256> → HMAC<SHA256> → hex recipe.
    public static func projectMemoryDocID(forSlug slug: String, keyData: Data) throws -> String {
        let key = try projectMemoryDocIDKey(from: keyData)
        let mac = try PlatformCrypto.hmacSHA256(Data(slug.utf8), keyData: PlatformCrypto.symmetricKeyData(key))
        return "pm_" + mac.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Vault-keyed dedup hash for a Pensieve knowledge chunk's plaintext.
    ///
    /// Equality-only idempotency key the server can compare without ever learning
    /// the plaintext (and without the cleartext-SHA-256 oracle the legacy
    /// `contentHash` exposed). Per-user HKDF derivation means two users with the
    /// same plaintext produce different hashes. Full HMAC-SHA256 digest (64 hex),
    /// matching `requireHexDigest`. Derivation parity:
    /// `HKDF<SHA256>(vaultKey, salt: ∅, info: "pensieve-dedup:content") → HMAC<SHA256>(plaintext)`.
    public static func pensieveDedupHash(_ plaintext: String, keyData: Data) throws -> String {
        let key = try pensieveDedupKey(from: keyData, label: "content")
        return try PlatformCrypto.hmacSHA256Hex(
            Data(plaintext.utf8),
            keyData: PlatformCrypto.symmetricKeyData(key)
        )
    }

    /// Vault-keyed HMAC of a Pensieve source slug — the opaque filter column that
    /// replaces the cleartext `sourceSlug`. Full HMAC-SHA256 digest (64 hex).
    /// Derivation parity:
    /// `HKDF<SHA256>(vaultKey, salt: ∅, info: "pensieve-dedup:slug") → HMAC<SHA256>(slug)`.
    public static func pensieveSlugHmac(_ slug: String, keyData: Data) throws -> String {
        let key = try pensieveDedupKey(from: keyData, label: "slug")
        return try PlatformCrypto.hmacSHA256Hex(
            Data(slug.utf8),
            keyData: PlatformCrypto.symmetricKeyData(key)
        )
    }

    /// Deterministic, opaque Firestore document id for a subscription topic.
    ///
    /// Cloaks the subscription graph: the legacy doc id was the human-readable
    /// `agentURI:topicID` (with `/`,`:`→`_`), letting the server enumerate exactly
    /// which agents a user follows. This replaces it with a vault-keyed HMAC of
    /// `"agentURI:topicID"` so the same `(agentURI, topicID, vaultKey)` always
    /// hashes to the same id (unsubscribe-by-id and upsert idempotency survive)
    /// while a different vault key — or a different agent — yields an unrelated id.
    /// The `sub_` + 32-hex output satisfies Firestore's `[a-z0-9_-]` doc-id rules
    /// unchanged. Mirrors `pensieveSlugHmac`/`projectMemoryDocID`:
    /// `HKDF<SHA256>(vaultKey, salt: ∅, info: "subscription-topic") → HMAC<SHA256>("agentURI:topicID")`.
    public static func subscriptionDocID(agentURI: String, topicID: String, keyData: Data) throws -> String {
        let key = try subscriptionDocIDKey(from: keyData)
        let mac = try PlatformCrypto.hmacSHA256(
            Data("\(agentURI):\(topicID)".utf8),
            keyData: PlatformCrypto.symmetricKeyData(key)
        )
        return "sub_" + mac.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func tokenHashes(forTerms terms: [String], key: PlatformSymmetricKey, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var hashes: [String] = []
        let keyData = PlatformCrypto.symmetricKeyData(key)
        for term in terms where seen.insert(term).inserted {
            guard let mac = try? PlatformCrypto.hmacSHA256(Data(term.utf8), keyData: keyData) else { continue }
            hashes.append(mac.prefix(16).map { String(format: "%02x", $0) }.joined())
            if hashes.count >= limit { break }
        }
        return hashes
    }

    private static func uniqueNormalizedTokens(from text: String) -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        for token in normalizedTokens(from: text) where seen.insert(token).inserted {
            tokens.append(token)
        }
        return tokens
    }

    private static func searchIndexPrefixTerms(from tokens: [String]) -> [String] {
        tokens.flatMap { token -> [String] in
            let characters = Array(token)
            guard characters.count >= 4 else { return [] }
            let maxPrefixLength = min(16, characters.count - 1)
            guard maxPrefixLength >= 3 else { return [] }
            return (3...maxPrefixLength).map { length in
                "prefix:v1:" + String(characters.prefix(length))
            }
        }
    }

    private static func searchQueryPrefixTerm(from token: String) -> String? {
        guard token.count >= 3 else { return nil }
        return "prefix:v1:\(String(token.prefix(16)))"
    }

    private static func exactPhraseTerms(from text: String) -> [String] {
        let tokens = exactPhraseTokens(from: text)
        guard tokens.count >= 2 else { return [] }
        var terms: [String] = []
        for index in tokens.indices {
            if index + 1 < tokens.count {
                terms.append("phrase:v1:" + tokens[index...(index + 1)].joined(separator: "_"))
            }
            if index + 2 < tokens.count {
                terms.append("phrase:v1:" + tokens[index...(index + 2)].joined(separator: "_"))
            }
        }
        return terms
    }

    /// Produces keyed semantic-search buckets from plaintext before it is encrypted.
    ///
    /// This is a searchable-symmetric-encryption style trapdoor: the server can
    /// intersect opaque buckets and rank candidate chunks, but it never receives
    /// plaintext tokens, embeddings, or the vault key. The sketch intentionally
    /// favors bounded, stable recall over model-specific vectors so every client
    /// can produce identical hashes offline.
    public static func semanticHashes(for text: String, keyData: Data, limit: Int = 24) throws -> [String] {
        let tokens = exactPhraseTokens(from: text)
        guard tokens.isEmpty == false, limit > 0 else { return [] }

        let key = try semanticSearchKey(from: keyData)
        let features = semanticFeatures(from: tokens)
        guard features.isEmpty == false else { return [] }

        let dimensions = 64
        var accumulator = [Double](repeating: 0, count: dimensions)
        let semanticKeyData = PlatformCrypto.symmetricKeyData(key)
        for feature in features {
            let mac = try PlatformCrypto.hmacSHA256(Data(feature.name.utf8), keyData: semanticKeyData)
            let bytes = Array(mac)
            let index = ((Int(bytes[0]) << 8) | Int(bytes[1])) % dimensions
            let sign = (bytes[2] & 1) == 0 ? 1.0 : -1.0
            accumulator[index] += sign * feature.weight
        }

        var hashes: [String] = []
        var seen = Set<String>()
        func appendBucket(_ bucket: String) {
            guard hashes.count < limit else { return }
            guard let mac = try? PlatformCrypto.hmacSHA256(Data(bucket.utf8), keyData: semanticKeyData) else { return }
            let hash = mac.prefix(16).map { String(format: "%02x", $0) }.joined()
            if seen.insert(hash).inserted {
                hashes.append(hash)
            }
        }

        let bandSize = 8
        let bandCount = dimensions / bandSize
        for band in 0..<bandCount {
            var value = 0
            for bit in 0..<bandSize {
                let index = band * bandSize + bit
                if accumulator[index] >= 0 {
                    value |= (1 << bit)
                }
            }
            appendBucket("simhash:v1:band:\(band):\(String(format: "%02x", value))")
        }

        for feature in features.prefix(max(0, limit - hashes.count)) {
            appendBucket("feature:v1:\(feature.name)")
        }

        return hashes
    }

    public static func normalizedTokens(from text: String) -> [String] {
        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && searchStopwords.contains($0) == false }
    }

    public static func wrapVaultKey(_ keyData: Data, recipientPublicKey: Data) throws -> Data {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        guard let recipientKey = try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: recipientPublicKey) else {
            throw CloudVaultCryptoError.invalidPublicKey
        }
        let ephemeralKey = PlatformCrypto.p256KeyAgreementPrivateKey()
        let sharedSecret = try PlatformCrypto.p256KeyAgreementSharedSecret(privateKey: ephemeralKey, publicKey: recipientKey)
        let wrappingKey = try PlatformCrypto.deriveHKDFSHA256Key(
            sharedSecret: sharedSecret,
            salt: Data(),
            info: Data("OpenBurnBar-Escrow-v1".utf8),
            outputByteCount: 32
        )
        let combined = try PlatformCrypto.sealAESGCM(plaintext: keyData, key: wrappingKey)
        return ephemeralKey.publicKey.x963Representation + combined
    }

    public static func unwrapVaultKey(_ ciphertext: Data, privateKey: PlatformP256KeyAgreementPrivateKey) throws -> Data {
        guard ciphertext.count > 65 else { throw CloudVaultCryptoError.invalidEnvelope }
        let publicKeyData = ciphertext.prefix(65)
        let sealedBoxData = ciphertext.suffix(from: 65)
        guard let publicKey = try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: Data(publicKeyData)) else {
            throw CloudVaultCryptoError.invalidPublicKey
        }
        let sharedSecret = try PlatformCrypto.p256KeyAgreementSharedSecret(privateKey: privateKey, publicKey: publicKey)
        let wrappingKey = try PlatformCrypto.deriveHKDFSHA256Key(
            sharedSecret: sharedSecret,
            salt: Data(),
            info: Data("OpenBurnBar-Escrow-v1".utf8),
            outputByteCount: 32
        )
        let keyData = try PlatformCrypto.openAESGCM(combined: Data(sealedBoxData), key: wrappingKey)
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return keyData
    }

    public static func deriveRecoveryWrappingKey(from recoveryKey: String) throws -> PlatformSymmetricKey {
        let normalized = normalizedRecoveryKey(recoveryKey)
        guard normalized.count >= 20 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: Data(normalized.utf8),
            salt: recoverySalt,
            info: recoveryWrapInfo,
            outputByteCount: 32
        )
    }

    public static func wrapVaultKeyWithRecovery(
        vaultKey: Data,
        recoveryKey: String
    ) throws -> (wrappedVaultKeyBase64: String, verificationHash: String) {
        guard vaultKey.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        let wrappingKey = try deriveRecoveryWrappingKey(from: recoveryKey)
        let combined = try PlatformCrypto.sealAESGCM(plaintext: vaultKey, key: wrappingKey)
        return (
            wrappedVaultKeyBase64: combined.base64EncodedString(),
            verificationHash: recoveryVerificationHash(forDerivedKey: wrappingKey)
        )
    }

    public static func unwrapVaultKeyWithRecovery(
        wrappedVaultKeyBase64: String,
        recoveryKey: String
    ) throws -> Data {
        guard let combined = Data(base64Encoded: wrappedVaultKeyBase64) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        let keyData = try PlatformCrypto.openAESGCM(
            combined: combined,
            key: try deriveRecoveryWrappingKey(from: recoveryKey)
        )
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return keyData
    }

    public static func recoveryVerificationHash(for recoveryKey: String) throws -> String {
        try recoveryVerificationHash(forDerivedKey: deriveRecoveryWrappingKey(from: recoveryKey))
    }

    public static func sha256Hex(_ data: Data) -> String {
        PlatformCrypto.sha256Hex(data)
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    private static func recoveryVerificationHash(forDerivedKey key: PlatformSymmetricKey) -> String {
        key.withUnsafeBytes { bytes in
            sha256Hex(Data(bytes))
        }
    }

    private static func normalizedRecoveryKey(_ recoveryKey: String) -> String {
        recoveryKey
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func symmetricKey(from data: Data) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.symmetricKey(data: data)
    }

    private static func keyedHMACHex(_ data: Data, keyData: Data, purpose: String) throws -> String {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        let key = try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: keyData,
            salt: Data("OpenBurnBar-CloudVault-HMAC-Salt-v1".utf8),
            info: Data("OpenBurnBar-CloudVault-HMAC-v1|\(purpose)".utf8),
            outputByteCount: 32
        )
        return PlatformCrypto.hexString(try PlatformCrypto.hmacSHA256(data, keyData: PlatformCrypto.symmetricKeyData(key)))
    }

    private static func sealedPayloadAAD(for envelope: CloudVaultSealedPayload, aadContext: CloudVaultAADContext?) -> Data {
        if let aadContext {
            return aadContext.data
        }
        return Data("\(sealedPayloadAADContext)|\(envelope.algorithm)|keyVersion=\(envelope.keyVersion)|vaultKeyID=\(envelope.vaultKeyID)".utf8)
    }

    private static func aadData(
        matching envelopeAAD: String?,
        context: CloudVaultAADContext,
        rejectLegacyV1: Bool = CloudVaultV1AADRejectionFlag.isEnabled()
    ) throws -> Data {
        if envelopeAAD == context.stringValue {
            return context.data
        }
        if envelopeAAD == context.legacyV1StringValue {
            // Post-backfill cutover: once enabled, the weaker v1 (global) AAD
            // domain-separation path is removed and any envelope still carrying it
            // is refused (fail closed) rather than silently downgraded.
            if rejectLegacyV1 {
                throw CloudVaultCryptoError.invalidEnvelope
            }
            return context.legacyV1Data
        }
        throw CloudVaultCryptoError.invalidEnvelope
    }

    /// Test seam over ``aadData(matching:context:rejectLegacyV1:)`` so the v1
    /// accept/reject cutover is verifiable without mutating process-wide
    /// `UserDefaults`. Never called from production paths.
    internal static func resolveAADForTesting(
        envelopeAAD: String?,
        context: CloudVaultAADContext,
        rejectLegacyV1: Bool
    ) throws -> Data {
        try aadData(matching: envelopeAAD, context: context, rejectLegacyV1: rejectLegacyV1)
    }

    private static func searchKey(from data: Data) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: data,
            salt: Data("OpenBurnBar-CloudSearch-Salt-v1".utf8),
            info: Data("OpenBurnBar-CloudSearch-TokenHash-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func semanticSearchKey(from data: Data) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: data,
            salt: Data("OpenBurnBar-CloudSearch-Semantic-Salt-v1".utf8),
            info: Data("OpenBurnBar-CloudSearch-SemanticHash-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func projectMemoryDocIDKey(from data: Data) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: data,
            salt: Data("OpenBurnBar-DocID-Salt-v1".utf8),
            info: Data("OpenBurnBar-ProjectMemory-DocID-v1".utf8),
            outputByteCount: 32
        )
    }

    /// Per-user Pensieve dedup subkey. Mirrors the TS device derivation the server
    /// test pins (`knowledgeMemoryDedupHash.test.ts`): empty HKDF salt, info
    /// `"pensieve-dedup:<label>"` where `label` is `content` or `slug`.
    private static func pensieveDedupKey(from data: Data, label: String) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: data,
            salt: Data(),
            info: Data("pensieve-dedup:\(label)".utf8),
            outputByteCount: 32
        )
    }

    /// Per-user subscription-graph doc-id subkey. Empty HKDF salt, info
    /// `"subscription-topic"` — the byte-for-byte derivation the Kotlin mirror
    /// (`AgentSubscriptionTopicStore.documentID`) must reproduce so the same
    /// `(agentURI, topicID, vaultKey)` yields an identical opaque doc id on iOS
    /// and Android.
    private static func subscriptionDocIDKey(from data: Data) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: data,
            salt: Data(),
            info: Data("subscription-topic".utf8),
            outputByteCount: 32
        )
    }

    private struct SemanticFeature {
        let name: String
        let weight: Double
    }

    private static let searchStopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "how", "what", "where",
        "when", "why", "are", "was", "were", "you", "your", "have", "has", "had",
        "into", "onto", "can", "could", "should", "would"
    ]

    private static func exactPhraseTokens(from text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                (token.count >= 2 || token == "x") && searchStopwords.contains(token) == false
            }
    }

    private static func semanticFeatures(from tokens: [String]) -> [SemanticFeature] {
        var features: [SemanticFeature] = []
        var seen = Set<String>()

        func append(_ name: String, weight: Double) {
            guard name.isEmpty == false, seen.insert(name).inserted else { return }
            features.append(SemanticFeature(name: name, weight: weight))
        }

        for concept in semanticConcepts(from: tokens) {
            append("concept:\(concept)", weight: 3.2)
        }

        for token in tokens {
            append("token:\(token)", weight: 2.4)
            let stem = simpleSemanticStem(token)
            if stem != token {
                append("stem:\(stem)", weight: 1.8)
            }
            if token.count >= 5 {
                append("prefix:\(String(token.prefix(5)))", weight: 0.8)
            }
        }

        if tokens.count >= 2 {
            for index in 0..<(tokens.count - 1) {
                append("bigram:\(tokens[index])_\(tokens[index + 1])", weight: 1.3)
            }
        }
        return features
    }

    private static func semanticConcepts(from tokens: [String]) -> [String] {
        var concepts: [String] = []
        var seen = Set<String>()

        func append(_ concept: String) {
            guard seen.insert(concept).inserted else { return }
            concepts.append(concept)
        }

        for token in tokens {
            switch token {
            case "x", "twitter", "tweets", "tweet", "xcom":
                append("x-platform")
                append("social-platform")
            case "ads", "ad", "advertising", "advertise", "campaign", "campaigns", "marketing":
                append("advertising")
            case "api", "apis", "endpoint", "endpoints", "sdk", "webhook", "webhooks", "integration", "integrations":
                append("api-integration")
            case "oauth", "auth", "login", "signin", "token", "tokens", "credential", "credentials":
                append("authentication")
            case "billing", "invoice", "invoices", "pricing", "price", "cost", "spend", "quota", "usage":
                append("billing-usage")
            case "backup", "sync", "mirror", "cache", "restore", "download", "upload":
                append("backup-sync")
            default:
                break
            }
        }

        if concepts.contains("x-platform") && concepts.contains("advertising") {
            append("x-ads")
        }
        if concepts.contains("advertising") && concepts.contains("api-integration") {
            append("ads-api")
        }
        if concepts.contains("x-platform") && concepts.contains("api-integration") {
            append("x-api")
        }
        return concepts
    }

    private static func simpleSemanticStem(_ token: String) -> String {
        let suffixes = ["ization", "ations", "ation", "ments", "ment", "ingly", "edly", "ing", "ies", "ied", "ers", "er", "ed", "s"]
        for suffix in suffixes where token.count > suffix.count + 3 && token.hasSuffix(suffix) {
            let stem = String(token.dropLast(suffix.count))
            if suffix == "ies" || suffix == "ied" {
                return stem + "y"
            }
            return stem
        }
        return token
    }

    private static func decodeEnvelope<T: Decodable>(_ raw: Any?, as type: T.Type) -> T? {
        guard let dict = raw as? [String: Any],
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func openTextForRewrap(
        _ envelope: CloudVaultSealedText,
        keyData: Data,
        aadContext: CloudVaultAADContext
    ) throws -> String {
        if (envelope.schemaVersion ?? 1) >= currentSealedTextSchemaVersion {
            return try openText(envelope, keyData: keyData, aadContext: aadContext)
        }
        return try openText(envelope, keyData: keyData)
    }

    private static func openBlobForRewrap(
        _ envelope: CloudVaultBlobEnvelope,
        keyData: Data,
        aadContext: CloudVaultAADContext
    ) throws -> Data {
        if envelope.schemaVersion >= currentBlobEnvelopeSchemaVersion,
           envelope.aad != blobEnvelopeAADContext {
            return try openBlob(envelope, keyData: keyData, aadContext: aadContext)
        }
        return try openBlob(envelope, keyData: keyData)
    }

    private static func openPayloadForRewrap(
        _ envelope: CloudVaultSealedPayload,
        keyData: Data,
        aadContext: CloudVaultAADContext
    ) throws -> Data {
        if envelope.schemaVersion >= currentSealedPayloadSchemaVersion,
           envelope.aad != sealedPayloadAADContext {
            return try openPayload(envelope, keyData: keyData, aadContext: aadContext)
        }
        return try openPayload(envelope, keyData: keyData)
    }

    private static func sealText(
        _ text: String,
        keyData: Data,
        keyVersion: Int = currentKeyVersion,
        aadContext: CloudVaultAADContext,
        nonce: Data
    ) throws -> CloudVaultSealedText {
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: Data(text.utf8),
            keyData: keyData,
            nonce: nonce,
            authenticating: aadContext.data
        )
        return try sealedText(from: sealed, keyVersion: keyVersion, aadContext: aadContext)
    }

    private static func sealBlob(
        _ data: Data,
        keyData: Data,
        keyVersion: Int = currentKeyVersion,
        aadContext: CloudVaultAADContext,
        nonce: Data
    ) throws -> CloudVaultBlobEnvelope {
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: data,
            keyData: keyData,
            nonce: nonce,
            authenticating: aadContext.data
        )
        return CloudVaultBlobEnvelope(
            schemaVersion: currentBlobEnvelopeSchemaVersion,
            keyVersion: keyVersion,
            plaintextHMAC: try blobPlaintextHMAC(data, keyData: keyData),
            integrityHashVersion: blobIntegrityHashVersion,
            sealedBoxBase64: sealed.combined.base64EncodedString(),
            aad: aadContext.stringValue
        )
    }

    private static func sealPayload(
        _ data: Data,
        keyData: Data,
        vaultKeyID: String,
        keyVersion: Int = currentKeyVersion,
        aadContext: CloudVaultAADContext,
        nonce: Data
    ) throws -> CloudVaultSealedPayload {
        let draft = CloudVaultSealedPayload(
            keyVersion: keyVersion,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: "",
            aad: aadContext.stringValue
        )
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: data,
            keyData: keyData,
            nonce: nonce,
            authenticating: sealedPayloadAAD(for: draft, aadContext: aadContext)
        )
        return CloudVaultSealedPayload(
            schemaVersion: currentSealedPayloadSchemaVersion,
            keyVersion: keyVersion,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: sealed.combined.base64EncodedString(),
            aad: draft.aad
        )
    }

    private static func applyVaultKeyCompanionUpdates(
        to data: inout [String: Any],
        field: String,
        newVaultKeyID: String
    ) {
        switch field {
        case "sealedPayload", "sealedReplyPayload":
            if data["vaultKeyID"] != nil {
                data["vaultKeyID"] = newVaultKeyID
            }
        case "sealedStatePayload":
            if data["sealedStateVaultKeyID"] != nil {
                data["sealedStateVaultKeyID"] = newVaultKeyID
            }
        default:
            break
        }
    }

    private static func sealedText(
        from sealed: (nonce: Data, ciphertext: Data, tag: Data, combined: Data),
        keyVersion: Int,
        aadContext: CloudVaultAADContext?
    ) throws -> CloudVaultSealedText {
        CloudVaultSealedText(
            schemaVersion: aadContext == nil ? nil : currentSealedTextSchemaVersion,
            algorithm: aesGCMAlgorithm,
            keyVersion: keyVersion,
            nonce: sealed.nonce.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString(),
            aad: aadContext?.stringValue
        )
    }

    private static func open(
        _ envelope: CloudVaultSealedText,
        keyData: Data,
        aadContext: CloudVaultAADContext?
    ) throws -> Data {
        guard envelope.algorithm == aesGCMAlgorithm,
              let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        let schemaVersion = envelope.schemaVersion ?? 1
        if schemaVersion >= currentSealedTextSchemaVersion {
            guard let aadContext else {
                throw CloudVaultCryptoError.invalidEnvelope
            }
            return try PlatformCrypto.openAESGCMDetached(
                nonce: nonceData,
                ciphertext: ciphertext,
                tag: tag,
                keyData: keyData,
                authenticating: try aadData(matching: envelope.aad, context: aadContext)
            )
        }
        return try PlatformCrypto.openAESGCMDetached(
            nonce: nonceData,
            ciphertext: ciphertext,
            tag: tag,
            keyData: keyData
        )
    }
}

public struct CloudVaultKeyStore: Sendable {
    private let service: String

    public init(service: String = "com.openburnbar.cloud-vault") {
        self.service = service
    }

    public func loadKey(uid: String) throws -> Data? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(uid: uid),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CloudVaultCryptoError.keychainError(Int(status)) }
        guard let data = item as? Data else { throw CloudVaultCryptoError.keychainDataMissing }
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return data
        #else
        return nil
        #endif
    }

    public func getOrCreateKey(uid: String) throws -> Data {
        if let existing = try loadKey(uid: uid) {
            return existing
        }
        let key = try CloudVaultCrypto.generateVaultKey()
        try saveKey(key, uid: uid)
        return key
    }

    public func saveKey(_ keyData: Data, uid: String) throws {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(uid: uid)
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CloudVaultCryptoError.keychainError(Int(updateStatus))
        }
        var create = query
        create[kSecValueData as String] = keyData
        create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(create as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CloudVaultCryptoError.keychainError(Int(addStatus))
        }
        #endif
    }

    private func account(uid: String) -> String {
        "vault-key:\(uid)"
    }
}

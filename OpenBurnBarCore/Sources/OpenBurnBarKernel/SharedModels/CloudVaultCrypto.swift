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
    case domainCoreUnavailable
    case invalidSearchInput

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
        case .domainCoreUnavailable:
            return "The required CloudVault domain core is unavailable."
        case .invalidSearchInput:
            return "Cloud vault search input exceeds the supported indexing boundary."
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
        do {
            return try CloudVaultDomainCoreAdapter.aadV2(
                uid: uid,
                collection: collection,
                docID: docID,
                field: field,
                schemaVersion: schemaVersion,
                purpose: purpose,
                legacy: { CloudVaultLegacyCrypto.aadV2(
                    uid: uid,
                    collection: collection,
                    docID: docID,
                    field: field,
                    schemaVersion: schemaVersion,
                    purpose: purpose
                ) }
            )
        } catch {
            preconditionFailure("CloudVault AAD v2 construction failed")
        }
    }

    public var legacyV1StringValue: String {
        do {
            return try CloudVaultDomainCoreAdapter.aadV1(
                uid: uid,
                collection: collection,
                docID: docID,
                field: field,
                legacy: { CloudVaultLegacyCrypto.aadV1(uid: uid, collection: collection, docID: docID, field: field) }
            )
        } catch {
            preconditionFailure("CloudVault AAD v1 construction failed")
        }
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
        do {
            return try CloudVaultDomainCoreAdapter.vaultKeyID(for: keyData) {
                try CloudVaultLegacyCrypto.vaultKeyID(for: keyData)
            }
        } catch CloudVaultDomainCoreAdapterError.nativeUnavailable {
            throw CloudVaultCryptoError.domainCoreUnavailable
        } catch {
            throw CloudVaultCryptoError.invalidKeyLength
        }
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
        let sealed = try sealAESGCMDetachedThroughDomainCore(
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
        try openTextThroughDomainCore(envelope, keyData: keyData, aadContext: aadContext)
    }

    public static func sealBlob(
        _ data: Data,
        keyData: Data,
        keyVersion: Int = currentKeyVersion,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> CloudVaultBlobEnvelope {
        let sealed = try sealAESGCMDetachedThroughDomainCore(
            plaintext: data,
            keyData: keyData,
            authenticating: aadContext?.data ?? Data()
        )
        return CloudVaultBlobEnvelope(
            schemaVersion: currentBlobEnvelopeSchemaVersion,
            keyVersion: keyVersion,
            plaintextHMAC: try blobPlaintextHMAC(data, keyData: keyData),
            integrityHashVersion: blobIntegrityHashVersion,
            sealedBoxBase64: try base64EncodeThroughDomainCore(sealed.combined),
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
        let combined = try base64DecodeThroughDomainCore(envelope.sealedBoxBase64)
        let plaintext: Data
        switch envelope.schemaVersion {
        case 1:
            plaintext = try openAESGCMThroughDomainCore(combined: combined, keyData: keyData, authenticating: Data())
            guard let plaintextSHA256 = envelope.plaintextSHA256,
                  sha256Hex(plaintext) == plaintextSHA256 else {
                throw CloudVaultCryptoError.invalidEnvelope
            }
        case currentBlobEnvelopeSchemaVersion:
            if envelope.aad == blobEnvelopeAADContext {
                plaintext = try openAESGCMThroughDomainCore(
                    combined: combined,
                    keyData: keyData,
                    authenticating: Data()
                )
            } else {
                guard let aadContext else {
                    throw CloudVaultCryptoError.invalidEnvelope
                }
                plaintext = try openAESGCMThroughDomainCore(
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
        try domainCoreKeyedHash(data, keyData: keyData, purpose: .blobIntegrity, legacyPurpose: "blob-integrity")
    }

    public static func sessionBodyHash(_ data: Data, keyData: Data) throws -> String {
        try domainCoreKeyedHash(data, keyData: keyData, purpose: .sessionBody, legacyPurpose: "session-body")
    }

    public static func sessionBodyHash(_ text: String, keyData: Data) throws -> String {
        try sessionBodyHash(Data(text.utf8), keyData: keyData)
    }

    public static func expectedSessionBodyHash(_ data: Data, keyData: Data, bodyHashVersion: Int) throws -> String {
        do {
            return try CloudVaultDomainCoreAdapter.expectedSessionBodyHash(
                data,
                keyData: keyData,
                bodyHashVersion: bodyHashVersion
            ) {
                switch bodyHashVersion {
                case sessionBodyHashVersion:
                    return try CloudVaultLegacyCrypto.keyedHMACHex(
                        data,
                        keyData: keyData,
                        purpose: "session-body"
                    )
                case 0, 1:
                    return PlatformCrypto.sha256Hex(data)
                default:
                    throw CloudVaultCryptoError.invalidEnvelope
                }
            }
        } catch let error as CloudVaultCryptoError {
            throw error
        } catch CloudVaultDomainCoreAdapterError.nativeUnavailable {
            throw CloudVaultCryptoError.domainCoreUnavailable
        } catch {
            throw CloudVaultCryptoError.invalidEnvelope
        }
    }

    public static func sessionChunkHash(_ chunk: String, keyData: Data) throws -> String {
        try domainCoreKeyedHash(
            Data(chunk.utf8),
            keyData: keyData,
            purpose: .sessionChunk,
            legacyPurpose: "session-chunk"
        )
    }

    public static func projectMemoryContentHash(_ data: Data, keyData: Data) throws -> String {
        try domainCoreKeyedHash(
            data,
            keyData: keyData,
            purpose: .projectMemoryContent,
            legacyPurpose: "project-memory-content"
        )
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
        let combined = try sealAESGCMThroughDomainCore(
            plaintext: data,
            keyData: keyData,
            authenticating: sealedPayloadAAD(for: draft, aadContext: aadContext)
        )
        return CloudVaultSealedPayload(
            schemaVersion: currentSealedPayloadSchemaVersion,
            keyVersion: keyVersion,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: try base64EncodeThroughDomainCore(combined),
            aad: draft.aad
        )
    }

    public static func openPayload(
        _ envelope: CloudVaultSealedPayload,
        keyData: Data,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> Data {
        guard envelope.algorithm == aesGCMAlgorithm,
              envelope.vaultKeyID == (try vaultKeyID(for: keyData)) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        let combined = try base64DecodeThroughDomainCore(envelope.sealedBoxBase64)
        switch envelope.schemaVersion {
        case 1:
            return try openAESGCMThroughDomainCore(combined: combined, keyData: keyData, authenticating: Data())
        case currentSealedPayloadSchemaVersion:
            if envelope.aad == sealedPayloadAADContext {
                return try openAESGCMThroughDomainCore(
                    combined: combined,
                    keyData: keyData,
                    authenticating: sealedPayloadAAD(for: envelope, aadContext: nil)
                )
            }
            guard let aadContext else {
                throw CloudVaultCryptoError.invalidEnvelope
            }
            return try openAESGCMThroughDomainCore(
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
            try CloudVaultLegacyDocumentRewrap.rewrapCloudVaultDocumentLegacy(
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
        try CloudVaultSearchDomainCoreAdapter.hashes(
            operation: .token,
            text: text,
            keyData: keyData,
            limit: limit
        ) {
            try CloudVaultLegacySearch.tokenHashes(for: text, keyData: keyData, limit: limit)
        }
    }

    public static func searchIndexTokenHashes(for text: String, keyData: Data, limit: Int = 250) throws -> [String] {
        try CloudVaultSearchDomainCoreAdapter.hashes(
            operation: .index,
            text: text,
            keyData: keyData,
            limit: limit
        ) {
            try CloudVaultLegacySearch.searchIndexTokenHashes(for: text, keyData: keyData, limit: limit)
        }
    }

    public static func searchQueryTokenHashes(for text: String, keyData: Data, limit: Int = 250) throws -> [String] {
        try CloudVaultSearchDomainCoreAdapter.hashes(
            operation: .query,
            text: text,
            keyData: keyData,
            limit: limit
        ) {
            try CloudVaultLegacySearch.searchQueryTokenHashes(for: text, keyData: keyData, limit: limit)
        }
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
        try runDomainCoreC1c(invalidError: .invalidKeyLength) {
            try CloudVaultDomainCoreAdapter.projectMemoryDocID(slug: slug, keyData: keyData) {
                try CloudVaultOpaqueIdentifierLegacy.projectMemoryDocID(forSlug: slug, keyData: keyData)
            }
        }
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
        try runDomainCoreC1c(invalidError: .invalidKeyLength) {
            try CloudVaultDomainCoreAdapter.pensieveDedupHash(plaintext: plaintext, keyData: keyData) {
                try CloudVaultOpaqueIdentifierLegacy.pensieveDedupHash(plaintext, keyData: keyData)
            }
        }
    }

    /// Vault-keyed HMAC of a Pensieve source slug — the opaque filter column that
    /// replaces the cleartext `sourceSlug`. Full HMAC-SHA256 digest (64 hex).
    /// Derivation parity:
    /// `HKDF<SHA256>(vaultKey, salt: ∅, info: "pensieve-dedup:slug") → HMAC<SHA256>(slug)`.
    public static func pensieveSlugHmac(_ slug: String, keyData: Data) throws -> String {
        try runDomainCoreC1c(invalidError: .invalidKeyLength) {
            try CloudVaultDomainCoreAdapter.pensieveSlugHmac(slug: slug, keyData: keyData) {
                try CloudVaultOpaqueIdentifierLegacy.pensieveSlugHmac(slug, keyData: keyData)
            }
        }
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
        try runDomainCoreC1c(invalidError: .invalidKeyLength) {
            try CloudVaultDomainCoreAdapter.subscriptionDocID(
                agentURI: agentURI,
                topicID: topicID,
                keyData: keyData
            ) {
                try CloudVaultOpaqueIdentifierLegacy.subscriptionDocID(
                    agentURI: agentURI,
                    topicID: topicID,
                    keyData: keyData
                )
            }
        }
    }

    /// Produces keyed semantic-search buckets from plaintext before it is encrypted.
    ///
    /// This is a searchable-symmetric-encryption style trapdoor: the server can
    /// intersect opaque buckets and rank candidate chunks, but it never receives
    /// plaintext tokens, embeddings, or the vault key. The sketch intentionally
    /// favors bounded, stable recall over model-specific vectors so every client
    /// can produce identical hashes offline.
    public static func semanticHashes(for text: String, keyData: Data, limit: Int = 24) throws -> [String] {
        try CloudVaultSearchDomainCoreAdapter.hashes(
            operation: .semantic,
            text: text,
            keyData: keyData,
            limit: limit
        ) {
            try CloudVaultLegacySearch.semanticHashes(for: text, keyData: keyData, limit: limit)
        }
    }

    public static func normalizedTokens(from text: String) -> [String] {
        CloudVaultLegacySearch.normalizedTokens(from: text)
    }

    public static func cloudSearchBodyChunks(
        _ body: String,
        metadata: String,
        maxBytes: Int = 16_000,
        maxExtractedTokens: Int = 4_096
    ) throws -> [String] {
        try CloudVaultLegacySearch.cloudSearchBodyChunks(
            body,
            metadata: metadata,
            maxBytes: maxBytes,
            maxExtractedTokens: maxExtractedTokens
        )
    }

    internal static func exactPhraseTokensForContract(from text: String) -> [String] {
        CloudVaultLegacySearch.exactPhraseTokens(from: text)
    }

    internal static func semanticFeatureNamesForContract(from text: String) -> [String] {
        CloudVaultLegacySearch.semanticFeatureNames(from: text)
    }

    public static func wrapVaultKey(_ keyData: Data, recipientPublicKey: Data) throws -> Data {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try sealEscrowPayload(keyData, recipientPublicKey: recipientPublicKey)
    }

    public static func sealEscrowPayload(
        _ plaintext: Data,
        recipientPublicKey: Data,
        authenticating aad: Data = Data()
    ) throws -> Data {
        try validateEscrowPublicKey(recipientPublicKey)
        guard let recipientKey = try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: recipientPublicKey) else {
            throw CloudVaultCryptoError.invalidPublicKey
        }
        let ephemeralKey = PlatformCrypto.p256KeyAgreementPrivateKey()
        let sharedSecret = try PlatformCrypto.p256KeyAgreementSharedSecret(privateKey: ephemeralKey, publicKey: recipientKey)
        let wrappingKeyData = try escrowWrappingKey(sharedSecret.withUnsafeBytes { Data($0) })
        let combined = try sealAESGCMThroughDomainCore(
            plaintext: plaintext,
            keyData: wrappingKeyData,
            authenticating: aad
        )
        let ephemeralPublicKey = ephemeralKey.publicKey.x963Representation
        return try runDomainCoreC1c(invalidError: .invalidEnvelope) {
            try CloudVaultDomainCoreAdapter.escrowAssembleWire(
                ephemeralPublicKey: ephemeralPublicKey,
                aesGCMCombined: combined
            ) { ephemeralPublicKey + combined }
        }
    }

    public static func unwrapVaultKey(_ ciphertext: Data, privateKey: PlatformP256KeyAgreementPrivateKey) throws -> Data {
        let keyData = try openEscrowPayload(ciphertext, privateKey: privateKey)
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return keyData
    }

    public static func openEscrowPayload(
        _ ciphertext: Data,
        privateKey: PlatformP256KeyAgreementPrivateKey,
        authenticating aad: Data = Data()
    ) throws -> Data {
        let parts = try runDomainCoreC1c(invalidError: .invalidEnvelope) {
            try CloudVaultDomainCoreAdapter.escrowSplitWire(ciphertext) {
                try CloudVaultLegacyCrypto.escrowSplitWire(ciphertext)
            }
        }
        guard let publicKey = try? PlatformCrypto.p256KeyAgreementPublicKey(
            x963Representation: parts.ephemeralPublicKey
        ) else { throw CloudVaultCryptoError.invalidPublicKey }
        let sharedSecret = try PlatformCrypto.p256KeyAgreementSharedSecret(privateKey: privateKey, publicKey: publicKey)
        let wrappingKeyData = try escrowWrappingKey(sharedSecret.withUnsafeBytes { Data($0) })
        return try openAESGCMThroughDomainCore(
            combined: parts.aesGCMCombined,
            keyData: wrappingKeyData,
            authenticating: aad
        )
    }

    public static func deriveRecoveryWrappingKey(from recoveryKey: String) throws -> PlatformSymmetricKey {
        let keyData = try runDomainCoreC1c(invalidError: .invalidKeyLength) {
            try CloudVaultDomainCoreAdapter.recoveryWrappingKey(recoveryKey: recoveryKey) {
                PlatformCrypto.symmetricKeyData(try CloudVaultLegacyCrypto.recoveryWrappingKey(from: recoveryKey))
            }
        }
        return try PlatformCrypto.symmetricKey(data: keyData)
    }

    public static func wrapVaultKeyWithRecovery(
        vaultKey: Data,
        recoveryKey: String
    ) throws -> (wrappedVaultKeyBase64: String, verificationHash: String) {
        guard vaultKey.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        let nonce = Data(try randomBytes(count: 12))
        let wrapped = try runDomainCoreC1c(invalidError: .invalidKeyLength) {
            try CloudVaultDomainCoreAdapter.recoveryWrapVaultKey(
                vaultKey: vaultKey,
                recoveryKey: recoveryKey,
                nonce: nonce
            ) {
                try CloudVaultLegacyCrypto.recoveryWrapVaultKey(
                    vaultKey: vaultKey,
                    recoveryKey: recoveryKey,
                    nonce: nonce
                )
            }
        }
        return (
            wrappedVaultKeyBase64: try base64EncodeThroughDomainCore(wrapped.combined),
            verificationHash: wrapped.verificationHash
        )
    }

    public static func unwrapVaultKeyWithRecovery(
        wrappedVaultKeyBase64: String,
        recoveryKey: String
    ) throws -> Data {
        let combined = try base64DecodeThroughDomainCore(wrappedVaultKeyBase64)
        return try runDomainCoreC1c(invalidError: .invalidEnvelope) {
            try CloudVaultDomainCoreAdapter.recoveryOpenVaultKey(combined: combined, recoveryKey: recoveryKey) {
                try CloudVaultLegacyCrypto.recoveryOpenVaultKey(combined: combined, recoveryKey: recoveryKey)
            }
        }
    }

    public static func recoveryVerificationHash(for recoveryKey: String) throws -> String {
        try runDomainCoreC1c(invalidError: .invalidKeyLength) {
            try CloudVaultDomainCoreAdapter.recoveryVerificationHash(recoveryKey: recoveryKey) {
                try CloudVaultLegacyCrypto.recoveryVerificationHash(for: recoveryKey)
            }
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        do {
            return try CloudVaultDomainCoreAdapter.sha256Hex(data) {
                CloudVaultLegacyCrypto.sha256Hex(data)
            }
        } catch {
            preconditionFailure("CloudVault SHA-256 failed")
        }
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    private static func validateEscrowPublicKey(_ publicKey: Data) throws {
        try runDomainCoreC1c(invalidError: .invalidPublicKey) {
            try CloudVaultDomainCoreAdapter.validateP256X963PublicKey(publicKey) {
                try CloudVaultLegacyCrypto.validateEscrowPublicKey(publicKey)
            }
        }
    }

    private static func escrowWrappingKey(_ sharedSecret: Data) throws -> Data {
        try runDomainCoreC1c(invalidError: .invalidEnvelope) {
            try CloudVaultDomainCoreAdapter.escrowWrappingKey(sharedSecret: sharedSecret) {
                try CloudVaultLegacyCrypto.escrowWrappingKey(sharedSecret)
            }
        }
    }

    private static func runDomainCoreC1c<T>(
        invalidError: CloudVaultCryptoError,
        _ operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch CloudVaultDomainCoreAdapterError.nativeUnavailable {
            throw CloudVaultCryptoError.domainCoreUnavailable
        } catch is CloudVaultDomainCoreAdapterError {
            throw invalidError
        }
    }

    private static func symmetricKey(from data: Data) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.symmetricKey(data: data)
    }

    private static func domainCoreKeyedHash(
        _ data: Data,
        keyData: Data,
        purpose: CloudVaultDomainCoreAdapter.Purpose,
        legacyPurpose: String
    ) throws -> String {
        do {
            return try CloudVaultDomainCoreAdapter.keyedHashHex(
                data,
                keyData: keyData,
                purpose: purpose
            ) {
                try CloudVaultLegacyCrypto.keyedHMACHex(data, keyData: keyData, purpose: legacyPurpose)
            }
        } catch let error as CloudVaultCryptoError {
            throw error
        } catch CloudVaultDomainCoreAdapterError.nativeUnavailable {
            throw CloudVaultCryptoError.domainCoreUnavailable
        } catch {
            throw CloudVaultCryptoError.invalidKeyLength
        }
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
        do {
            return try CloudVaultDomainCoreAdapter.resolveAAD(
                envelopeAAD: envelopeAAD ?? "",
                context: context,
                rejectLegacyV1: rejectLegacyV1
            ) {
                try CloudVaultLegacyCrypto.resolveAAD(
                    envelopeAAD: envelopeAAD,
                    context: context,
                    rejectLegacyV1: rejectLegacyV1
                )
            }
        } catch let error as CloudVaultCryptoError {
            throw error
        } catch CloudVaultDomainCoreAdapterError.nativeUnavailable {
            throw CloudVaultCryptoError.domainCoreUnavailable
        } catch {
            throw CloudVaultCryptoError.invalidEnvelope
        }
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

    private static func decodeEnvelope<T: Decodable>(_ raw: Any?, as type: T.Type) -> T? {
        guard let dict = raw as? [String: Any],
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func sealedText(
        from sealed: CloudVaultDomainCoreAdapter.AESGCMDetachedBox,
        keyVersion: Int,
        aadContext: CloudVaultAADContext?
    ) throws -> CloudVaultSealedText {
        CloudVaultSealedText(
            schemaVersion: aadContext == nil ? nil : currentSealedTextSchemaVersion,
            algorithm: aesGCMAlgorithm,
            keyVersion: keyVersion,
            nonce: try base64EncodeThroughDomainCore(sealed.nonce),
            ciphertext: try base64EncodeThroughDomainCore(sealed.ciphertext),
            tag: try base64EncodeThroughDomainCore(sealed.tag),
            aad: aadContext?.stringValue
        )
    }

    private static func sealedText(
        from sealed: PlatformAESGCMSealedBox,
        keyVersion: Int,
        aadContext: CloudVaultAADContext?
    ) -> CloudVaultSealedText {
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

    private static func openTextThroughDomainCore(
        _ envelope: CloudVaultSealedText,
        keyData: Data,
        aadContext: CloudVaultAADContext?
    ) throws -> String {
        guard envelope.algorithm == aesGCMAlgorithm else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        let nonceData = try base64DecodeThroughDomainCore(envelope.nonce)
        let ciphertext = try base64DecodeThroughDomainCore(envelope.ciphertext)
        let tag = try base64DecodeThroughDomainCore(envelope.tag)
        let schemaVersion = envelope.schemaVersion ?? 1
        let aad: Data
        switch schemaVersion {
        case 1:
            aad = Data()
        case currentSealedTextSchemaVersion:
            guard let aadContext else {
                throw CloudVaultCryptoError.invalidEnvelope
            }
            aad = try aadData(matching: envelope.aad, context: aadContext)
        default:
            throw CloudVaultCryptoError.invalidEnvelope
        }
        return try runDomainCoreAES {
            try CloudVaultDomainCoreAdapter.openAESGCMTextDetached(
                nonce: nonceData,
                ciphertext: ciphertext,
                tag: tag,
                keyData: keyData,
                authenticating: aad
            ) {
                try CloudVaultLegacyCrypto.openAESGCMTextDetached(
                    nonce: nonceData,
                    ciphertext: ciphertext,
                    tag: tag,
                    keyData: keyData,
                    authenticating: aad
                )
            }
        }
    }

    private static func sealAESGCMDetachedThroughDomainCore(
        plaintext: Data,
        keyData: Data,
        authenticating aad: Data
    ) throws -> CloudVaultDomainCoreAdapter.AESGCMDetachedBox {
        let nonce = Data(try randomBytes(count: 12))
        return try runDomainCoreAES {
            try CloudVaultDomainCoreAdapter.sealAESGCMDetached(
                plaintext: plaintext,
                keyData: keyData,
                nonce: nonce,
                authenticating: aad
            ) {
                try CloudVaultLegacyCrypto.sealAESGCMDetached(
                    plaintext: plaintext,
                    keyData: keyData,
                    nonce: nonce,
                    authenticating: aad
                )
            }
        }
    }

    private static func sealAESGCMThroughDomainCore(
        plaintext: Data,
        keyData: Data,
        authenticating aad: Data
    ) throws -> Data {
        let nonce = Data(try randomBytes(count: 12))
        return try runDomainCoreAES {
            try CloudVaultDomainCoreAdapter.sealAESGCMCombined(
                plaintext: plaintext,
                keyData: keyData,
                nonce: nonce,
                authenticating: aad
            ) {
                try CloudVaultLegacyCrypto.sealAESGCMCombined(
                    plaintext: plaintext,
                    keyData: keyData,
                    nonce: nonce,
                    authenticating: aad
                )
            }
        }
    }

    private static func openAESGCMThroughDomainCore(
        combined: Data,
        keyData: Data,
        authenticating aad: Data
    ) throws -> Data {
        try runDomainCoreAES {
            try CloudVaultDomainCoreAdapter.openAESGCMCombined(
                combined: combined,
                keyData: keyData,
                authenticating: aad
            ) {
                try CloudVaultLegacyCrypto.openAESGCMCombined(
                    combined: combined,
                    keyData: keyData,
                    authenticating: aad
                )
            }
        }
    }

    private static func base64EncodeThroughDomainCore(_ data: Data) throws -> String {
        try runDomainCoreAES {
            try CloudVaultDomainCoreAdapter.base64Encode(data) {
                CloudVaultLegacyCrypto.base64Encode(data)
            }
        }
    }

    private static func base64DecodeThroughDomainCore(_ value: String) throws -> Data {
        try runDomainCoreAES {
            try CloudVaultDomainCoreAdapter.base64DecodeStrict(value) {
                try CloudVaultLegacyCrypto.base64DecodeStrict(value)
            }
        }
    }

    private static func runDomainCoreAES<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch CloudVaultDomainCoreAdapterError.nativeUnavailable {
            throw CloudVaultCryptoError.domainCoreUnavailable
        } catch is CloudVaultDomainCoreAdapterError {
            throw CloudVaultCryptoError.invalidEnvelope
        }
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

    /// Remove a stored key. Used by the team key ring to destroy a PENDING
    /// generation the roster authority has burned (`abandonTeamKeyGeneration`,
    /// memory program D16 / P21): that version is never rotated to again, so
    /// its key can open nothing that will ever exist, and leaving it behind
    /// would keep a slot whose bytes only this Mac holds.
    ///
    /// `errSecItemNotFound` is success — deleting a key that is not there
    /// leaves exactly the state the caller asked for, so the operation is an
    /// idempotent retry like `saveKey`.
    public func deleteKey(uid: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(uid: uid)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudVaultCryptoError.keychainError(Int(status))
        }
        #endif
    }

    private func account(uid: String) -> String {
        "vault-key:\(uid)"
    }
}

import CryptoKit
import Foundation
import Security

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

public struct CloudVaultSealedText: Codable, Hashable, Sendable {
    public let algorithm: String
    public let keyVersion: Int
    public let nonce: String
    public let ciphertext: String
    public let tag: String

    public init(algorithm: String, keyVersion: Int, nonce: String, ciphertext: String, tag: String) {
        self.algorithm = algorithm
        self.keyVersion = keyVersion
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public struct CloudVaultBlobEnvelope: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let algorithm: String
    public let keyVersion: Int
    public let plaintextSHA256: String
    public let sealedBoxBase64: String
    public let createdAt: Date

    public init(
        schemaVersion: Int = 1,
        algorithm: String = CloudVaultCrypto.aesGCMAlgorithm,
        keyVersion: Int,
        plaintextSHA256: String,
        sealedBoxBase64: String,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyVersion = keyVersion
        self.plaintextSHA256 = plaintextSHA256
        self.sealedBoxBase64 = sealedBoxBase64
        self.createdAt = createdAt
    }
}

public enum CloudVaultCrypto {
    public static let aesGCMAlgorithm = "AES-256-GCM"
    public static let tokenHashVersion = 1
    public static let semanticHashVersion = 1
    public static let currentKeyVersion = 1

    public static func generateVaultKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    public static func sealText(_ text: String, keyData: Data, keyVersion: Int = currentKeyVersion) throws -> CloudVaultSealedText {
        let sealed = try AES.GCM.seal(Data(text.utf8), using: try symmetricKey(from: keyData))
        return try sealedText(from: sealed, keyVersion: keyVersion)
    }

    public static func openText(_ envelope: CloudVaultSealedText, keyData: Data) throws -> String {
        let data = try open(envelope, keyData: keyData)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        return text
    }

    public static func sealBlob(_ data: Data, keyData: Data, keyVersion: Int = currentKeyVersion) throws -> CloudVaultBlobEnvelope {
        let sealed = try AES.GCM.seal(data, using: try symmetricKey(from: keyData))
        guard let combined = sealed.combined else {
            throw CloudVaultCryptoError.sealedBoxUnavailable
        }
        return CloudVaultBlobEnvelope(
            keyVersion: keyVersion,
            plaintextSHA256: sha256Hex(data),
            sealedBoxBase64: combined.base64EncodedString()
        )
    }

    public static func openBlob(_ envelope: CloudVaultBlobEnvelope, keyData: Data) throws -> Data {
        guard let combined = Data(base64Encoded: envelope.sealedBoxBase64) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: try symmetricKey(from: keyData))
        guard sha256Hex(plaintext) == envelope.plaintextSHA256 else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        return plaintext
    }

    public static func tokenHashes(for text: String, keyData: Data, limit: Int = 250) throws -> [String] {
        let key = try searchKey(from: keyData)
        var seen = Set<String>()
        var hashes: [String] = []
        for token in normalizedTokens(from: text) where seen.insert(token).inserted {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: key)
            hashes.append(Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined())
            if hashes.count >= limit { break }
        }
        return hashes
    }

    /// Produces keyed semantic-search buckets from plaintext before it is encrypted.
    ///
    /// This is a searchable-symmetric-encryption style trapdoor: the server can
    /// intersect opaque buckets and rank candidate chunks, but it never receives
    /// plaintext tokens, embeddings, or the vault key. The sketch intentionally
    /// favors bounded, stable recall over model-specific vectors so every client
    /// can produce identical hashes offline.
    public static func semanticHashes(for text: String, keyData: Data, limit: Int = 24) throws -> [String] {
        let tokens = normalizedTokens(from: text)
        guard tokens.isEmpty == false, limit > 0 else { return [] }

        let key = try semanticSearchKey(from: keyData)
        let features = semanticFeatures(from: tokens)
        guard features.isEmpty == false else { return [] }

        let dimensions = 64
        var accumulator = [Double](repeating: 0, count: dimensions)
        for feature in features {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(feature.name.utf8), using: key)
            let bytes = Array(Data(mac))
            let index = ((Int(bytes[0]) << 8) | Int(bytes[1])) % dimensions
            let sign = (bytes[2] & 1) == 0 ? 1.0 : -1.0
            accumulator[index] += sign * feature.weight
        }

        var hashes: [String] = []
        var seen = Set<String>()
        func appendBucket(_ bucket: String) {
            guard hashes.count < limit else { return }
            let mac = HMAC<SHA256>.authenticationCode(for: Data(bucket.utf8), using: key)
            let hash = Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
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
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "how", "what", "where",
            "when", "why", "are", "was", "were", "you", "your", "have", "has", "had",
            "into", "onto", "can", "could", "should", "would"
        ]
        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && stopwords.contains($0) == false }
    }

    public static func wrapVaultKey(_ keyData: Data, recipientPublicKey: Data) throws -> Data {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        guard let recipientKey = try? P256.KeyAgreement.PublicKey(x963Representation: recipientPublicKey) else {
            throw CloudVaultCryptoError.invalidPublicKey
        }
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: recipientKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("OpenBurnBar-Escrow-v1".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(keyData, using: wrappingKey)
        guard let combined = sealed.combined else {
            throw CloudVaultCryptoError.sealedBoxUnavailable
        }
        return ephemeralKey.publicKey.x963Representation + combined
    }

    public static func unwrapVaultKey(_ ciphertext: Data, privateKey: P256.KeyAgreement.PrivateKey) throws -> Data {
        guard ciphertext.count > 65 else { throw CloudVaultCryptoError.invalidEnvelope }
        let publicKeyData = ciphertext.prefix(65)
        let sealedBoxData = ciphertext.suffix(from: 65)
        guard let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: publicKeyData) else {
            throw CloudVaultCryptoError.invalidPublicKey
        }
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("OpenBurnBar-Escrow-v1".utf8),
            outputByteCount: 32
        )
        let sealedBox = try AES.GCM.SealedBox(combined: sealedBoxData)
        let keyData = try AES.GCM.open(sealedBox, using: wrappingKey)
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return keyData
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    private static func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return SymmetricKey(data: data)
    }

    private static func searchKey(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: data),
            salt: Data("OpenBurnBar-CloudSearch-Salt-v1".utf8),
            info: Data("OpenBurnBar-CloudSearch-TokenHash-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func semanticSearchKey(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: data),
            salt: Data("OpenBurnBar-CloudSearch-Semantic-Salt-v1".utf8),
            info: Data("OpenBurnBar-CloudSearch-SemanticHash-v1".utf8),
            outputByteCount: 32
        )
    }

    private struct SemanticFeature {
        let name: String
        let weight: Double
    }

    private static func semanticFeatures(from tokens: [String]) -> [SemanticFeature] {
        var features: [SemanticFeature] = []
        var seen = Set<String>()

        func append(_ name: String, weight: Double) {
            guard name.isEmpty == false, seen.insert(name).inserted else { return }
            features.append(SemanticFeature(name: name, weight: weight))
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

    private static func sealedText(from sealed: AES.GCM.SealedBox, keyVersion: Int) throws -> CloudVaultSealedText {
        CloudVaultSealedText(
            algorithm: aesGCMAlgorithm,
            keyVersion: keyVersion,
            nonce: sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
    }

    private static func open(_ envelope: CloudVaultSealedText, keyData: Data) throws -> Data {
        guard envelope.algorithm == aesGCMAlgorithm,
              let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: try symmetricKey(from: keyData))
    }
}

public struct CloudVaultKeyStore: Sendable {
    private let service: String

    public init(service: String = "com.openburnbar.cloud-vault") {
        self.service = service
    }

    public func loadKey(uid: String) throws -> Data? {
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
    }

    public func getOrCreateKey(uid: String) throws -> Data {
        if let existing = try loadKey(uid: uid) {
            return existing
        }
        let key = CloudVaultCrypto.generateVaultKey()
        try saveKey(key, uid: uid)
        return key
    }

    public func saveKey(_ keyData: Data, uid: String) throws {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
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
    }

    private func account(uid: String) -> String {
        "vault-key:\(uid)"
    }
}

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

public struct CloudVaultSealedPayload: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let algorithm: String
    public let keyVersion: Int
    public let vaultKeyID: String
    public let sealedBoxBase64: String

    public init(
        schemaVersion: Int = 1,
        algorithm: String = CloudVaultCrypto.aesGCMAlgorithm,
        keyVersion: Int,
        vaultKeyID: String,
        sealedBoxBase64: String
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.keyVersion = keyVersion
        self.vaultKeyID = vaultKeyID
        self.sealedBoxBase64 = sealedBoxBase64
    }
}

public enum CloudVaultCrypto {
    public static let aesGCMAlgorithm = "AES-256-GCM"
    public static let tokenHashVersion = 1
    public static let semanticHashVersion = 1
    public static let currentKeyVersion = 1
    public static let recoverySalt = Data("OpenBurnBar-Recovery-Salt-v1".utf8)
    public static let recoveryWrapInfo = Data("OpenBurnBar-Recovery-Wrap-v1".utf8)

    public static func generateVaultKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    public static func vaultKeyID(for keyData: Data) throws -> String {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return "v1_" + String(sha256Hex(keyData).prefix(32))
    }

    public static func generateRecoveryKey() throws -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 35)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw CloudVaultCryptoError.keychainError(Int(status)) }
        let characters = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: characters.count, by: 7)
            .map { String(characters[$0..<min($0 + 7, characters.count)]) }
            .joined(separator: "-")
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

    public static func sealPayload(
        _ data: Data,
        keyData: Data,
        vaultKeyID: String,
        keyVersion: Int = currentKeyVersion
    ) throws -> CloudVaultSealedPayload {
        let sealed = try AES.GCM.seal(data, using: try symmetricKey(from: keyData))
        guard let combined = sealed.combined else {
            throw CloudVaultCryptoError.sealedBoxUnavailable
        }
        return CloudVaultSealedPayload(
            keyVersion: keyVersion,
            vaultKeyID: vaultKeyID,
            sealedBoxBase64: combined.base64EncodedString()
        )
    }

    public static func openPayload(_ envelope: CloudVaultSealedPayload, keyData: Data) throws -> Data {
        guard envelope.algorithm == aesGCMAlgorithm,
              envelope.schemaVersion == 1,
              envelope.vaultKeyID == (try vaultKeyID(for: keyData)),
              let combined = Data(base64Encoded: envelope.sealedBoxBase64) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: try symmetricKey(from: keyData))
    }

    public static func sealedPayloadDictionary(_ envelope: CloudVaultSealedPayload) -> [String: Any] {
        [
            "schemaVersion": envelope.schemaVersion,
            "algorithm": envelope.algorithm,
            "keyVersion": envelope.keyVersion,
            "vaultKeyID": envelope.vaultKeyID,
            "sealedBoxBase64": envelope.sealedBoxBase64
        ]
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
            sealedBoxBase64: sealedBoxBase64
        )
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

    private static func tokenHashes(forTerms terms: [String], key: SymmetricKey, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var hashes: [String] = []
        for term in terms where seen.insert(term).inserted {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(term.utf8), using: key)
            hashes.append(Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined())
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
        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && searchStopwords.contains($0) == false }
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

    public static func deriveRecoveryWrappingKey(from recoveryKey: String) throws -> SymmetricKey {
        let normalized = normalizedRecoveryKey(recoveryKey)
        guard normalized.count >= 20 else { throw CloudVaultCryptoError.invalidKeyLength }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalized.utf8)),
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
        let sealed = try AES.GCM.seal(vaultKey, using: wrappingKey)
        guard let combined = sealed.combined else {
            throw CloudVaultCryptoError.sealedBoxUnavailable
        }
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
        let box = try AES.GCM.SealedBox(combined: combined)
        let keyData = try AES.GCM.open(box, using: try deriveRecoveryWrappingKey(from: recoveryKey))
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return keyData
    }

    public static func recoveryVerificationHash(for recoveryKey: String) throws -> String {
        try recoveryVerificationHash(forDerivedKey: deriveRecoveryWrappingKey(from: recoveryKey))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    private static func recoveryVerificationHash(forDerivedKey key: SymmetricKey) -> String {
        key.withUnsafeBytes { bytes in
            sha256Hex(Data(bytes))
        }
    }

    private static func normalizedRecoveryKey(_ recoveryKey: String) -> String {
        recoveryKey
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
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

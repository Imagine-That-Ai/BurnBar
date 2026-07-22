import Foundation

enum CloudVaultOpaqueIdentifierLegacy {
    static func projectMemoryDocID(forSlug slug: String, keyData: Data) throws -> String {
        let key = try deriveKey(
            from: keyData,
            salt: Data("OpenBurnBar-DocID-Salt-v1".utf8),
            info: Data("OpenBurnBar-ProjectMemory-DocID-v1".utf8)
        )
        let mac = try PlatformCrypto.hmacSHA256(
            Data(slug.utf8),
            keyData: PlatformCrypto.symmetricKeyData(key)
        )
        return "pm_" + hex(mac.prefix(16))
    }

    static func pensieveDedupHash(_ plaintext: String, keyData: Data) throws -> String {
        try pensieveHMAC(plaintext, keyData: keyData, label: "content")
    }

    static func pensieveSlugHmac(_ slug: String, keyData: Data) throws -> String {
        try pensieveHMAC(slug, keyData: keyData, label: "slug")
    }

    static func subscriptionDocID(agentURI: String, topicID: String, keyData: Data) throws -> String {
        let key = try deriveKey(
            from: keyData,
            salt: Data(),
            info: Data("subscription-topic".utf8)
        )
        let mac = try PlatformCrypto.hmacSHA256(
            Data("\(agentURI):\(topicID)".utf8),
            keyData: PlatformCrypto.symmetricKeyData(key)
        )
        return "sub_" + hex(mac.prefix(16))
    }

    private static func pensieveHMAC(_ value: String, keyData: Data, label: String) throws -> String {
        let key = try deriveKey(
            from: keyData,
            salt: Data(),
            info: Data("pensieve-dedup:\(label)".utf8)
        )
        return try PlatformCrypto.hmacSHA256Hex(
            Data(value.utf8),
            keyData: PlatformCrypto.symmetricKeyData(key)
        )
    }

    private static func deriveKey(from data: Data, salt: Data, info: Data) throws -> PlatformSymmetricKey {
        guard data.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: data,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    private static func hex(_ data: Data.SubSequence) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

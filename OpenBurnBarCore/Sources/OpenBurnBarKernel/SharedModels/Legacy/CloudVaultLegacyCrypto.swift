import Foundation

enum CloudVaultLegacyCrypto {
    static func aadV1(uid: String, collection: String, docID: String, field: String) -> String {
        "\(CloudVaultCrypto.legacyAADContextPrefix)|\(uid)|\(collection)|\(docID)|\(field)"
    }

    static func aadV2(
        uid: String,
        collection: String,
        docID: String,
        field: String,
        schemaVersion: Int,
        purpose: String
    ) -> String {
        "\(CloudVaultCrypto.aadContextPrefix)|\(uid)|\(collection)|\(docID)|\(field)|\(schemaVersion)|\(purpose)"
    }

    static func resolveAAD(
        envelopeAAD: String?,
        context: CloudVaultAADContext,
        rejectLegacyV1: Bool
    ) throws -> Data {
        if envelopeAAD == context.stringValue { return context.data }
        if envelopeAAD == context.legacyV1StringValue {
            if rejectLegacyV1 { throw CloudVaultCryptoError.invalidEnvelope }
            return context.legacyV1Data
        }
        throw CloudVaultCryptoError.invalidEnvelope
    }

    static func vaultKeyID(for keyData: Data) throws -> String {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return "v1_" + String(PlatformCrypto.sha256Hex(keyData).prefix(32))
    }

    static func sha256Hex(_ data: Data) -> String {
        PlatformCrypto.sha256Hex(data)
    }

    static func keyedHMACHex(_ data: Data, keyData: Data, purpose: String) throws -> String {
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        let key = try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: keyData,
            salt: Data("OpenBurnBar-CloudVault-HMAC-Salt-v1".utf8),
            info: Data("OpenBurnBar-CloudVault-HMAC-v1|\(purpose)".utf8),
            outputByteCount: 32
        )
        return PlatformCrypto.hexString(
            try PlatformCrypto.hmacSHA256(data, keyData: PlatformCrypto.symmetricKeyData(key))
        )
    }

    static func recoveryWrappingKey(from recoveryKey: String) throws -> PlatformSymmetricKey {
        let normalized = recoveryKey.uppercased().filter { $0.isLetter || $0.isNumber }
        guard normalized.count >= 20 else { throw CloudVaultCryptoError.invalidKeyLength }
        return try PlatformCrypto.deriveHKDFSHA256Key(
            inputKeyMaterial: Data(normalized.utf8),
            salt: Data("OpenBurnBar-Recovery-Salt-v1".utf8),
            info: Data("OpenBurnBar-Recovery-Wrap-v1".utf8),
            outputByteCount: 32
        )
    }

    static func recoveryWrapVaultKey(
        vaultKey: Data,
        recoveryKey: String,
        nonce: Data
    ) throws -> CloudVaultDomainCoreAdapter.RecoveryWrappedVaultKey {
        let wrappingKey = try recoveryWrappingKey(from: recoveryKey)
        let combined = try PlatformCrypto.sealAESGCMDetached(
            plaintext: vaultKey,
            keyData: PlatformCrypto.symmetricKeyData(wrappingKey),
            nonce: nonce,
            authenticating: Data()
        ).combined
        return .init(combined: combined, verificationHash: recoveryVerificationHash(forDerivedKey: wrappingKey))
    }

    static func recoveryOpenVaultKey(combined: Data, recoveryKey: String) throws -> Data {
        let keyData = try PlatformCrypto.openAESGCM(
            combined: combined,
            key: try recoveryWrappingKey(from: recoveryKey),
            authenticating: Data()
        )
        guard keyData.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
        return keyData
    }

    static func recoveryVerificationHash(for recoveryKey: String) throws -> String {
        recoveryVerificationHash(forDerivedKey: try recoveryWrappingKey(from: recoveryKey))
    }

    static func validateEscrowPublicKey(_ publicKey: Data) throws -> Bool {
        guard (try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: publicKey)) != nil else {
            throw CloudVaultCryptoError.invalidPublicKey
        }
        return true
    }

    static func escrowWrappingKey(_ sharedSecret: Data) throws -> Data {
        try PlatformCrypto.deriveHKDFSHA256KeyData(
            inputKeyMaterial: sharedSecret,
            salt: Data(),
            info: Data("OpenBurnBar-Escrow-v1".utf8),
            outputByteCount: 32
        )
    }

    static func escrowSplitWire(_ ciphertext: Data) throws -> CloudVaultDomainCoreAdapter.EscrowWireParts {
        guard ciphertext.count >= 65 + 12 + 16 else { throw CloudVaultCryptoError.invalidEnvelope }
        let publicKeyData = Data(ciphertext.prefix(65))
        _ = try validateEscrowPublicKey(publicKeyData)
        return .init(
            ephemeralPublicKey: publicKeyData,
            aesGCMCombined: Data(ciphertext.dropFirst(65))
        )
    }

    static func sealAESGCMDetached(
        plaintext: Data,
        keyData: Data,
        nonce: Data,
        authenticating aad: Data
    ) throws -> CloudVaultDomainCoreAdapter.AESGCMDetachedBox {
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: plaintext,
            keyData: keyData,
            nonce: nonce,
            authenticating: aad
        )
        return .init(nonce: sealed.nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
    }

    static func sealAESGCMCombined(
        plaintext: Data,
        keyData: Data,
        nonce: Data,
        authenticating aad: Data
    ) throws -> Data {
        try PlatformCrypto.sealAESGCMDetached(
            plaintext: plaintext,
            keyData: keyData,
            nonce: nonce,
            authenticating: aad
        ).combined
    }

    static func openAESGCMCombined(combined: Data, keyData: Data, authenticating aad: Data) throws -> Data {
        try PlatformCrypto.openAESGCM(combined: combined, keyData: keyData, authenticating: aad)
    }

    static func openAESGCMTextDetached(
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        keyData: Data,
        authenticating aad: Data
    ) throws -> String {
        let data = try PlatformCrypto.openAESGCMDetached(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            keyData: keyData,
            authenticating: aad
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        return text
    }

    static func base64Encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    static func base64DecodeStrict(_ value: String) throws -> Data {
        guard let decoded = Data(base64Encoded: value) else { throw CloudVaultCryptoError.invalidEnvelope }
        return decoded
    }

    private static func recoveryVerificationHash(forDerivedKey key: PlatformSymmetricKey) -> String {
        key.withUnsafeBytes { PlatformCrypto.sha256Hex(Data($0)) }
    }
}

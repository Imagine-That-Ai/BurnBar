import Foundation

enum HermesRelayLegacyCrypto {
    static func aad(_ parts: [String]) -> Data {
        Data("OpenBurnBar-HermesRelay-v1|\(parts.joined(separator: "|"))".utf8)
    }

    static func keyWrapInfo(aad: Data) -> Data {
        var info = Data("OpenBurnBar-HermesRelay-KeyWrap-v1|".utf8)
        info.append(aad)
        return info
    }

    static func keyWrapInfoV2(
        aad: Data,
        enc: Data,
        recipientPublicKey: Data,
        senderPublicKey: Data
    ) -> Data {
        var info = Data("OpenBurnBar-HermesRelay-KeyWrap-v2|".utf8)
        info.append(aad)
        info.append(enc)
        info.append(recipientPublicKey)
        info.append(senderPublicKey)
        return info
    }

    static func hpkeV3Info(aad: Data) -> Data {
        var info = Data("OpenBurnBar-HermesRelay-HPKE-v3|".utf8)
        info.append(aad)
        return info
    }

    static func deriveWrappingKey(inputKeyMaterial: Data, info: Data) throws -> Data {
        try PlatformCrypto.deriveHKDFSHA256KeyData(
            inputKeyMaterial: inputKeyMaterial,
            salt: Data(),
            info: info,
            outputByteCount: HermesRelayCrypto.symmetricKeyByteCount
        )
    }

    static func sealToBase64(plaintext: Data, keyData: Data, aad: Data) throws -> String {
        try PlatformCrypto.sealAESGCM(
            plaintext: plaintext,
            keyData: keyData,
            authenticating: aad
        ).base64EncodedString()
    }

    static func openBase64(ciphertext: String, keyData: Data, aad: Data) throws -> Data {
        guard let combined = Data(base64Encoded: ciphertext) else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        return try PlatformCrypto.openAESGCM(
            combined: combined,
            keyData: keyData,
            authenticating: aad
        )
    }

    static func sealCombined(
        plaintext: Data,
        key: PlatformSymmetricKey,
        aad: Data
    ) throws -> Data {
        try PlatformCrypto.sealAESGCM(plaintext: plaintext, key: key, authenticating: aad)
    }

    static func openCombined(
        combined: Data,
        key: PlatformSymmetricKey,
        aad: Data
    ) throws -> Data {
        try PlatformCrypto.openAESGCM(combined: combined, key: key, authenticating: aad)
    }
}

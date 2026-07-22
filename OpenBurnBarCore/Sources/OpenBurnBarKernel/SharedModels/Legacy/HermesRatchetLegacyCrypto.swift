import Foundation

enum HermesRatchetLegacyCrypto {
    private static let rootInfo = Data("OpenBurnBar-HermesRatchet-v1-root".utf8)
    private static let chainLabel = Data("OpenBurnBar-HermesRatchet-v1-chain".utf8)
    private static let messageLabel = Data("OpenBurnBar-HermesRatchet-v1-message".utf8)

    static func rootKDFBytes(rootKey: Data, dhOutput: Data) throws -> Data {
        try PlatformCrypto.deriveHKDFSHA256KeyData(
            inputKeyMaterial: dhOutput,
            salt: rootKey,
            info: rootInfo,
            outputByteCount: 64
        )
    }

    static func nextChainKey(_ chainKey: Data) throws -> Data {
        try PlatformCrypto.hmacSHA256(chainLabel, keyData: chainKey)
    }

    static func messageKey(_ chainKey: Data) throws -> Data {
        try PlatformCrypto.hmacSHA256(messageLabel, keyData: chainKey)
    }

    static func envelopeAAD(header: HermesRatchetHeader, associatedData: Data) -> Data {
        var data = Data("OpenBurnBar-HermesRatchet-v1-AAD".utf8)
        appendPart(&data, associatedData)
        appendPart(&data, Data(header.algorithm.utf8))
        appendPart(&data, Data(header.sessionID.utf8))
        appendPart(&data, Data(header.senderDeviceID.utf8))
        appendPart(&data, Data(header.receiverDeviceID.utf8))
        appendPart(&data, Data(header.ratchetPublicKeyBase64.utf8))
        appendInt(&data, header.version)
        appendInt(&data, header.previousChainLength)
        appendInt(&data, header.messageNumber)
        appendInt(&data, header.epoch)
        return data
    }

    static func seal(plaintext: Data, key: Data, aad: Data) throws -> Data {
        try PlatformCrypto.sealAESGCM(plaintext: plaintext, keyData: key, authenticating: aad)
    }

    static func open(combined: Data, key: Data, aad: Data) throws -> Data {
        try PlatformCrypto.openAESGCM(combined: combined, keyData: key, authenticating: aad)
    }

    private static func appendPart(_ data: inout Data, _ part: Data) {
        appendInt(&data, part.count)
        data.append(part)
    }

    private static func appendInt(_ data: inout Data, _ value: Int) {
        var bigEndian = UInt64(value).bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

import CryptoKit
import Foundation
import Security

public enum HermesRatchetError: Error, Equatable {
    case invalidBase64(String)
    case invalidKeyLength(String)
    case invalidPublicKey(String)
    case invalidPrivateKey(String)
    case missingRemoteRatchetKey
    case missingSendingChain
    case missingReceivingChain
    case tooManySkippedKeys
    case skippedKeyLimitExceeded
    case invalidEnvelope
    case authenticationFailed
}

public enum HermesRatchetRole: String, Codable, Sendable {
    case initiator
    case responder
}

public struct HermesRatchetKeyPair: Codable, Hashable, Sendable {
    public let privateKeyBase64: String
    public let publicKeyBase64: String

    public init(privateKeyBase64: String, publicKeyBase64: String) {
        self.privateKeyBase64 = privateKeyBase64
        self.publicKeyBase64 = publicKeyBase64
    }
}

public struct HermesRatchetHeader: Codable, Hashable, Sendable {
    public let version: Int
    public let algorithm: String
    public let sessionID: String
    public let senderDeviceID: String
    public let receiverDeviceID: String
    public let ratchetPublicKeyBase64: String
    public let previousChainLength: Int
    public let messageNumber: Int
    public let epoch: Int

    public init(
        version: Int = HermesRatchetCrypto.version,
        algorithm: String = HermesRatchetCrypto.algorithm,
        sessionID: String,
        senderDeviceID: String,
        receiverDeviceID: String,
        ratchetPublicKeyBase64: String,
        previousChainLength: Int,
        messageNumber: Int,
        epoch: Int
    ) {
        self.version = version
        self.algorithm = algorithm
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.receiverDeviceID = receiverDeviceID
        self.ratchetPublicKeyBase64 = ratchetPublicKeyBase64
        self.previousChainLength = previousChainLength
        self.messageNumber = messageNumber
        self.epoch = epoch
    }
}

public struct HermesRatchetEnvelope: Codable, Hashable, Sendable {
    public let header: HermesRatchetHeader
    public let ciphertextBase64: String

    public init(header: HermesRatchetHeader, ciphertextBase64: String) {
        self.header = header
        self.ciphertextBase64 = ciphertextBase64
    }
}

public struct HermesRatchetSessionState: Codable, Hashable, Sendable {
    public var role: HermesRatchetRole
    public var sessionID: String
    public var localDeviceID: String
    public var remoteDeviceID: String
    public var rootKeyBase64: String
    public var sendingChainKeyBase64: String?
    public var receivingChainKeyBase64: String?
    public var sendingRatchetPrivateKeyBase64: String
    public var remoteRatchetPublicKeyBase64: String?
    public var sendMessageNumber: Int
    public var receiveMessageNumber: Int
    public var previousSendingChainLength: Int
    public var epoch: Int
    public var maxSkip: Int
    public var skippedMessageKeys: [String: String]

    public init(
        role: HermesRatchetRole,
        sessionID: String,
        localDeviceID: String,
        remoteDeviceID: String,
        rootKeyBase64: String,
        sendingChainKeyBase64: String? = nil,
        receivingChainKeyBase64: String? = nil,
        sendingRatchetPrivateKeyBase64: String,
        remoteRatchetPublicKeyBase64: String? = nil,
        sendMessageNumber: Int = 0,
        receiveMessageNumber: Int = 0,
        previousSendingChainLength: Int = 0,
        epoch: Int = 0,
        maxSkip: Int = HermesRatchetCrypto.defaultMaxSkip,
        skippedMessageKeys: [String: String] = [:]
    ) {
        self.role = role
        self.sessionID = sessionID
        self.localDeviceID = localDeviceID
        self.remoteDeviceID = remoteDeviceID
        self.rootKeyBase64 = rootKeyBase64
        self.sendingChainKeyBase64 = sendingChainKeyBase64
        self.receivingChainKeyBase64 = receivingChainKeyBase64
        self.sendingRatchetPrivateKeyBase64 = sendingRatchetPrivateKeyBase64
        self.remoteRatchetPublicKeyBase64 = remoteRatchetPublicKeyBase64
        self.sendMessageNumber = sendMessageNumber
        self.receiveMessageNumber = receiveMessageNumber
        self.previousSendingChainLength = previousSendingChainLength
        self.epoch = epoch
        self.maxSkip = maxSkip
        self.skippedMessageKeys = skippedMessageKeys
    }
}

public enum HermesRatchetCrypto {
    public static let version = 1
    public static let algorithm = "OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM"
    public static let defaultMaxSkip = 64

    public static func generateKeyPair() -> HermesRatchetKeyPair {
        let key = P256.KeyAgreement.PrivateKey()
        return HermesRatchetKeyPair(
            privateKeyBase64: key.rawRepresentation.base64EncodedString(),
            publicKeyBase64: key.publicKey.x963Representation.base64EncodedString()
        )
    }

    public static func randomRootKey() throws -> Data {
        var data = Data(repeating: 0, count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw HermesRatchetError.invalidKeyLength("SecRandomCopyBytes failed")
        }
        return data
    }

    public static func initiatorState(
        sessionID: String,
        localDeviceID: String,
        remoteDeviceID: String,
        sharedSecret: Data,
        remoteInitialRatchetPublicKeyBase64: String,
        localInitialRatchetKeyPair: HermesRatchetKeyPair = generateKeyPair(),
        maxSkip: Int = defaultMaxSkip
    ) throws -> HermesRatchetSessionState {
        try validateSymmetricKey(sharedSecret, label: "sharedSecret")
        let localPrivateKey = try privateKey(from: localInitialRatchetKeyPair.privateKeyBase64)
        let remotePublicKey = try publicKey(from: remoteInitialRatchetPublicKeyBase64)
        let dhOutput = try sharedSecretBytes(privateKey: localPrivateKey, publicKey: remotePublicKey)
        let derived = rootKDF(rootKey: sharedSecret, dhOutput: dhOutput)
        return HermesRatchetSessionState(
            role: .initiator,
            sessionID: sessionID,
            localDeviceID: localDeviceID,
            remoteDeviceID: remoteDeviceID,
            rootKeyBase64: derived.rootKey.base64EncodedString(),
            sendingChainKeyBase64: derived.chainKey.base64EncodedString(),
            sendingRatchetPrivateKeyBase64: localInitialRatchetKeyPair.privateKeyBase64,
            remoteRatchetPublicKeyBase64: remoteInitialRatchetPublicKeyBase64,
            maxSkip: maxSkip
        )
    }

    public static func responderState(
        sessionID: String,
        localDeviceID: String,
        remoteDeviceID: String,
        sharedSecret: Data,
        localInitialRatchetKeyPair: HermesRatchetKeyPair,
        maxSkip: Int = defaultMaxSkip
    ) throws -> HermesRatchetSessionState {
        try validateSymmetricKey(sharedSecret, label: "sharedSecret")
        _ = try privateKey(from: localInitialRatchetKeyPair.privateKeyBase64)
        return HermesRatchetSessionState(
            role: .responder,
            sessionID: sessionID,
            localDeviceID: localDeviceID,
            remoteDeviceID: remoteDeviceID,
            rootKeyBase64: sharedSecret.base64EncodedString(),
            sendingRatchetPrivateKeyBase64: localInitialRatchetKeyPair.privateKeyBase64,
            maxSkip: maxSkip
        )
    }

    public static func encrypt(
        plaintext: Data,
        state: inout HermesRatchetSessionState,
        associatedData: Data = Data()
    ) throws -> HermesRatchetEnvelope {
        guard let sendingChainKeyBase64 = state.sendingChainKeyBase64 else {
            throw HermesRatchetError.missingSendingChain
        }
        let sendingChainKey = try symmetricKeyData(fromBase64: sendingChainKeyBase64, label: "sendingChainKey")
        let derived = chainKDF(chainKey: sendingChainKey)
        let privateKey = try privateKey(from: state.sendingRatchetPrivateKeyBase64)
        let header = HermesRatchetHeader(
            sessionID: state.sessionID,
            senderDeviceID: state.localDeviceID,
            receiverDeviceID: state.remoteDeviceID,
            ratchetPublicKeyBase64: privateKey.publicKey.x963Representation.base64EncodedString(),
            previousChainLength: state.previousSendingChainLength,
            messageNumber: state.sendMessageNumber,
            epoch: state.epoch
        )
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: derived.messageKey),
            authenticating: envelopeAAD(header: header, associatedData: associatedData)
        )
        guard let combined = sealed.combined else {
            throw HermesRatchetError.invalidEnvelope
        }
        state.sendingChainKeyBase64 = derived.chainKey.base64EncodedString()
        state.sendMessageNumber += 1
        return HermesRatchetEnvelope(header: header, ciphertextBase64: combined.base64EncodedString())
    }

    public static func decrypt(
        _ envelope: HermesRatchetEnvelope,
        state: inout HermesRatchetSessionState,
        associatedData: Data = Data()
    ) throws -> Data {
        try validateHeader(envelope.header, state: state)
        let skippedKey = skippedKeyID(
            ratchetPublicKeyBase64: envelope.header.ratchetPublicKeyBase64,
            messageNumber: envelope.header.messageNumber
        )
        if let keyBase64 = state.skippedMessageKeys.removeValue(forKey: skippedKey) {
            let messageKey = try symmetricKeyData(fromBase64: keyBase64, label: "skippedMessageKey")
            return try open(envelope, messageKey: messageKey, associatedData: associatedData)
        }

        if state.remoteRatchetPublicKeyBase64 != envelope.header.ratchetPublicKeyBase64 {
            if let remote = state.remoteRatchetPublicKeyBase64 {
                try skipMessageKeys(
                    until: envelope.header.previousChainLength,
                    remoteRatchetPublicKeyBase64: remote,
                    state: &state
                )
            }
            try dhRatchet(remoteRatchetPublicKeyBase64: envelope.header.ratchetPublicKeyBase64, state: &state)
        }

        try skipMessageKeys(
            until: envelope.header.messageNumber,
            remoteRatchetPublicKeyBase64: envelope.header.ratchetPublicKeyBase64,
            state: &state
        )
        guard let receivingChainKeyBase64 = state.receivingChainKeyBase64 else {
            throw HermesRatchetError.missingReceivingChain
        }
        let receivingChainKey = try symmetricKeyData(fromBase64: receivingChainKeyBase64, label: "receivingChainKey")
        let derived = chainKDF(chainKey: receivingChainKey)
        let plaintext = try open(envelope, messageKey: derived.messageKey, associatedData: associatedData)
        state.receivingChainKeyBase64 = derived.chainKey.base64EncodedString()
        state.receiveMessageNumber += 1
        return plaintext
    }

    private static func dhRatchet(
        remoteRatchetPublicKeyBase64: String,
        state: inout HermesRatchetSessionState
    ) throws {
        let currentPrivateKey = try privateKey(from: state.sendingRatchetPrivateKeyBase64)
        let remotePublicKey = try publicKey(from: remoteRatchetPublicKeyBase64)
        let rootKey = try symmetricKeyData(fromBase64: state.rootKeyBase64, label: "rootKey")
        let receiveDerived = rootKDF(
            rootKey: rootKey,
            dhOutput: try sharedSecretBytes(privateKey: currentPrivateKey, publicKey: remotePublicKey)
        )
        let nextPrivateKey = P256.KeyAgreement.PrivateKey()
        let sendDerived = rootKDF(
            rootKey: receiveDerived.rootKey,
            dhOutput: try sharedSecretBytes(privateKey: nextPrivateKey, publicKey: remotePublicKey)
        )
        state.previousSendingChainLength = state.sendMessageNumber
        state.sendMessageNumber = 0
        state.receiveMessageNumber = 0
        state.epoch += 1
        state.remoteRatchetPublicKeyBase64 = remoteRatchetPublicKeyBase64
        state.rootKeyBase64 = sendDerived.rootKey.base64EncodedString()
        state.receivingChainKeyBase64 = receiveDerived.chainKey.base64EncodedString()
        state.sendingChainKeyBase64 = sendDerived.chainKey.base64EncodedString()
        state.sendingRatchetPrivateKeyBase64 = nextPrivateKey.rawRepresentation.base64EncodedString()
    }

    private static func skipMessageKeys(
        until messageNumber: Int,
        remoteRatchetPublicKeyBase64: String,
        state: inout HermesRatchetSessionState
    ) throws {
        guard messageNumber >= state.receiveMessageNumber else { return }
        guard messageNumber - state.receiveMessageNumber <= state.maxSkip else {
            throw HermesRatchetError.tooManySkippedKeys
        }
        guard var receivingChainKey = try state.receivingChainKeyBase64.map({
            try symmetricKeyData(fromBase64: $0, label: "receivingChainKey")
        }) else {
            if messageNumber == state.receiveMessageNumber { return }
            throw HermesRatchetError.missingReceivingChain
        }
        while state.receiveMessageNumber < messageNumber {
            let derived = chainKDF(chainKey: receivingChainKey)
            let key = skippedKeyID(
                ratchetPublicKeyBase64: remoteRatchetPublicKeyBase64,
                messageNumber: state.receiveMessageNumber
            )
            guard state.skippedMessageKeys.count < state.maxSkip else {
                throw HermesRatchetError.skippedKeyLimitExceeded
            }
            state.skippedMessageKeys[key] = derived.messageKey.base64EncodedString()
            receivingChainKey = derived.chainKey
            state.receiveMessageNumber += 1
        }
        state.receivingChainKeyBase64 = receivingChainKey.base64EncodedString()
    }

    private static func open(
        _ envelope: HermesRatchetEnvelope,
        messageKey: Data,
        associatedData: Data
    ) throws -> Data {
        guard let combined = Data(base64Encoded: envelope.ciphertextBase64) else {
            throw HermesRatchetError.invalidEnvelope
        }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(
                box,
                using: SymmetricKey(data: messageKey),
                authenticating: envelopeAAD(header: envelope.header, associatedData: associatedData)
            )
        } catch {
            throw HermesRatchetError.authenticationFailed
        }
    }

    private static func validateHeader(_ header: HermesRatchetHeader, state: HermesRatchetSessionState) throws {
        guard header.version == version,
              header.algorithm == algorithm,
              header.sessionID == state.sessionID,
              header.receiverDeviceID == state.localDeviceID,
              header.senderDeviceID == state.remoteDeviceID,
              header.messageNumber >= 0,
              header.previousChainLength >= 0,
              header.epoch >= 0 else {
            throw HermesRatchetError.invalidEnvelope
        }
        _ = try publicKey(from: header.ratchetPublicKeyBase64)
    }

    private static func rootKDF(rootKey: Data, dhOutput: Data) -> (rootKey: Data, chainKey: Data) {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dhOutput),
            salt: rootKey,
            info: Data("OpenBurnBar-HermesRatchet-v1-root".utf8),
            outputByteCount: 64
        )
        let data = data(from: derived)
        return (Data(data.prefix(32)), Data(data.suffix(32)))
    }

    private static func chainKDF(chainKey: Data) -> (chainKey: Data, messageKey: Data) {
        let key = SymmetricKey(data: chainKey)
        let next = Data(HMAC<SHA256>.authenticationCode(for: Data("OpenBurnBar-HermesRatchet-v1-chain".utf8), using: key))
        let message = Data(HMAC<SHA256>.authenticationCode(for: Data("OpenBurnBar-HermesRatchet-v1-message".utf8), using: key))
        return (next, message)
    }

    private static func envelopeAAD(header: HermesRatchetHeader, associatedData: Data) -> Data {
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

    private static func skippedKeyID(ratchetPublicKeyBase64: String, messageNumber: Int) -> String {
        "\(ratchetPublicKeyBase64):\(messageNumber)"
    }

    private static func privateKey(from base64: String) throws -> P256.KeyAgreement.PrivateKey {
        guard let data = Data(base64Encoded: base64) else {
            throw HermesRatchetError.invalidBase64("privateKey")
        }
        guard data.count == 32 else {
            throw HermesRatchetError.invalidKeyLength("privateKey")
        }
        do {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        } catch {
            throw HermesRatchetError.invalidPrivateKey("privateKey")
        }
    }

    private static func publicKey(from base64: String) throws -> P256.KeyAgreement.PublicKey {
        guard let data = Data(base64Encoded: base64) else {
            throw HermesRatchetError.invalidBase64("publicKey")
        }
        guard data.count == 65 else {
            throw HermesRatchetError.invalidKeyLength("publicKey")
        }
        do {
            return try P256.KeyAgreement.PublicKey(x963Representation: data)
        } catch {
            throw HermesRatchetError.invalidPublicKey("publicKey")
        }
    }

    private static func sharedSecretBytes(
        privateKey: P256.KeyAgreement.PrivateKey,
        publicKey: P256.KeyAgreement.PublicKey
    ) throws -> Data {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        var data = Data()
        secret.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func symmetricKeyData(fromBase64 base64: String, label: String) throws -> Data {
        guard let data = Data(base64Encoded: base64) else {
            throw HermesRatchetError.invalidBase64(label)
        }
        try validateSymmetricKey(data, label: label)
        return data
    }

    private static func validateSymmetricKey(_ data: Data, label: String) throws {
        guard data.count == 32 else {
            throw HermesRatchetError.invalidKeyLength(label)
        }
    }

    private static func data(from key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private static func appendPart(_ data: inout Data, _ part: Data) {
        appendInt(&data, part.count)
        data.append(part)
    }

    private static func appendInt(_ data: inout Data, _ value: Int) {
        var be = UInt64(value).bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
}

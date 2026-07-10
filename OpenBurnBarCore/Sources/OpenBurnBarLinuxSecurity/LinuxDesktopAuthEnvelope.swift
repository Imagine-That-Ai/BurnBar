import Crypto
import Foundation

public enum LinuxDesktopAuthEnvelopeError: Error, Equatable, Sendable {
    case invalidFlowBinding
    case unsupportedAlgorithm
    case invalidAdditionalAuthenticatedData
    case invalidPublicKey
    case invalidNonce
    case invalidAuthenticationTag
    case invalidCiphertext
    case authenticationFailed
}

public struct LinuxDesktopAuthCredentialDelivery: Codable, Equatable, Sendable {
    public let algorithm: String
    public let publicKeyBase64: String
    public let flowBinding: String

    public init(algorithm: String, publicKeyBase64: String, flowBinding: String) {
        self.algorithm = algorithm
        self.publicKeyBase64 = publicKeyBase64
        self.flowBinding = flowBinding
    }
}

public struct LinuxDesktopAuthCredentialEnvelope: Codable, Equatable, Sendable {
    public let algorithm: String
    public let ephemeralPublicKeyBase64: String
    public let ivBase64: String
    public let ciphertextBase64: String
    public let authTagBase64: String
    public let aad: String

    public init(
        algorithm: String,
        ephemeralPublicKeyBase64: String,
        ivBase64: String,
        ciphertextBase64: String,
        authTagBase64: String,
        aad: String
    ) {
        self.algorithm = algorithm
        self.ephemeralPublicKeyBase64 = ephemeralPublicKeyBase64
        self.ivBase64 = ivBase64
        self.ciphertextBase64 = ciphertextBase64
        self.authTagBase64 = authTagBase64
        self.aad = aad
    }
}

public struct LinuxDesktopAuthDeliveryKey {
    public static let algorithm = "p256-ecdh-aes-256-gcm-v2"
    public static let keyContext = "OpenBurnBar desktop auth credential delivery v2"
    public static let aadPrefix = "openburnbar:desktop-auth:credential-delivery:v2:"

    private let privateKey: P256.KeyAgreement.PrivateKey

    public init() {
        privateKey = P256.KeyAgreement.PrivateKey()
    }

    public init(rawPrivateKey: Data) throws {
        privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    public func credentialDelivery(flowBinding: String) throws -> LinuxDesktopAuthCredentialDelivery {
        guard Self.isValidFlowBinding(flowBinding) else {
            throw LinuxDesktopAuthEnvelopeError.invalidFlowBinding
        }
        return LinuxDesktopAuthCredentialDelivery(
            algorithm: Self.algorithm,
            publicKeyBase64: privateKey.publicKey.x963Representation.base64EncodedString(),
            flowBinding: flowBinding
        )
    }

    public func open(
        _ envelope: LinuxDesktopAuthCredentialEnvelope,
        flowBinding: String
    ) throws -> Data {
        guard Self.isValidFlowBinding(flowBinding) else {
            throw LinuxDesktopAuthEnvelopeError.invalidFlowBinding
        }
        guard envelope.algorithm == Self.algorithm else {
            throw LinuxDesktopAuthEnvelopeError.unsupportedAlgorithm
        }
        let expectedAAD = Self.aadPrefix + flowBinding
        guard envelope.aad == expectedAAD else {
            throw LinuxDesktopAuthEnvelopeError.invalidAdditionalAuthenticatedData
        }
        guard let publicKeyData = Self.canonicalBase64Data(envelope.ephemeralPublicKeyBase64),
              publicKeyData.count == 65,
              publicKeyData.first == 0x04,
              let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: publicKeyData),
              publicKey.x963Representation == publicKeyData else {
            throw LinuxDesktopAuthEnvelopeError.invalidPublicKey
        }
        guard let iv = Self.canonicalBase64Data(envelope.ivBase64), iv.count == 12 else {
            throw LinuxDesktopAuthEnvelopeError.invalidNonce
        }
        guard let tag = Self.canonicalBase64Data(envelope.authTagBase64), tag.count == 16 else {
            throw LinuxDesktopAuthEnvelopeError.invalidAuthenticationTag
        }
        guard let ciphertext = Self.canonicalBase64Data(envelope.ciphertextBase64),
              !ciphertext.isEmpty,
              ciphertext.count <= 32_768 else {
            throw LinuxDesktopAuthEnvelopeError.invalidCiphertext
        }

        do {
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            let key = Self.deliveryKey(sharedSecret: sharedSecret)
            let nonce = try AES.GCM.Nonce(data: iv)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: Data(expectedAAD.utf8)
            )
        } catch let error as LinuxDesktopAuthEnvelopeError {
            throw error
        } catch {
            throw LinuxDesktopAuthEnvelopeError.authenticationFailed
        }
    }

    private static func deliveryKey(sharedSecret: SharedSecret) -> SymmetricKey {
        var input = Data(keyContext.utf8)
        input.append(0)
        sharedSecret.withUnsafeBytes { input.append(contentsOf: $0) }
        return SymmetricKey(data: Data(SHA256.hash(data: input)))
    }

    private static func isValidFlowBinding(_ value: String) -> Bool {
        guard value.count <= 128, let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }

    private static func canonicalBase64Data(_ value: String) -> Data? {
        guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else { return nil }
        return data
    }
}

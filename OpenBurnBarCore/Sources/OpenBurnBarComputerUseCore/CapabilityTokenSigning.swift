import Foundation
import CryptoKit

/// Ed25519 signing and verification for `CapabilityToken` payloads.
///
/// Wire layout:
/// ```
/// signature = Ed25519.sign(privKey, UTF-8(canonicalJSON(tokenFieldsWithoutSignature)))
/// ```
public struct CapabilityTokenSigner: Sendable {
    public init() {}

    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CapabilityToken.canonicalDateString(date))
        }
        return encoder
    }()

    /// Fields included in the signed body (everything except the signature).
    public struct SignableBody: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var domain: CapabilityToken.Domain
        public var nonce: String
        public var issuedAt: Date
        public var expiresAt: Date
        public var allowedActionKinds: [String]
        public var scopeHash: String
        public var actionBudget: Int
        public var boundEscrowDeviceId: String?
        public var attestationHashBlake3: String?

        public init(token: CapabilityToken) {
            schemaVersion = token.schemaVersion
            domain = token.domain
            nonce = token.nonce
            issuedAt = token.issuedAt
            expiresAt = token.expiresAt
            allowedActionKinds = token.allowedActionKinds
            scopeHash = token.scopeHash
            actionBudget = token.actionBudget
            boundEscrowDeviceId = token.boundEscrowDeviceId
            attestationHashBlake3 = token.attestationHashBlake3
        }
    }

    public func canonicalSignableBytes(token: CapabilityToken) throws -> Data {
        try Self.canonicalEncoder.encode(SignableBody(token: token))
    }

    public func sign(
        token: CapabilityToken,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> CapabilityToken {
        var signed = token
        let payload = try canonicalSignableBytes(token: token)
        let signature = try privateKey.signature(for: payload)
        signed.signatureEd25519Base64 = signature.base64EncodedString()
        return signed
    }

    public func verify(
        token: CapabilityToken,
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> Bool {
        guard let signatureBase64 = token.signatureEd25519Base64,
              let signature = Data(base64Encoded: signatureBase64) else {
            return false
        }
        let payload = try canonicalSignableBytes(token: token)
        return publicKey.isValidSignature(signature, for: payload)
    }
}

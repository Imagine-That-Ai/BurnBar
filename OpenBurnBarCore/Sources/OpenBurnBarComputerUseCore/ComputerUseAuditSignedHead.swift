import Foundation
import CryptoKit

/// Terminal audit chain head with an Ed25519 signature for offline verification (WS3).
public struct ComputerUseAuditSignedHead: Codable, Hashable, Sendable {
    public static let schemaVersion: Int = 1

    public let schemaVersion: Int
    public let sessionId: String
    public let lastEntryIndex: Int
    public let headHashHex: String
    public let closedAt: Date
    public let signatureEd25519Base64: String
    public let signerPublicKeyEd25519Base64: String

    public init(
        sessionId: String,
        lastEntryIndex: Int,
        headHashHex: String,
        closedAt: Date,
        signatureEd25519Base64: String,
        signerPublicKeyEd25519Base64: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.sessionId = sessionId
        self.lastEntryIndex = lastEntryIndex
        self.headHashHex = headHashHex
        self.closedAt = closedAt
        self.signatureEd25519Base64 = signatureEd25519Base64
        self.signerPublicKeyEd25519Base64 = signerPublicKeyEd25519Base64
    }

    /// Canonical payload bytes signed by the Mac audit exporter.
    public var signingPayload: Data {
        get throws {
            struct Payload: Encodable {
                let sessionId: String
                let lastEntryIndex: Int
                let headHashHex: String
                let closedAtMs: Int64
            }
            let ms = Int64((closedAt.timeIntervalSince1970 * 1000).rounded())
            let payload = Payload(
                sessionId: sessionId,
                lastEntryIndex: lastEntryIndex,
                headHashHex: headHashHex,
                closedAtMs: ms
            )
            return try ComputerUseAuditHasher.canonicalJSONEncoder.encode(payload)
        }
    }

    public func verifySignature() throws -> Bool {
        guard let signature = Data(base64Encoded: signatureEd25519Base64),
              let publicKeyData = Data(base64Encoded: signerPublicKeyEd25519Base64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        let payload = try signingPayload
        return publicKey.isValidSignature(signature, for: payload)
    }
}

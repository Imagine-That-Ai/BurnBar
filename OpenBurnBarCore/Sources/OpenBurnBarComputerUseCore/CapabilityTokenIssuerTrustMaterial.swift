import Foundation
import CryptoKit

/// Published issuer trust for offline bridge verification (public key only).
public struct CapabilityTokenIssuerTrustMaterial: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var keyId: String
    public var publicKeyEd25519Base64: String
    public var revoked: Bool
    public var publishedAt: String

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        keyId: String,
        publicKeyEd25519Base64: String,
        revoked: Bool = false,
        publishedAt: String = CapabilityToken.canonicalDateString(Date())
    ) {
        self.schemaVersion = schemaVersion
        self.keyId = keyId
        self.publicKeyEd25519Base64 = publicKeyEd25519Base64
        self.revoked = revoked
        self.publishedAt = publishedAt
    }

    public func signingPublicKey() throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: publicKeyEd25519Base64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
            throw CapabilityTokenVerificationFailure.issuerKeyUnavailable
        }
        return key
    }

    public func issuerTrust() throws -> CapabilityTokenIssuerTrust {
        CapabilityTokenIssuerTrust(
            publicKey: try signingPublicKey(),
            keyId: keyId,
            revoked: revoked
        )
    }

    public static func load(from path: String = RemoteUnlockSetupProbe.capabilityTokenIssuerTrustPath) -> CapabilityTokenIssuerTrustMaterial? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let material = try? JSONDecoder().decode(CapabilityTokenIssuerTrustMaterial.self, from: data) else {
            return nil
        }
        return material
    }

    public func write(to path: String = RemoteUnlockSetupProbe.capabilityTokenIssuerTrustPath) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }
}

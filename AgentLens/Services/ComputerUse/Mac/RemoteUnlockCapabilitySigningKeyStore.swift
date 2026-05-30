#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore
import Security

/// Certification-provisioned Ed25519 issuer for Remote Unlock capability tokens.
///
/// The private key lives in the login keychain (device-only, after-first-unlock). The
/// corresponding public trust material is published for offline bridge verification.
public final class RemoteUnlockCapabilitySigningKeyStore: @unchecked Sendable {
    public static let shared = RemoteUnlockCapabilitySigningKeyStore()

    public struct KeyMaterial: Sendable, Equatable {
        public var keyId: String
        public var publicKey: Curve25519.Signing.PublicKey
        public var privateKey: Curve25519.Signing.PrivateKey
    }

    private let service = "com.openburnbar.remote-unlock.capability-token-issuer"
    private let account = "default"
    private let queue = DispatchQueue(label: "com.openburnbar.remote-unlock.capability-issuer")

    public func copyOrCreateKeyMaterial() throws -> KeyMaterial {
        try queue.sync {
            if let data = try copyPrivateKeyData() {
                return try material(fromPrivateKeyData: data)
            }
            let privateKey = Curve25519.Signing.PrivateKey()
            try savePrivateKeyData(privateKey.rawRepresentation)
            return try material(fromPrivateKeyData: privateKey.rawRepresentation)
        }
    }

    public func publishIssuerTrust(revoked: Bool = false) throws {
        let material = try copyOrCreateKeyMaterial()
        let trust = CapabilityTokenIssuerTrustMaterial(
            keyId: material.keyId,
            publicKeyEd25519Base64: material.publicKey.rawRepresentation.base64EncodedString(),
            revoked: revoked
        )
        try trust.write()
    }

    public func revokePublishedTrust() throws {
        try publishIssuerTrust(revoked: true)
    }

    private func material(fromPrivateKeyData data: Data) throws -> KeyMaterial {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let keyId = SHA256.hash(data: publicKeyData)
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return KeyMaterial(
            keyId: "cap-\(keyId)",
            publicKey: privateKey.publicKey,
            privateKey: privateKey
        )
    }

    private func copyPrivateKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return item as? Data
    }

    private func savePrivateKeyData(_ data: Data) throws {
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private struct KeychainError: Error {
        let status: OSStatus
    }
}
#endif

#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore
import Security

/// In-process PDP mint for Computer Use domain capability tokens (post-unlock, fail-closed at leaf).
@MainActor
public final class ComputerUseCapabilityTokenService {
    public static let shared = ComputerUseCapabilityTokenService()

    private let issuer = CapabilityTokenIssuer()
    private let signingKeyStore = ComputerUseCapabilitySigningKeyStore()

    public func mintMacInputToken(
        sessionId: ComputerUseSessionID,
        actionKind: String,
        actionBudget: Int = 1,
        attestationHashBlake3: String? = nil,
        boundEscrowDeviceId: String? = nil,
        now: Date = Date()
    ) throws -> CapabilityToken {
        let keyMaterial = try signingKeyStore.copyOrCreateKeyMaterial()
        let scopeHash = SHA256.hash(data: Data("computer_use:\(sessionId.rawValue)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try issuer.mintComputerUseToken(
            privateKey: keyMaterial.privateKey,
            scopeHash: scopeHash,
            allowedActionKinds: [actionKind],
            actionBudget: actionBudget,
            attestationHashBlake3: attestationHashBlake3,
            boundEscrowDeviceId: boundEscrowDeviceId
        )
    }
}

/// Device-only Ed25519 issuer for Computer Use capability tokens (separate from Remote Unlock issuer).
final class ComputerUseCapabilitySigningKeyStore: Sendable {
    private let service = "com.openburnbar.computer-use.capability-token-issuer"
    private let account = "default"
    private let queue = DispatchQueue(label: "com.openburnbar.computer-use.capability-issuer")

    struct KeyMaterial: Sendable {
        var keyId: String
        var privateKey: Curve25519.Signing.PrivateKey
    }

    func copyOrCreateKeyMaterial() throws -> KeyMaterial {
        try queue.sync {
            if let data = try copyPrivateKeyData() {
                return try material(from: data)
            }
            let privateKey = Curve25519.Signing.PrivateKey()
            try savePrivateKeyData(privateKey.rawRepresentation)
            return try material(from: privateKey.rawRepresentation)
        }
    }

    private func material(from data: Data) throws -> KeyMaterial {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        let keyId = SHA256.hash(data: privateKey.publicKey.rawRepresentation)
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return KeyMaterial(keyId: "cu-\(keyId)", privateKey: privateKey)
    }

    private func copyPrivateKeyData() throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return item as? Data
    }

    private func savePrivateKeyData(_ data: Data) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private struct KeychainError: Error {
        let status: OSStatus
    }
}
#endif

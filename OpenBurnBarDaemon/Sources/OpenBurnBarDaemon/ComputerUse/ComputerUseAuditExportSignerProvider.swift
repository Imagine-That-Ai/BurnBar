import CryptoKit
import Foundation
import LocalAuthentication
import OpenBurnBarComputerUseCore
import Security

public protocol ComputerUseAuditExportSignerProviding: Sendable {
    func signer() throws -> ComputerUseEd25519AuditExportSigner
}

protocol ComputerUseAuditExportKeyStoring: Sendable {
    func data(service: String, account: String) throws -> Data?
    func set(_ data: Data, service: String, account: String) throws
}

struct ComputerUseAuditExportSecurityKeyStore: ComputerUseAuditExportKeyStoring {
    func data(service: String, account: String) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound
            || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
            || status == errSecAuthFailed {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ComputerUseAuditExportSignerStoreError.keychainStatus(status)
        }
        return data
    }

    func set(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = withKeychainUserInteractionDisabled {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ComputerUseAuditExportSignerStoreError.keychainStatus(updateStatus)
        }

        var createQuery = query
        createQuery[kSecValueData as String] = data
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = withKeychainUserInteractionDisabled {
            SecItemAdd(createQuery as CFDictionary, nil)
        }
        guard addStatus == errSecSuccess else {
            throw ComputerUseAuditExportSignerStoreError.keychainStatus(addStatus)
        }
    }
}

public enum ComputerUseAuditExportSignerStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
    case invalidStoredKey
}

/// Trusted-device signer for Phase 13 audit exports.
///
/// The original implementation wrote an Ed25519 private key as a raw file
/// inside the audit directory. That made the archive signature portable but
/// weakened the claimed device provenance. This provider follows the repo's
/// iroh-pairing pattern instead: private key bytes live in the local Keychain
/// as `WhenUnlockedThisDeviceOnly`, while the signature sidecar carries the
/// public key and stable device-key fingerprint.
public struct ComputerUseKeychainAuditExportSignerProvider: ComputerUseAuditExportSignerProviding, @unchecked Sendable {
    public static let defaultService = "ai.openburnbar.computer-use.audit-export"
    public static let defaultAccount = "trusted-device-ed25519-v1"

    private let service: String
    private let account: String
    private let legacyRawKeyURL: URL?
    private let keyStore: any ComputerUseAuditExportKeyStoring
    private let fileManager: FileManager

    init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount,
        legacyRawKeyURL: URL? = nil,
        keyStore: any ComputerUseAuditExportKeyStoring = ComputerUseAuditExportSecurityKeyStore(),
        fileManager: FileManager = .default
    ) {
        self.service = service
        self.account = account
        self.legacyRawKeyURL = legacyRawKeyURL
        self.keyStore = keyStore
        self.fileManager = fileManager
    }

    public func signer() throws -> ComputerUseEd25519AuditExportSigner {
        let key = try loadOrCreateKey()
        let fingerprint = Data(SHA256.hash(data: key.publicKey.rawRepresentation))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return ComputerUseEd25519AuditExportSigner(
            privateKey: key,
            signerIdentifier: "openburnbar-trusted-device-ed25519-keychain-v1:\(fingerprint)",
            trustRoot: "openburnbar-trusted-device-keychain-v1"
        )
    }

    private func loadOrCreateKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try keyStore.data(service: service, account: account) {
            return try decodeKey(data)
        }

        if let migrated = try migrateLegacyRawKeyIfPresent() {
            return migrated
        }

        let fresh = Curve25519.Signing.PrivateKey()
        try keyStore.set(fresh.rawRepresentation, service: service, account: account)
        return fresh
    }

    private func migrateLegacyRawKeyIfPresent() throws -> Curve25519.Signing.PrivateKey? {
        guard let legacyRawKeyURL,
              fileManager.fileExists(atPath: legacyRawKeyURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: legacyRawKeyURL)
        let key = try decodeKey(data)
        try keyStore.set(key.rawRepresentation, service: service, account: account)
        try? fileManager.removeItem(at: legacyRawKeyURL)
        return key
    }

    private func decodeKey(_ data: Data) throws -> Curve25519.Signing.PrivateKey {
        guard data.count == 32 else {
            throw ComputerUseAuditExportSignerStoreError.invalidStoredKey
        }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw ComputerUseAuditExportSignerStoreError.invalidStoredKey
        }
    }
}

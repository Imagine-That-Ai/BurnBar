import CryptoKit
import Foundation
import LibSignalClient
import OpenBurnBarCore
import Security

public struct OpenBurnBarSignalIdentityKeypair: Sendable, Hashable {
    public let identityKeyId: String
    public let publicKeyData: Data
    public let privateKeyData: Data
    public let keyVersion: Int

    public static func generateInMemory(deviceId: String, keyVersion: Int = 1) -> OpenBurnBarSignalIdentityKeypair {
        let identity = IdentityKeyPair.generate()
        return OpenBurnBarSignalIdentityKeypair(
            identityKeyId: OpenBurnBarSignalIdentityKeyStore.identityKeyId(deviceId: deviceId, keyVersion: keyVersion),
            publicKeyData: identity.publicKey.serialize(),
            privateKeyData: identity.privateKey.serialize(),
            keyVersion: keyVersion
        )
    }

    public var publicKeyBase64: String {
        publicKeyData.base64EncodedString()
    }

    public var publicKeyFingerprint: String {
        Data(SHA256.hash(data: publicKeyData)).base64EncodedString()
    }

    public func atRestRecipient(kind: String = "device") -> OpenBurnBarSignalAtRestRecipient {
        OpenBurnBarSignalAtRestRecipient(
            recipientKind: kind,
            recipientIdentityKeyId: identityKeyId,
            publicKeyData: publicKeyData
        )
    }
}

public struct OpenBurnBarSignalIdentityKeyStore: Sendable {
    public static let defaultService = "com.openburnbar.signal-identity"

    private let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func loadOrCreate(uid: String, deviceId: String) throws -> OpenBurnBarSignalIdentityKeypair {
        let account = Self.account(uid: uid, deviceId: deviceId)
        if let existing = try load(account: account, deviceId: deviceId) {
            return existing
        }

        let identity = IdentityKeyPair.generate()
        let privateKeyData = identity.privateKey.serialize()
        try save(privateKeyData, keyVersion: 1, account: account)
        return try material(fromPrivateKeyData: privateKeyData, deviceId: deviceId, keyVersion: 1)
    }

    public func load(uid: String, deviceId: String) throws -> OpenBurnBarSignalIdentityKeypair? {
        try load(account: Self.account(uid: uid, deviceId: deviceId), deviceId: deviceId)
    }

    public static func identityKeyId(deviceId: String, keyVersion: Int) -> String {
        "\(deviceId)_\(keyVersion)"
    }

    public static func account(uid: String, deviceId: String) -> String {
        "signal-at-rest-identity:\(uid):\(deviceId)"
    }

    private func load(account: String, deviceId: String) throws -> OpenBurnBarSignalIdentityKeypair? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CloudVaultCryptoError.keychainError(Int(status))
        }
        guard let dict = item as? [String: Any],
              let privateKeyData = dict[kSecValueData as String] as? Data else {
            throw CloudVaultCryptoError.keychainDataMissing
        }
        let comment = dict[kSecAttrComment as String] as? String
        let keyVersion = comment.flatMap(Int.init) ?? 1
        return try material(fromPrivateKeyData: privateKeyData, deviceId: deviceId, keyVersion: keyVersion)
    }

    private func save(_ privateKeyData: Data, keyVersion: Int, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var create = query
        create[kSecValueData as String] = privateKeyData
        create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        create[kSecAttrComment as String] = "\(keyVersion)"
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(create as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CloudVaultCryptoError.keychainError(Int(status))
        }
    }

    private func material(
        fromPrivateKeyData privateKeyData: Data,
        deviceId: String,
        keyVersion: Int
    ) throws -> OpenBurnBarSignalIdentityKeypair {
        let privateKey = try PrivateKey(privateKeyData)
        return OpenBurnBarSignalIdentityKeypair(
            identityKeyId: Self.identityKeyId(deviceId: deviceId, keyVersion: keyVersion),
            publicKeyData: privateKey.publicKey.serialize(),
            privateKeyData: privateKeyData,
            keyVersion: keyVersion
        )
    }
}

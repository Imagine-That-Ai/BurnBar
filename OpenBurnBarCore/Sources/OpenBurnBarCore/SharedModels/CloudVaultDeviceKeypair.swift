import CryptoKit
import Foundation
import Security

public struct CloudVaultDeviceKeypair: DeviceKeypairProtocol, Sendable {
    private let privateKey: P256.KeyAgreement.PrivateKey
    public let keyVersion: Int

    public init(service: String = "com.openburnbar.device-escrow", account: String) throws {
        if let existing = try Self.load(service: service, account: account) {
            self.privateKey = existing.privateKey
            self.keyVersion = existing.keyVersion
            return
        }
        let created = P256.KeyAgreement.PrivateKey()
        try Self.save(created, keyVersion: 1, service: service, account: account)
        self.privateKey = created
        self.keyVersion = 1
    }

    public var publicKeyData: Data {
        privateKey.publicKey.x963Representation
    }

    public var publicKeyFingerprint: String {
        Data(SHA256.hash(data: publicKeyData)).base64EncodedString()
    }

    public func encrypt(_ plaintext: Data, for recipientPublicKey: Data) throws -> Data {
        try CloudVaultCrypto.wrapVaultKey(plaintext, recipientPublicKey: recipientPublicKey)
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        try CloudVaultCrypto.unwrapVaultKey(ciphertext, privateKey: privateKey)
    }

    private static func load(service: String, account: String) throws -> (privateKey: P256.KeyAgreement.PrivateKey, keyVersion: Int)? {
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
        guard status == errSecSuccess else { throw CloudVaultCryptoError.keychainError(Int(status)) }
        guard let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            throw CloudVaultCryptoError.keychainDataMissing
        }
        let comment = dict[kSecAttrComment as String] as? String
        let version = comment.flatMap(Int.init) ?? 1
        return (key, version)
    }

    private static func save(
        _ privateKey: P256.KeyAgreement.PrivateKey,
        keyVersion: Int,
        service: String,
        account: String
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var create = query
        create[kSecValueData as String] = privateKey.rawRepresentation
        create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        create[kSecAttrComment as String] = "\(keyVersion)"
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(create as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CloudVaultCryptoError.keychainError(Int(status))
        }
    }
}

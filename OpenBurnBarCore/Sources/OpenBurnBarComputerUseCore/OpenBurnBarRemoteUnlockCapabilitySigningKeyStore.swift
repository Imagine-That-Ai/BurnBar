import Foundation
import OpenBurnBarCore

public protocol RemoteUnlockCapabilityPrivateKeyStoring: Sendable {
    func data() throws -> Data?
    func set(_ data: Data) throws
}

public enum RemoteUnlockCapabilitySigningKeyStoreError: Error, Equatable {
    case secretStorageUnavailable
    case invalidStoredKey
}

public final class OpenBurnBarRemoteUnlockCapabilitySigningKeyStore: @unchecked Sendable {
    public static let defaultService = "com.openburnbar.remote-unlock.capability-token-issuer"
    public static let defaultAccount = "default"

    public struct KeyMaterial: Sendable {
        public var keyId: String
        public var publicKey: PlatformEd25519PublicKey
        public var privateKey: PlatformEd25519PrivateKey

        public init(
            keyId: String,
            publicKey: PlatformEd25519PublicKey,
            privateKey: PlatformEd25519PrivateKey
        ) {
            self.keyId = keyId
            self.publicKey = publicKey
            self.privateKey = privateKey
        }
    }

    private let keyStore: any RemoteUnlockCapabilityPrivateKeyStoring
    private let queue = DispatchQueue(label: "com.openburnbar.remote-unlock.capability-issuer.shared")

    public init(keyStore: (any RemoteUnlockCapabilityPrivateKeyStoring)? = nil) {
        self.keyStore = keyStore ?? Self.defaultKeyStore()
    }

    public func copyOrCreateKeyMaterial() throws -> KeyMaterial {
        try queue.sync {
            if let data = try keyStore.data() {
                return try material(fromPrivateKeyData: data)
            }
            let privateKey = PlatformCrypto.ed25519PrivateKey()
            try keyStore.set(privateKey.rawRepresentation)
            return try material(fromPrivateKeyData: privateKey.rawRepresentation)
        }
    }

    public func publishIssuerTrust(
        revoked: Bool = false,
        path: String = RemoteUnlockSetupProbe.capabilityTokenIssuerTrustPath
    ) throws {
        let material = try copyOrCreateKeyMaterial()
        let trust = CapabilityTokenIssuerTrustMaterial(
            keyId: material.keyId,
            publicKeyEd25519Base64: material.publicKey.rawRepresentation.base64EncodedString(),
            revoked: revoked
        )
        try trust.write(to: path)
    }

    public func revokePublishedTrust(path: String = RemoteUnlockSetupProbe.capabilityTokenIssuerTrustPath) throws {
        try publishIssuerTrust(revoked: true, path: path)
    }

    private func material(fromPrivateKeyData data: Data) throws -> KeyMaterial {
        guard data.count == 32 else {
            throw RemoteUnlockCapabilitySigningKeyStoreError.invalidStoredKey
        }
        let privateKey: PlatformEd25519PrivateKey
        do {
            privateKey = try PlatformCrypto.ed25519PrivateKey(rawRepresentation: data)
        } catch {
            throw RemoteUnlockCapabilitySigningKeyStoreError.invalidStoredKey
        }
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let keyId = PlatformCrypto.sha256(publicKeyData)
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return KeyMaterial(
            keyId: "cap-\(keyId)",
            publicKey: privateKey.publicKey,
            privateKey: privateKey
        )
    }

    private static func defaultKeyStore() -> any RemoteUnlockCapabilityPrivateKeyStoring {
        #if os(Linux)
        return LinuxRemoteUnlockCapabilityPrivateKeyStore()
        #else
        return UnavailableRemoteUnlockCapabilityPrivateKeyStore()
        #endif
    }
}

private struct UnavailableRemoteUnlockCapabilityPrivateKeyStore: RemoteUnlockCapabilityPrivateKeyStoring {
    func data() throws -> Data? {
        throw RemoteUnlockCapabilitySigningKeyStoreError.secretStorageUnavailable
    }

    func set(_: Data) throws {
        throw RemoteUnlockCapabilitySigningKeyStoreError.secretStorageUnavailable
    }
}

#if os(Linux)
public final class LinuxRemoteUnlockCapabilityPrivateKeyStore: RemoteUnlockCapabilityPrivateKeyStoring, @unchecked Sendable {
    private let store: LinuxPersistentSecretStore
    private let account: String

    public convenience init() {
        self.init(
            store: LinuxPersistentSecretStore(service: LinuxPersistentSecretStore.remoteUnlockCapabilityService),
            account: LinuxPersistentSecretStore.defaultRemoteUnlockCapabilityAccount
        )
    }

    init(
        fallbackDirectory: URL,
        secretService: any LinuxSecretServiceClient,
        logger: @escaping @Sendable (String) -> Void = { _ in },
        account: String = LinuxPersistentSecretStore.defaultRemoteUnlockCapabilityAccount
    ) {
        self.store = LinuxPersistentSecretStore(
            service: LinuxPersistentSecretStore.remoteUnlockCapabilityService,
            fallbackDirectory: fallbackDirectory,
            secretService: secretService,
            logger: logger
        )
        self.account = account
    }

    init(store: LinuxPersistentSecretStore, account: String) {
        self.store = store
        self.account = account
    }

    public func data() throws -> Data? {
        switch store.load(account: account) {
        case .found(let data):
            return data
        case .absent:
            return nil
        case .unreadable:
            throw RemoteUnlockCapabilitySigningKeyStoreError.invalidStoredKey
        }
    }

    public func set(_ data: Data) throws {
        guard store.save(data, account: account) == errSecSuccessCompat else {
            throw RemoteUnlockCapabilitySigningKeyStoreError.secretStorageUnavailable
        }
    }
}
#endif

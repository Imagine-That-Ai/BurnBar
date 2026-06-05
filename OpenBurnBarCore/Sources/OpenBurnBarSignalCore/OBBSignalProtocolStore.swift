import Foundation
import LibSignalClient
import OpenBurnBarCore
import Security

/// L41 client runtime (item 4): a durable libsignal protocol store that persists this
/// device's X3DH/PQXDH + Double Ratchet state for REAL Signal sessions — the
/// transport/session path, distinct from the at-rest HPKE sealing in
/// `SignalAtRestSealer` (the producers wired for chat/CLI/Pensieve use single-shot HPKE,
/// not these stores). One class conforms to all five libsignal stores, mirroring the
/// canonical `InMemorySignalProtocolStore` behavior.
///
/// Persistence: EC/Kyber key records + trusted-identity TOFU live in the Keychain
/// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, exactly like
/// `OpenBurnBarSignalIdentityKeyStore`); `SessionRecord`s — large, frequently rewritten,
/// and not raw secret keys — are written atomically as files under `sessionDir`. Account
/// keys are namespaced (`prekey:`, `signed-prekey:`, `kyber-prekey:`, `kyber-prekey-used:`,
/// `trusted-identity:`) so the five stores never collide on one service string.
///
/// Thread-safety: libsignal's Swift store callbacks are synchronous and the protocol
/// makes thread-safety the embedder's responsibility, so every public store method runs
/// under a single recursive lock — this makes the kyber replay-guard read-modify-write and
/// the per-recipient session/identity writes atomic against concurrent decrypts.
public final class OBBSignalProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore, SessionStore
{
    public let identityKeypair: IdentityKeyPair
    public let registrationId: UInt32
    public let keychainService: String
    public let sessionDir: URL

    private let lock = NSRecursiveLock()

    public init(
        identityKeypair: IdentityKeyPair,
        registrationId: UInt32,
        keychainService: String,
        sessionDir: URL
    ) throws {
        self.identityKeypair = identityKeypair
        self.registrationId = registrationId
        self.keychainService = keychainService
        self.sessionDir = sessionDir
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - IdentityKeyStore

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { identityKeypair }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 { registrationId }

    public func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        try withLock {
            let account = identityAccount(address)
            let old = try keychainRead(account)
            let new = Data(identity.serialize())
            try keychainWrite(new, account: account)
            // Mirrors InMemorySignalProtocolStore: unchanged/new => .newOrUnchanged, else replaced.
            return (old == nil || old == new) ? .newOrUnchanged : .replacedExisting
        }
    }

    public func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        try withLock {
            guard let existing = try keychainRead(identityAccount(address)) else { return true } // TOFU
            return existing == Data(identity.serialize())
        }
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        try withLock {
            guard let bytes = try keychainRead(identityAccount(address)) else { return nil }
            return try IdentityKey(bytes: bytes)
        }
    }

    // MARK: - PreKeyStore

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        try withLock {
            guard let bytes = try keychainRead("prekey:\(id)") else {
                throw SignalError.invalidKeyIdentifier("no prekey with this identifier")
            }
            return try PreKeyRecord(bytes: bytes)
        }
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try withLock { try keychainWrite(Data(record.serialize()), account: "prekey:\(id)") }
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws {
        try withLock { try keychainDelete("prekey:\(id)") }
    }

    // MARK: - SignedPreKeyStore

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        try withLock {
            guard let bytes = try keychainRead("signed-prekey:\(id)") else {
                throw SignalError.invalidKeyIdentifier("no signed prekey with this identifier")
            }
            return try SignedPreKeyRecord(bytes: bytes)
        }
    }

    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try withLock { try keychainWrite(Data(record.serialize()), account: "signed-prekey:\(id)") }
    }

    // MARK: - KyberPreKeyStore

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        try withLock {
            guard let bytes = try keychainRead("kyber-prekey:\(id)") else {
                throw SignalError.invalidKeyIdentifier("no kyber prekey with this identifier")
            }
            return try KyberPreKeyRecord(bytes: bytes)
        }
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try withLock { try keychainWrite(Data(record.serialize()), account: "kyber-prekey:\(id)") }
    }

    public func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId: UInt32,
        baseKey: PublicKey,
        context: StoreContext
    ) throws {
        try withLock {
            // Replay guard, mirroring InMemorySignalProtocolStore: a base key reused for the same
            // (kyber id, signed-prekey id) pair is a replay. The seen base keys persist as a
            // concatenation of fixed-size serializations under one namespaced account; the whole
            // read-modify-write runs under the lock so concurrent decrypts cannot lose an append.
            let account = "kyber-prekey-used:\(id):\(signedPreKeyId)"
            let base = Data(baseKey.serialize())
            let seen = (try keychainRead(account)) ?? Data()
            let chunk = base.count
            if chunk > 0 {
                var offset = 0
                while offset + chunk <= seen.count {
                    if seen.subdata(in: offset..<(offset + chunk)) == base {
                        throw SignalError.invalidMessage("reused base key")
                    }
                    offset += chunk
                }
            }
            try keychainWrite(seen + base, account: account)
        }
    }

    // MARK: - SessionStore

    public func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        try withLock {
            let url = sessionURL(address)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try SessionRecord(bytes: Data(contentsOf: url))
        }
    }

    public func loadExistingSessions(
        for addresses: [ProtocolAddress],
        context: StoreContext
    ) throws -> [SessionRecord] {
        try withLock {
            try addresses.map { address in
                let url = sessionURL(address)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw SignalError.sessionNotFound("\(address.name).\(address.deviceId)")
                }
                return try SessionRecord(bytes: Data(contentsOf: url))
            }
        }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try withLock { try Data(record.serialize()).write(to: sessionURL(address), options: .atomic) }
    }

    // MARK: - Private helpers (always called while `lock` is held)

    private func identityAccount(_ address: ProtocolAddress) -> String {
        "trusted-identity:\(address.name):\(address.deviceId)"
    }

    private func sessionURL(_ address: ProtocolAddress) -> URL {
        let safeName = address.name.replacingOccurrences(of: "/", with: "-")
        return sessionDir.appendingPathComponent("\(safeName)_\(address.deviceId).session")
    }

    private func keychainRead(_ account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CloudVaultCryptoError.keychainError(Int(status)) }
        guard let data = item as? Data else { throw CloudVaultCryptoError.keychainDataMissing }
        return data
    }

    /// Atomic upsert (no destructive delete-then-add window): add, and on a duplicate update
    /// in place, so a partial failure can never erase the existing value (e.g. the replay blob).
    private func keychainWrite(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw CloudVaultCryptoError.keychainError(Int(updateStatus)) }
            return
        }
        throw CloudVaultCryptoError.keychainError(Int(addStatus))
    }

    private func keychainDelete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudVaultCryptoError.keychainError(Int(status))
        }
    }
}

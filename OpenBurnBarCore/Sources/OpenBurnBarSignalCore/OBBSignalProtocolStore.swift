import Foundation
import CryptoKit
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
    /// Out-of-band trust anchor for remote peer identities (F6). When set, the
    /// closure is the SOLE authority for `isTrustedIdentity`: it receives the
    /// peer's `ProtocolAddress` and the identity key the (untrusted) directory is
    /// advertising, and returns `true` only when that key matches a key the
    /// caller pinned out-of-band (mirroring `SignalAtRestSealer`'s
    /// `trustedSenderPublicKeys`). It is keyed by a STABLE peer identity (uid +
    /// deviceId), so a key swap that arrives under a new `identityKeyId` — and
    /// therefore a fresh per-address Keychain slot — is still caught instead of
    /// being trust-on-first-use'd into a new slot. Covers BOTH the outbound
    /// (`processPreKeyBundle`) and inbound (`signalDecryptPreKey`) paths because
    /// both consult the store's `isTrustedIdentity`.
    ///
    /// When `nil` the store falls back to the legacy byte-equality TOFU contract
    /// (no anchor configured). Production wiring of this transport MUST provide an
    /// evaluator — the transport is otherwise trust-on-first-use against a
    /// server-supplied key. See `OBBSignalSessionCipherTransport`.
    public typealias IdentityTrustEvaluator = @Sendable (
        _ address: ProtocolAddress,
        _ advertisedIdentity: IdentityKey
    ) -> Bool

    public let identityKeypair: IdentityKeyPair
    public let registrationId: UInt32
    public let keychainService: String
    public let sessionDir: URL
    private static let sessionStoreKeyAccount = "signal-session-store-key:v1"
    private static let sealedSessionMagic = Data("OpenBurnBar.SignalSessionRecord.v1\n".utf8)

    private let identityTrustEvaluator: IdentityTrustEvaluator?
    private let sessionStoreKey: SymmetricKey
    private let allowsTestingTOFU: Bool

    private let lock = NSRecursiveLock()

    public convenience init(
        identityKeypair: IdentityKeyPair,
        registrationId: UInt32,
        keychainService: String,
        sessionDir: URL,
        identityTrustEvaluator: @escaping IdentityTrustEvaluator
    ) throws {
        try self.init(
            identityKeypair: identityKeypair,
            registrationId: registrationId,
            keychainService: keychainService,
            sessionDir: sessionDir,
            identityTrustEvaluator: identityTrustEvaluator,
            allowsTestingTOFU: false
        )
    }

    public static func testingTOFU(
        identityKeypair: IdentityKeyPair,
        registrationId: UInt32,
        keychainService: String,
        sessionDir: URL
    ) throws -> OBBSignalProtocolStore {
        try OBBSignalProtocolStore(
            identityKeypair: identityKeypair,
            registrationId: registrationId,
            keychainService: keychainService,
            sessionDir: sessionDir,
            identityTrustEvaluator: nil,
            allowsTestingTOFU: true
        )
    }

    private init(
        identityKeypair: IdentityKeyPair,
        registrationId: UInt32,
        keychainService: String,
        sessionDir: URL,
        identityTrustEvaluator: IdentityTrustEvaluator?,
        allowsTestingTOFU: Bool
    ) throws {
        guard identityTrustEvaluator != nil || allowsTestingTOFU else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        self.identityKeypair = identityKeypair
        self.registrationId = registrationId
        self.keychainService = keychainService
        self.sessionDir = sessionDir
        self.identityTrustEvaluator = identityTrustEvaluator
        self.sessionStoreKey = try Self.loadOrCreateSessionStoreKey(keychainService: keychainService)
        self.allowsTestingTOFU = allowsTestingTOFU
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionDir.path)
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
        // F6: when an out-of-band trust anchor is configured it is the SOLE
        // authority — fail-closed against any server-supplied key that is not
        // pinned, which also catches a key swap arriving under a new
        // identityKeyId (a fresh per-address slot would otherwise TOFU-accept it).
        // Without an anchor, fall back to the legacy byte-equality TOFU contract.
        if let identityTrustEvaluator {
            return identityTrustEvaluator(address, identity)
        }
        guard allowsTestingTOFU else { return false }
        return try withLock {
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
            return try SessionRecord(bytes: openSessionRecordData(Data(contentsOf: url)))
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
                return try SessionRecord(bytes: openSessionRecordData(Data(contentsOf: url)))
            }
        }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try withLock {
            let sealed = try sealSessionRecordData(Data(record.serialize()))
            let url = sessionURL(address)
            try sealed.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: - Private helpers (always called while `lock` is held)

    private func identityAccount(_ address: ProtocolAddress) -> String {
        "trusted-identity:\(address.name):\(address.deviceId)"
    }

    private func sessionURL(_ address: ProtocolAddress) -> URL {
        let safeName = address.name.replacingOccurrences(of: "/", with: "-")
        return sessionDir.appendingPathComponent("\(safeName)_\(address.deviceId).session")
    }

    private func sealSessionRecordData(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: sessionStoreKey, authenticating: Self.sealedSessionMagic)
        guard let combined = sealed.combined else { throw CloudVaultCryptoError.sealedBoxUnavailable }
        return Self.sealedSessionMagic + combined
    }

    private func openSessionRecordData(_ data: Data) throws -> Data {
        guard data.starts(with: Self.sealedSessionMagic) else {
            throw CloudVaultCryptoError.invalidEnvelope
        }
        let combined = data.dropFirst(Self.sealedSessionMagic.count)
        let sealed = try AES.GCM.SealedBox(combined: Data(combined))
        return try AES.GCM.open(sealed, using: sessionStoreKey, authenticating: Self.sealedSessionMagic)
    }

    private static func loadOrCreateSessionStoreKey(keychainService: String) throws -> SymmetricKey {
        if let existing = try staticKeychainRead(keychainService: keychainService, account: sessionStoreKeyAccount) {
            guard existing.count == 32 else { throw CloudVaultCryptoError.invalidKeyLength }
            return SymmetricKey(data: existing)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw CloudVaultCryptoError.keychainError(Int(status)) }
        let data = Data(bytes)
        try staticKeychainWrite(data, keychainService: keychainService, account: sessionStoreKeyAccount)
        return SymmetricKey(data: data)
    }

    private static func staticKeychainRead(keychainService: String, account: String) throws -> Data? {
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

    private static func staticKeychainWrite(_ data: Data, keychainService: String, account: String) throws {
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

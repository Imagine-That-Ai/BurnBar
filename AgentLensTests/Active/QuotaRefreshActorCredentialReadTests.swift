import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Proves the credential-read fault path that `QuotaRefreshActor` now relies on
/// instead of a bare `try?`.
///
/// Two daemon credential reads in `QuotaRefreshActor.swift` previously used
/// `try? providerRuntimeKeyStore.string(for:allowUserInteraction:)`:
///   - `resolveDaemonPlanAPIKey` (the daemon *plan* key fallback), and
///   - `resolveDaemonAccountCredentials` (each daemon *account* credential slot).
///
/// A bare `try?` collapsed a genuinely *broken* Keychain — a locked store, an ACL
/// denial, an unhandled `OSStatus`, or corrupt data — into the same `nil` as a
/// genuinely-absent credential. In a security product that means a broken or
/// locked keychain silently looks identical to "no daemon credential configured,"
/// degrading quota/auth flows with no diagnostic and no trace.
///
/// The fix routes both reads through
/// `KeychainStore.credentialIfPresent(for:allowUserInteraction:event:)`, which
/// keeps the exact nil-on-absent contract callers depend on (`if let` /
/// `guard let` optionality and absent-key behavior are unchanged) while making a
/// real fault observable: it logs the named event to `AppLogger` and returns
/// `nil` instead of letting the error vanish.
///
/// These tests drive that accessor through the `KeychainStore` `init(backend:)`
/// seam — the same seam the daemon resolvers consume via the injected
/// `providerRuntimeKeyStore` — so the precise mechanism the actor depends on is
/// verified directly with the exact event names the migrated call sites pass:
///   1. a backend whose `data(for:)` throws `KeychainStoreError.unhandled(...)`
///      resolves to `nil` *without throwing* (the fault is absorbed and logged,
///      never propagated, never crashing the refresh); and
///   2. a backend with no stored item still resolves to `nil` (the absent path is
///      unchanged), so the only difference between "broken" and "absent" is the
///      logged event — never the caller-visible outcome.
final class QuotaRefreshActorCredentialReadTests: XCTestCase {
    // Mirrors the account shape the daemon resolvers build:
    // "provider.<providerID>.slot.<slotID>.apiKey".
    private let account = "provider.minimax.slot.work.apiKey"

    func test_daemonPlanKeyRead_faultingKeychain_returnsNilWithoutThrowing() {
        let backend = FaultingReadKeychainBackend(error: .unhandled(errSecNotAvailable))
        let runtimeKeyStore = KeychainStore(backend: backend)

        // Models `resolveDaemonPlanAPIKey`'s migrated read. A real keychain fault
        // must be absorbed to nil (observable via the logged event), never
        // rethrown — so the plan-key fallback degrades gracefully instead of
        // crashing, and a broken store is never silently treated as "configured".
        let value = runtimeKeyStore.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "daemon_plan_api_key_read_failed"
        )

        XCTAssertNil(value, "A faulting Keychain read must resolve to nil, not a credential.")
        XCTAssertTrue(backend.didAttemptRead, "The fault path must actually exercise the backend read.")
    }

    func test_daemonAccountCredentialRead_faultingKeychain_returnsNilWithoutThrowing() {
        let backend = FaultingReadKeychainBackend(error: .unhandled(errSecNotAvailable))
        let runtimeKeyStore = KeychainStore(backend: backend)

        // Models `resolveDaemonAccountCredentials`'s migrated per-slot read. The
        // `guard let key = ...` site keeps its optionality: a fault yields nil and
        // the slot is skipped (no forged credential surfaces to a quota request),
        // but unlike `try?` the fault is now logged rather than vanishing.
        let value = runtimeKeyStore.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "daemon_account_api_key_read_failed"
        )

        XCTAssertNil(value, "A faulting Keychain read must resolve to nil, not a credential.")
        XCTAssertTrue(backend.didAttemptRead, "The fault path must actually exercise the backend read.")
    }

    func test_daemonCredentialRead_absentItem_returnsNil() {
        let backend = EmptyReadKeychainBackend()
        let runtimeKeyStore = KeychainStore(backend: backend)

        // The unchanged absent path: a genuinely missing credential still yields
        // nil, identical to the pre-fix `try?` behavior — the slot is skipped and
        // nothing is logged.
        let value = runtimeKeyStore.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "daemon_account_api_key_read_failed"
        )

        XCTAssertNil(value, "A genuinely absent credential must still resolve to nil.")
        XCTAssertTrue(backend.didAttemptRead, "The absent path must actually exercise the backend read.")
    }

    func test_daemonCredentialRead_presentItem_returnsStoredValue() throws {
        let backend = InMemoryKeychainBackend()
        let runtimeKeyStore = KeychainStore(backend: backend)
        try runtimeKeyStore.set("sk-cp-work", for: account)

        // Sanity: a healthy store returns the stored secret, so the fault/absent
        // nils are not masking a regression that always returns nil.
        let value = runtimeKeyStore.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "daemon_account_api_key_read_failed"
        )

        XCTAssertEqual(value, "sk-cp-work", "A present credential must be read back unchanged.")
    }
}

// MARK: - Test backends

/// A `KeychainStoreBackend` whose `data(for:)` throws, simulating a broken or
/// locked Keychain (e.g. `errSecNotAvailable`). Writes/deletes succeed so the
/// store under test reaches the read before failing.
private final class FaultingReadKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    private let error: KeychainStoreError
    private(set) var didAttemptRead = false

    init(error: KeychainStoreError) {
        self.error = error
    }

    func set(_: Data, service _: String, account _: String) throws {}

    func data(for _: String, account _: String, allowUserInteraction _: Bool) throws -> Data? {
        didAttemptRead = true
        throw error
    }

    func delete(service _: String, account _: String) throws {}
}

/// A `KeychainStoreBackend` that has no stored item, modelling a genuinely
/// absent credential.
private final class EmptyReadKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    private(set) var didAttemptRead = false

    func set(_: Data, service _: String, account _: String) throws {}

    func data(for _: String, account _: String, allowUserInteraction _: Bool) throws -> Data? {
        didAttemptRead = true
        return nil
    }

    func delete(service _: String, account _: String) throws {}
}

/// A minimal healthy in-memory `KeychainStoreBackend` for the present-credential
/// sanity check.
private final class InMemoryKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

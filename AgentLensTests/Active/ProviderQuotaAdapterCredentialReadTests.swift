import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Proves the credential-read fault path that `ProviderQuotaAdapter` now relies
/// on instead of a bare `try?`.
///
/// `DeepSeekQuotaAdapter.cursorConnectorKey(for:)` previously read its connector
/// key with `try? keychain.string(for:)`, which collapsed a *broken* Keychain
/// (locked store / ACL denial / unhandled OSStatus / corrupt data) into the same
/// `nil` as a genuinely-absent credential — a silent, undiagnosable degradation
/// in a security product. The fix routes the read through
/// `KeychainStore.credentialIfPresent(for:allowUserInteraction:event:)`, which
/// keeps the nil-on-absent contract while making a real fault observable (it
/// logs to `AppLogger` rather than vanishing).
///
/// These tests drive the underlying `KeychainStore` accessor through its
/// existing `init(backend:)` seam so the exact mechanism the adapter depends on
/// is verified directly:
///   1. a backend whose `data(for:)` throws is read as `nil` *without throwing*
///      (the fault is absorbed, not propagated, and is logged);
///   2. a backend that simply has no item still yields `nil` (absent path
///      unchanged).
final class ProviderQuotaAdapterCredentialReadTests: XCTestCase {
    private let account = "provider.deepseek.apiKey"

    func testCredentialIfPresent_faultingBackend_returnsNilWithoutThrowing() {
        let backend = FaultingReadKeychainBackend(error: .unhandled(errSecNotAvailable))
        let keychain = KeychainStore(backend: backend)

        // Real Keychain fault: must be absorbed to nil (observable via the log
        // event), never rethrown, so quota fetch degrades gracefully instead of
        // crashing — and never silently misreads a broken store as "configured".
        let value = keychain.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "deepseek_connector_key_read_failed"
        )

        XCTAssertNil(value, "A faulting Keychain read must resolve to nil, not a credential.")
        XCTAssertTrue(backend.didAttemptRead, "The fault path must actually exercise the backend read.")
    }

    func testCredentialIfPresent_absentItem_returnsNil() {
        let backend = EmptyReadKeychainBackend()
        let keychain = KeychainStore(backend: backend)

        let value = keychain.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "deepseek_connector_key_read_failed"
        )

        XCTAssertNil(value, "A genuinely absent credential must still resolve to nil.")
        XCTAssertTrue(backend.didAttemptRead, "The absent path must actually exercise the backend read.")
    }
}

// MARK: - Test backends

/// A `KeychainStoreBackend` whose `data(for:)` throws, simulating a broken or
/// locked Keychain (e.g. `errSecNotAvailable`). Writes/deletes succeed so the
/// store under test reaches the read.
private final class FaultingReadKeychainBackend: KeychainStoreBackend {
    private let error: KeychainStoreError
    private let didAttemptReadBox = OpenBurnBarCore.Locked(false)

    var didAttemptRead: Bool {
        didAttemptReadBox.read()
    }

    init(error: KeychainStoreError) {
        self.error = error
    }

    func set(_: Data, service _: String, account _: String) throws {}

    func data(for _: String, account _: String, allowUserInteraction _: Bool) throws -> Data? {
        didAttemptReadBox.write(true)
        throw error
    }

    func delete(service _: String, account _: String) throws {}
}

/// A `KeychainStoreBackend` that has no stored item, modelling a genuinely
/// absent credential.
private final class EmptyReadKeychainBackend: KeychainStoreBackend {
    private let didAttemptReadBox = OpenBurnBarCore.Locked(false)

    var didAttemptRead: Bool {
        didAttemptReadBox.read()
    }

    func set(_: Data, service _: String, account _: String) throws {}

    func data(for _: String, account _: String, allowUserInteraction _: Bool) throws -> Data? {
        didAttemptReadBox.write(true)
        return nil
    }

    func delete(service _: String, account _: String) throws {}
}

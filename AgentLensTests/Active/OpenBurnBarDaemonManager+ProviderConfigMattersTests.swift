import Security
import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Proves the provider-slot secret deletions in
/// `OpenBurnBarDaemonManager+ProviderConfig` no longer swallow a real Keychain
/// fault behind `try?`.
///
/// Three call sites used to delete a slot's app-side plaintext API key with
/// `try? Self.providerRuntimeSecrets.delete(...)`, which collapsed a locked
/// keychain / ACL denial / unhandled `OSStatus` into the same silent no-op as a
/// genuinely-absent item. That left a stale, still-readable plaintext credential
/// lingering in the keychain with zero diagnostic — a credential-continuity leak
/// in a security product.
///
/// The deletions now route through two intent-revealing helpers:
///
///  * `purgeProviderSlotSecretFailClosed` — used before *rotating* a new key in.
///    A real fault means we cannot prove the previous plaintext is gone, so it
///    rethrows and the rotation is rejected (never written on top of an
///    un-purged secret).
///  * `purgeProviderSlotSecretObservable` — used for *post-commit* cleanup (slot
///    already removed daemon-side, or ownership already migrated). A real fault
///    is logged and reported via the return value, but tolerated so a completed
///    operation isn't falsely reported as failed.
///
/// Both are exercised here against an injected `KeychainStore` backend, so the
/// fault branch is verified without touching the system keychain.
final class OpenBurnBarDaemonManagerProviderConfigMattersTests: XCTestCase {

    private let service = OpenBurnBar.OpenBurnBarIdentity.cursorConnectorKeychainService
    private let account = "provider.zai.slot.test-slot.apiKey"

    private func makeStore(backend: KeychainStoreBackend) -> KeychainStore {
        KeychainStore(service: service, legacyServices: [], backend: backend)
    }

    // MARK: - Fail-closed purge (credential rotation)

    @MainActor
    func test_failClosedPurge_rethrowsOnKeychainFault_soRotationIsRejected() throws {
        // A genuine Keychain fault must propagate so the caller refuses to write a
        // new credential on top of an un-purged stale plaintext secret.
        let backend = ProviderSlotSecretTestKeychainBackend()
        backend.deleteError = KeychainStoreError.unhandled(errSecNotAvailable)
        let store = makeStore(backend: backend)

        XCTAssertThrowsError(
            try OpenBurnBarDaemonManager.purgeProviderSlotSecretFailClosed(
                account: account,
                from: store
            ),
            "a real keychain fault must fail closed, not silently succeed"
        ) { error in
            guard case KeychainStoreError.unhandled = error else {
                XCTFail("expected the underlying keychain fault to propagate, got \(error)"); return
            }
            }
        XCTAssertEqual(backend.deleteAttempts, 1, "the fault must come from a real delete attempt")
    }

    @MainActor
    func test_failClosedPurge_removesPresentSecret() throws {
        let backend = ProviderSlotSecretTestKeychainBackend()
        let store = makeStore(backend: backend)
        try store.set("zai-secret-key", for: account)
        XCTAssertNotNil(try store.string(for: account), "precondition: secret is present")

        XCTAssertNoThrow(
            try OpenBurnBarDaemonManager.purgeProviderSlotSecretFailClosed(
                account: account,
                from: store
            )
        )
        XCTAssertNil(try store.string(for: account), "the stale plaintext secret must be purged")
    }

    @MainActor
    func test_failClosedPurge_succeedsWhenSecretAbsent() {
        // A genuinely-absent item is success: the backend maps item-not-found to a
        // no-op, so an empty slot is fully purged without throwing.
        let backend = ProviderSlotSecretTestKeychainBackend()
        let store = makeStore(backend: backend)

        XCTAssertNoThrow(
            try OpenBurnBarDaemonManager.purgeProviderSlotSecretFailClosed(
                account: account,
                from: store
            )
        )
    }

    // MARK: - Observable purge (post-commit cleanup)

    @MainActor
    func test_observablePurge_returnsFalseOnKeychainFault_butDoesNotThrow() {
        // The authoritative state change already committed, so a fault here must
        // not abort the flow — it is logged and reported via the return value
        // while leaving the orphaned secret detectable rather than re-throwing.
        let backend = ProviderSlotSecretTestKeychainBackend()
        backend.deleteError = KeychainStoreError.unhandled(errSecNotAvailable)
        let store = makeStore(backend: backend)

        let purged = OpenBurnBarDaemonManager.purgeProviderSlotSecretObservable(
            account: account,
            from: store
        )

        XCTAssertFalse(purged, "a real keychain fault must report the orphan was not purged")
        XCTAssertEqual(backend.deleteAttempts, 1, "the fault must come from a real delete attempt")
    }

    @MainActor
    func test_observablePurge_removesOrphanedSecretAndReportsSuccess() throws {
        let backend = ProviderSlotSecretTestKeychainBackend()
        let store = makeStore(backend: backend)
        try store.set("orphaned-key", for: account)

        let purged = OpenBurnBarDaemonManager.purgeProviderSlotSecretObservable(
            account: account,
            from: store
        )

        XCTAssertTrue(purged)
        XCTAssertNil(try store.string(for: account), "the orphaned plaintext secret must be deleted")
    }

    @MainActor
    func test_observablePurge_succeedsWhenSecretAbsent() {
        let backend = ProviderSlotSecretTestKeychainBackend()
        let store = makeStore(backend: backend)

        XCTAssertTrue(
            OpenBurnBarDaemonManager.purgeProviderSlotSecretObservable(
                account: account,
                from: store
            ),
            "an absent item is a successful no-op purge"
        )
    }
}

// MARK: - Fault-injecting Keychain backend

/// In-memory `KeychainStoreBackend` that stores values like a real keychain but
/// can be told to throw on `delete`, exercising the real-fault branch of the
/// purge helpers without touching the system keychain. Item-not-found is modeled
/// as a benign no-op by simply returning, matching the production backend.
private final class ProviderSlotSecretTestKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    var storage: [String: [String: Data]] = [:]
    var deleteError: Error?
    private(set) var deleteAttempts = 0

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        deleteAttempts += 1
        if let deleteError {
            throw deleteError
        }
        storage[service]?[account] = nil
    }
}

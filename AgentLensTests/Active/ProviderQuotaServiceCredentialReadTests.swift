import Foundation
import Security
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Proves the credential read used by
/// `ProviderQuotaService.daemonPlanAPIKey(for:)` distinguishes a genuinely
/// absent runtime key from a *broken* Keychain.
///
/// The daemon-plan key lookup resolves each credential slot's API key through
/// `KeychainStore.credentialIfPresent(for:allowUserInteraction:event:)` with the
/// `daemon_plan_api_key_read_failed` event. Previously this site used
/// `try? providerRuntimeKeyStore.string(for:)`, which collapsed a locked
/// keychain / ACL denial / unhandled `OSStatus` into the same `nil` as "no key
/// configured" — silently degrading quota with no diagnostic. These tests pin
/// both halves of the new contract: a real fault is non-throwing-nil (and
/// logs), while a missing item still returns nil.
final class ProviderQuotaServiceCredentialReadTests: XCTestCase {
    private let service = "com.openburnbar.provider-quota-runtime-credential-read-tests"
    private let account = "provider.minimax.slot.work.apiKey"

    func test_credentialRead_returnsStoredValue() throws {
        let backend = ProviderQuotaRuntimeTestKeychainBackend()
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)
        try store.set("sk-cp-work", for: account)

        let value = store.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "daemon_plan_api_key_read_failed"
        )

        XCTAssertEqual(value, "sk-cp-work")
    }

    func test_credentialRead_returnsNilWhenAbsent() {
        // The genuinely-absent path must still resolve to nil so the daemon-plan
        // key lookup degrades gracefully (falls through to the next slot / no key).
        let backend = ProviderQuotaRuntimeTestKeychainBackend()
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)

        let value = store.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "daemon_plan_api_key_read_failed"
        )

        XCTAssertNil(value)
    }

    func test_credentialRead_returnsNilWithoutThrowingOnKeychainFault() {
        // The whole point of the fix: a real Keychain fault (locked keychain /
        // ACL denial / unhandled OSStatus) is observable via the log and the read
        // returns nil — never throwing, never crashing, and never silently
        // indistinguishable from "no key configured".
        let backend = ProviderQuotaRuntimeTestKeychainBackend()
        backend.readErrors[service] = KeychainStoreError.unhandled(errSecNotAvailable)
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)

        var value: String?
        XCTAssertNoThrow(
            value = store.credentialIfPresent(
                for: account,
                allowUserInteraction: false,
                event: "daemon_plan_api_key_read_failed"
            )
        )
        XCTAssertNil(value)
    }
}

// MARK: - Test Keychain Backend

/// Fault-injecting `KeychainStoreBackend` seam: `data(for:)` throws the configured
/// error so we can drive the real-fault path; absence is the empty `storage`.
private final class ProviderQuotaRuntimeTestKeychainBackend: KeychainStoreBackend {
    private struct State: Sendable {
        var storage: [String: [String: Data]] = [:]
        var readErrors: [String: KeychainStoreError] = [:]
        var deleteErrors: [String: KeychainStoreError] = [:]
    }

    private let state = OpenBurnBarCore.Locked(State())

    var readErrors: [String: KeychainStoreError] {
        get { state.read().readErrors }
        set { state.withLock { $0.readErrors = newValue } }
    }

    var deleteErrors: [String: KeychainStoreError] {
        get { state.read().deleteErrors }
        set { state.withLock { $0.deleteErrors = newValue } }
    }

    func set(_ value: Data, service: String, account: String) throws {
        state.withLock { $0.storage[service, default: [:]][account] = value }
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        try state.withLock { state in
            if let error = state.readErrors[service] {
                throw error
            }
            return state.storage[service]?[account]
        }
    }

    func delete(service: String, account: String) throws {
        try state.withLock { state in
            if let error = state.deleteErrors[service] {
                throw error
            }
            state.storage[service]?[account] = nil
        }
    }
}

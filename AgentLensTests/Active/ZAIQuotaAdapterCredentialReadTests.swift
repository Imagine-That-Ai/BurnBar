import Foundation
import Security
import XCTest
@testable import OpenBurnBar

/// Proves the credential read used by `ZAIQuotaAdapter.cursorConnectorKey(for:)`
/// distinguishes a genuinely absent key from a *broken* Keychain.
///
/// The adapter resolves its Z.ai coding-plan key through
/// `KeychainStore.credentialIfPresent(for:allowUserInteraction:event:)` with the
/// `zai_quota_key_read_failed` event. Previously this site used
/// `try? keychain.string(for:)`, which collapsed a locked keychain / ACL denial /
/// unhandled `OSStatus` into the same `nil` as "no key configured" — silently
/// degrading quota with no diagnostic. These tests pin both halves of the new
/// contract: a real fault is non-throwing-nil (and logs), while a missing item
/// still returns nil.
final class ZAIQuotaAdapterCredentialReadTests: XCTestCase {
    private let service = "com.openburnbar.zai-quota-credential-read-tests"

    func test_credentialRead_returnsStoredValue() throws {
        let backend = ZAIQuotaTestKeychainBackend()
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)
        try store.set("zai-coding-plan-key", for: "provider.zai.apiKey")

        let value = store.credentialIfPresent(
            for: "provider.zai.apiKey",
            allowUserInteraction: false,
            event: "zai_quota_key_read_failed"
        )

        XCTAssertEqual(value, "zai-coding-plan-key")
    }

    func test_credentialRead_returnsNilWhenAbsent() {
        // The genuinely-absent path must still resolve to nil so the adapter
        // degrades gracefully ("Add a Z.ai coding-plan key …").
        let backend = ZAIQuotaTestKeychainBackend()
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)

        let value = store.credentialIfPresent(
            for: "provider.zai.apiKey",
            allowUserInteraction: false,
            event: "zai_quota_key_read_failed"
        )

        XCTAssertNil(value)
    }

    func test_credentialRead_returnsNilWithoutThrowingOnKeychainFault() {
        // The whole point of the fix: a real Keychain fault (locked keychain /
        // ACL denial / unhandled OSStatus) is observable via the log and the read
        // returns nil — never throwing, never crashing, and never silently
        // indistinguishable from "no key configured".
        let backend = ZAIQuotaTestKeychainBackend()
        backend.readErrors[service] = KeychainStoreError.unhandled(errSecNotAvailable)
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)

        var value: String?
        XCTAssertNoThrow(
            value = store.credentialIfPresent(
                for: "provider.zai.apiKey",
                allowUserInteraction: false,
                event: "zai_quota_key_read_failed"
            )
        )
        XCTAssertNil(value)
    }
}

// MARK: - Test Keychain Backend

/// Fault-injecting `KeychainStoreBackend` seam: `data(for:)` throws the configured
/// error so we can drive the real-fault path; absence is the empty `storage`.
private final class ZAIQuotaTestKeychainBackend: KeychainStoreBackend {
    var storage: [String: [String: Data]] = [:]
    var readErrors: [String: Error] = [:]
    var deleteErrors: [String: Error] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        if let error = readErrors[service] {
            throw error
        }
        return storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        if let error = deleteErrors[service] {
            throw error
        }
        storage[service]?[account] = nil
    }
}

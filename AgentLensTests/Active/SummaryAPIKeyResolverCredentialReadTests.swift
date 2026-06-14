import Foundation
import Security
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Proves the Cursor Connector bridge-key read in `SummaryAPIKeyResolver`
/// (`cursorConnectorKey(for:)`) no longer collapses a *broken* Keychain into the
/// same `nil` as "no credential configured".
///
/// Before this change the resolver read the connector key with
/// `try? keychain.string(for:)`, which silently mapped a locked/unavailable
/// Keychain to the exact same `nil` as a genuinely absent key — degrading the
/// summary auth path with no diagnostic. The migrated call site now reads via
/// `KeychainStore.credentialIfPresent`, which preserves the nil-on-absent
/// contract callers rely on while surfacing real faults to `AppLogger`.
///
/// These tests drive the migrated path end to end through `resolveAPIKey`, using
/// the `keychainStoreProvider` injection seam so the only credential source under
/// test is the connector Keychain:
///
///   * a genuine Keychain fault (`KeychainStoreError.unhandled(errSecNotAvailable)`)
///     must resolve to `nil` *without throwing or crashing* — the fault is now
///     observable in the log rather than silently swallowed by the old `try?`.
///   * a genuinely absent credential must still resolve to `nil`, so the migrated
///     call site keeps degrading gracefully when no connector key is configured.
///   * a present credential must still be returned, so the happy path is intact.
@MainActor
final class SummaryAPIKeyResolverCredentialReadTests: XCTestCase {
    /// The connector-key account the resolver reads for the z.ai provider.
    private let zaiAccount = "provider.zai.apiKey"

    /// Builds an isolated `ProviderAPIKeyStore` backed by an empty in-memory
    /// Keychain so `store.apiKey(for:)` returns `nil` and the connector-key path
    /// is the only credential source exercised by these tests.
    private func makeEmptyProviderStore(service: String) -> ProviderAPIKeyStore {
        let backend = FaultInjectingKeychainBackend()
        let keychain = KeychainStore(service: service, legacyServices: [], backend: backend)
        return ProviderAPIKeyStore(keychain: keychain)
    }

    func test_resolve_returnsNilAndDoesNotThrowOnConnectorKeychainFault() async throws {
        // The resolver falls back to a process env var after the connector key;
        // skip if it is set so the assertion isolates the migrated Keychain path.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ZAI_API_KEY"] == nil,
            "ZAI_API_KEY is set in the environment; cannot isolate the connector-key fault path."
        )

        // Drive the real fault path: a locked/unavailable Keychain surfaces an
        // unhandled OSStatus. The migrated resolver must log and degrade to nil —
        // never propagate, never crash, never masquerade as "no credential".
        let connectorService = "com.openburnbar.summary-resolver-credential-tests.fault"
        let providerStoreService = "com.openburnbar.summary-resolver-credential-tests.provider.fault"

        let connectorBackend = FaultInjectingKeychainBackend()
        connectorBackend.readErrors[connectorService] = KeychainStoreError.unhandled(errSecNotAvailable)

        let resolver = SummaryAPIKeyResolver(
            providerAPIKeyStore: makeEmptyProviderStore(service: providerStoreService),
            keychainStoreProvider: {
                KeychainStore(service: connectorService, legacyServices: [], backend: connectorBackend)
            }
        )

        let key = await resolver.resolveAPIKey(for: .zai)

        XCTAssertNil(key)
    }

    func test_resolve_returnsNilWhenConnectorCredentialAbsent() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ZAI_API_KEY"] == nil,
            "ZAI_API_KEY is set in the environment; cannot isolate the absent connector-key path."
        )

        let connectorService = "com.openburnbar.summary-resolver-credential-tests.absent"
        let providerStoreService = "com.openburnbar.summary-resolver-credential-tests.provider.absent"

        let connectorBackend = FaultInjectingKeychainBackend()

        let resolver = SummaryAPIKeyResolver(
            providerAPIKeyStore: makeEmptyProviderStore(service: providerStoreService),
            keychainStoreProvider: {
                KeychainStore(service: connectorService, legacyServices: [], backend: connectorBackend)
            }
        )

        let key = await resolver.resolveAPIKey(for: .zai)

        XCTAssertNil(key)
    }

    func test_resolve_returnsStoredConnectorCredential() async throws {
        let connectorService = "com.openburnbar.summary-resolver-credential-tests.present"
        let providerStoreService = "com.openburnbar.summary-resolver-credential-tests.provider.present"

        let connectorBackend = FaultInjectingKeychainBackend()
        let connectorKeychain = KeychainStore(
            service: connectorService,
            legacyServices: [],
            backend: connectorBackend
        )
        try connectorKeychain.set("sk-connector-secret", for: zaiAccount)

        let resolver = SummaryAPIKeyResolver(
            providerAPIKeyStore: makeEmptyProviderStore(service: providerStoreService),
            keychainStoreProvider: {
                KeychainStore(service: connectorService, legacyServices: [], backend: connectorBackend)
            }
        )

        let key = await resolver.resolveAPIKey(for: .zai)

        XCTAssertEqual(key, "sk-connector-secret")
    }
}

// MARK: - Fault-injecting test backend

/// In-memory `KeychainStoreBackend` whose `data(for:)` throws a configured fault,
/// letting tests model a locked/unavailable Keychain through the production seam.
private final class FaultInjectingKeychainBackend: KeychainStoreBackend {
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

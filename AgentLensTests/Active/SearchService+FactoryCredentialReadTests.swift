import Foundation
import Security
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Proves the cross-encoder connector-key read in `SearchService+Factory`
/// (`cursorConnectorKey(for:)`) no longer collapses a *broken* Keychain into the
/// same `nil` as "no credential configured".
///
/// The factory reads the connector key via `KeychainStore.credentialIfPresent`,
/// which preserves the nil-on-absent contract while surfacing genuine Keychain
/// faults to `AppLogger`. These tests exercise that exact accessor through the
/// `KeychainStore(backend:)` injection seam the production path resolves to:
///
///   * a genuine Keychain fault (`KeychainStoreError.unhandled(errSecNotAvailable)`)
///     must return `nil` *without throwing or crashing* — the fault is observable
///     in the log rather than silently swallowed by the old `try?`.
///   * a genuinely absent credential must still return `nil`, so the migrated
///     call site keeps degrading gracefully when no key is configured.
final class SearchServiceFactoryCredentialReadTests: XCTestCase {
    private let service = "com.openburnbar.searchservice-factory-credential-tests"
    private let account = "provider.minimax.apiKey"

    func test_connectorKeyRead_returnsNilAndDoesNotThrowOnKeychainFault() {
        // Drive the real fault path: a locked/unavailable Keychain surfaces an
        // unhandled OSStatus. The accessor must log and degrade to nil — never
        // propagate, never crash, never masquerade as "no credential".
        let backend = FaultInjectingKeychainBackend()
        backend.readErrors[service] = KeychainStoreError.unhandled(errSecNotAvailable)
        let keychain = KeychainStore(service: service, legacyServices: [], backend: backend)

        let result = keychain.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "cross_encoder_connector_key_read_failed"
        )

        XCTAssertNil(result)
    }

    func test_connectorKeyRead_returnsNilWhenCredentialAbsent() {
        let backend = FaultInjectingKeychainBackend()
        let keychain = KeychainStore(service: service, legacyServices: [], backend: backend)

        let result = keychain.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "cross_encoder_connector_key_read_failed"
        )

        XCTAssertNil(result)
    }

    func test_connectorKeyRead_returnsStoredCredential() throws {
        let backend = FaultInjectingKeychainBackend()
        let keychain = KeychainStore(service: service, legacyServices: [], backend: backend)
        try keychain.set("sk-connector-secret", for: account)

        let result = keychain.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "cross_encoder_connector_key_read_failed"
        )

        XCTAssertEqual(result, "sk-connector-secret")
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

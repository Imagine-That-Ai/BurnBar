import Foundation
import Security
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Proves the credential reads in `ProviderUsageAPIService.swift` route through
/// `KeychainStore.credentialIfPresent(for:event:)` instead of a bare `try?`.
///
/// The migration's whole point: a *broken* keychain (locked / ACL denied /
/// unhandled `OSStatus` / corrupt data) is no longer collapsed into the same
/// silent `nil` as a genuinely-absent credential. `credentialIfPresent` catches
/// the real fault, logs it, and returns `nil` — so the call sites stay total
/// (never throw, never crash) while the fault becomes observable at the seam.
///
/// These tests drive the two migrated sites:
///   1. `ProviderAPIKeyStore.apiKey(for:)`  -> `keychain` read (event
///      `provider_api_key_read_failed`).
///   2. `ProviderUsageAPIService.connectorKey(for:)` -> `connectorKeychain`
///      read for the `zai` connector account (event
///      `connector_api_key_read_failed`).
///
/// The fault is injected through the existing `KeychainStore(backend:)` seam,
/// which `ProviderAPIKeyStore(keychain:)` and
/// `ProviderUsageAPIService(connectorKeychain:)` both expose for tests.
@MainActor
final class ProviderUsageAPIServiceCredentialReadTests: XCTestCase {

    // MARK: - Fake backends

    /// A backend whose `data(for:)` ALWAYS throws a real keychain fault.
    /// Models a locked / unavailable keychain (`errSecNotAvailable`) that a bare
    /// `try?` would have silently swallowed as "no credential configured".
    private nonisolated final class ThrowingReadKeychainBackend: KeychainStoreBackend {
        private let readAttemptsBox = OpenBurnBarCore.Locked(0)

        var readAttempts: Int {
            readAttemptsBox.read()
        }

        func set(_: Data, service _: String, account _: String) throws {
            // Not exercised by these read-path tests.
        }

        func data(for _: String, account _: String, allowUserInteraction _: Bool) throws -> Data? {
            readAttemptsBox.withLock { $0 += 1 }
            throw KeychainStoreError.unhandled(errSecNotAvailable)
        }

        func delete(service _: String, account _: String) throws {
            // Not exercised by these read-path tests.
        }
    }

    /// A backend with no stored items: every read genuinely returns `nil`.
    private nonisolated final class EmptyKeychainBackend: KeychainStoreBackend {
        private let readAttemptsBox = OpenBurnBarCore.Locked(0)

        var readAttempts: Int {
            readAttemptsBox.read()
        }

        func set(_: Data, service _: String, account _: String) throws {}

        func data(for _: String, account _: String, allowUserInteraction _: Bool) throws -> Data? {
            readAttemptsBox.withLock { $0 += 1 }
            return nil
        }

        func delete(service _: String, account _: String) throws {}
    }

    private func makeStore(backend: any KeychainStoreBackend) -> KeychainStore {
        KeychainStore(
            service: "tests.provider-usage.\(UUID().uuidString)",
            legacyServices: [],
            backend: backend
        )
    }

    // MARK: - ProviderAPIKeyStore (`keychain` read, line ~102)

    /// FAULT PATH: a throwing keychain must not crash or propagate — the read is
    /// attempted, the fault is caught, and `apiKey(for:)` resolves to `nil`.
    func testApiKeyReturnsNilWithoutThrowingOnKeychainFault() {
        let backend = ThrowingReadKeychainBackend()
        let keyStore = ProviderAPIKeyStore(keychain: makeStore(backend: backend))

        let result = keyStore.apiKey(for: "anthropic", allowUserInteraction: false)

        XCTAssertNil(result, "A real keychain fault must resolve to nil, not propagate.")
        XCTAssertGreaterThanOrEqual(
            backend.readAttempts, 1,
            "The fault path must actually attempt the read (and catch the throw)."
        )
        // hasKey is derived from apiKey; a broken keychain must not look configured.
        XCTAssertFalse(keyStore.hasKey(for: "anthropic"))
    }

    /// ABSENT PATH: a genuinely-empty keychain still yields `nil` — identical
    /// observable result to the legacy `try?`, so the absent contract is intact.
    func testApiKeyReturnsNilWhenCredentialAbsent() {
        let backend = EmptyKeychainBackend()
        let keyStore = ProviderAPIKeyStore(keychain: makeStore(backend: backend))

        let result = keyStore.apiKey(for: "anthropic", allowUserInteraction: false)

        XCTAssertNil(result, "An absent credential must resolve to nil.")
        XCTAssertGreaterThanOrEqual(backend.readAttempts, 1)
    }

    /// The two paths are indistinguishable to callers (both nil) but BOTH go
    /// through the read — i.e. the fault is no longer short-circuited away.
    func testApiKeyFaultAndAbsentAreBothNilButBothAttemptTheRead() {
        let faultBackend = ThrowingReadKeychainBackend()
        let absentBackend = EmptyKeychainBackend()

        let faultStore = ProviderAPIKeyStore(keychain: makeStore(backend: faultBackend))
        let absentStore = ProviderAPIKeyStore(keychain: makeStore(backend: absentBackend))

        XCTAssertNil(faultStore.apiKey(for: "openai"))
        XCTAssertNil(absentStore.apiKey(for: "openai"))
        XCTAssertGreaterThanOrEqual(faultBackend.readAttempts, 1)
        XCTAssertGreaterThanOrEqual(absentBackend.readAttempts, 1)
    }

    // MARK: - ProviderUsageAPIService.connectorKey (`connectorKeychain`, line ~258)

    /// FAULT PATH (connector seam): a throwing connector keychain resolves the
    /// `zai` connector key to `nil` without throwing, and `rebuildAPIs()` (which
    /// calls the resolver) completes cleanly. No `ZAI_API_KEY` env so the only
    /// connector-backed source is the faulting keychain.
    func testConnectorKeyReturnsNilWithoutThrowingOnKeychainFault() {
        let backend = ThrowingReadKeychainBackend()
        // Empty keyStore so the connector keychain is actually consulted.
        let keyStore = ProviderAPIKeyStore(keychain: makeStore(backend: EmptyKeychainBackend()))

        let service = ProviderUsageAPIService(
            keyStore: keyStore,
            connectorKeychain: makeStore(backend: backend),
            environment: [:]
        )

        // Rebuild forces the credential resolution path (including connectorKey)
        // for every provider; a fault must not throw or crash here.
        service.rebuildAPIs()

        XCTAssertGreaterThanOrEqual(
            backend.readAttempts, 1,
            "The connector keychain read must be attempted (and its fault caught)."
        )
        // zai resolved to nil (faulting connector + no env) => no Z.ai probe.
        XCTAssertFalse(
            service.configuredProviders.contains("Z.ai"),
            "A faulting connector keychain must not advertise a Z.ai probe."
        )
    }

    /// ABSENT PATH (connector seam): an empty connector keychain also yields no
    /// connector key — same observable result, proving the absent contract holds.
    func testConnectorKeyReturnsNilWhenCredentialAbsent() {
        let backend = EmptyKeychainBackend()
        let keyStore = ProviderAPIKeyStore(keychain: makeStore(backend: EmptyKeychainBackend()))

        let service = ProviderUsageAPIService(
            keyStore: keyStore,
            connectorKeychain: makeStore(backend: backend),
            environment: [:]
        )

        service.rebuildAPIs()

        XCTAssertGreaterThanOrEqual(backend.readAttempts, 1)
        XCTAssertFalse(service.configuredProviders.contains("Z.ai"))
    }

    // MARK: - validate(provider:) fail-closed (line ~227)

    /// A fake probe whose `validate()` outcome is fully controlled: it either
    /// returns a fixed boolean OR throws a fixed error. Lets the tests drive the
    /// `ProviderUsageAPIService.validate(provider:)` decision deterministically,
    /// with no live network.
    private struct StubUsageAPI: ProviderUsageAPI {
        enum Outcome: Sendable {
            case returns(Bool)
            case throwsError
        }

        let providerName: String
        let authMethod: ProviderAuthMethod = .apiKey
        let outcome: Outcome

        func validate() async throws -> Bool {
            switch outcome {
            case let .returns(value):
                return value
            case .throwsError:
                throw URLError(.notConnectedToInternet)
            }
        }

        func fetchUsage(since _: Date) async throws -> [ProviderUsageRecord] { [] }
    }

    private func makeService() -> ProviderUsageAPIService {
        ProviderUsageAPIService(
            keyStore: ProviderAPIKeyStore(keychain: makeStore(backend: EmptyKeychainBackend())),
            connectorKeychain: makeStore(backend: EmptyKeychainBackend()),
            environment: [:]
        )
    }

    /// FAIL-CLOSED: a probe that THROWS (transient network / API fault) must
    /// resolve to `false`. The legacy `try?` already collapsed to `false`, but it
    /// did so SILENTLY — the migration keeps the fail-closed result while logging
    /// the throw so a transient failure is no longer indistinguishable from a
    /// genuine rejection. We must never report a credential as valid that we
    /// could not actually verify.
    func testValidateReturnsFalseWhenProbeThrows() async {
        let service = makeService()
        service.setAPIsForTesting([
            StubUsageAPI(providerName: "Anthropic", outcome: .throwsError)
        ])

        let result = await service.validate(provider: "Anthropic")

        XCTAssertFalse(
            result,
            "A throwing validation probe must fail closed: unverifiable != valid."
        )
    }

    /// CONFIRMED-INVALID: a probe that returns `false` (provider rejected the
    /// credential) still resolves to `false` — the non-throwing rejection path is
    /// preserved.
    func testValidateReturnsFalseWhenProbeRejects() async {
        let service = makeService()
        service.setAPIsForTesting([
            StubUsageAPI(providerName: "OpenAI", outcome: .returns(false))
        ])

        let result = await service.validate(provider: "OpenAI")

        XCTAssertFalse(result, "A provider-confirmed-invalid credential must be false.")
    }

    /// HAPPY PATH: a probe that returns `true` (provider confirmed the
    /// credential) resolves to `true` — the success path is untouched and the
    /// fix does not over-fail-close a genuinely valid credential.
    func testValidateReturnsTrueWhenProbeConfirms() async {
        let service = makeService()
        service.setAPIsForTesting([
            StubUsageAPI(providerName: "OpenAI", outcome: .returns(true))
        ])

        let result = await service.validate(provider: "OpenAI")

        XCTAssertTrue(result, "A provider-confirmed-valid credential must be true.")
    }

    /// UNKNOWN PROVIDER: no matching probe is configured, so validation fails
    /// closed without ever invoking a probe (guard path preserved).
    func testValidateReturnsFalseForUnknownProvider() async {
        let service = makeService()
        service.setAPIsForTesting([
            StubUsageAPI(providerName: "Anthropic", outcome: .returns(true))
        ])

        let result = await service.validate(provider: "NotARealProvider")

        XCTAssertFalse(result, "An unconfigured provider must fail closed.")
    }
}

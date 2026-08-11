import Foundation
import OpenBurnBarCore
import Security
import XCTest
@testable import OpenBurnBar

/// Pins the two `try?` error-swallows in
/// `PiAgentCloudRelayHostService.swift` that were judged to MATTER, both rooted
/// in `PiAgentRelayKeyStore`:
///
///  - L133 `publishRelayOffline` — `try? relayKeyStore.existingPublicKeyBase64()`
///    decided whether the offline connection doc advertised a `relayPublicKey`.
///    A broken Keychain / corrupt cached fallback was indistinguishable from
///    "no key yet". The fix routes the read through `AppLogger.network.silently`,
///    which relies on `existingPublicKeyBase64()` degrading to `nil` (not a
///    crash) on a missing/corrupt key. These tests pin that degrade-to-nil
///    contract for the present-but-corrupt and genuinely-absent inputs.
///
///  - L706 `privateKey()` — `try? PiAgentRelayPrivateKey(rawRepresentation:)`
///    silently regenerated AND overwrote the relay identity key whenever the
///    stored bytes failed to parse. That rotates the key the phone has PINNED in
///    the two-key safety code (breaking sender authentication) with no
///    diagnostic. The fix keeps the recover-by-regenerating behavior (the relay
///    must still come up) but makes the corruption observable and still
///    *persists* a fresh valid key so the store self-heals. These tests pin the
///    valid round-trip, the corrupt→regenerate-and-persist heal, and the
///    first-run absence path.
final class PiAgentCloudRelayHostServiceMattersTests: XCTestCase {
    private let service = "com.openburnbar.pi-agent-relay-matters-tests"
    private let account = "settings.chat.piagent.relay.p256.v1"

    private func makeStore(
        backend: MattersTestKeychainBackend,
        fallbackCacheKey: String
    ) -> PiAgentRelayKeyStore {
        let keychain = KeychainStore(service: service, legacyServices: [], backend: backend)
        return PiAgentRelayKeyStore(keychain: keychain, fallbackCacheKey: fallbackCacheKey)
    }

    // MARK: - privateKey()

    func test_privateKey_returnsStoredKey_whenValidBytesPresent() throws {
        let backend = MattersTestKeychainBackend()
        let store = makeStore(backend: backend, fallbackCacheKey: uniqueFallbackKey())

        // First call mints + persists a key; the second must return the SAME key
        // (no rotation), proving the happy round-trip the phone's pinning relies on.
        let first = try store.privateKey()
        let second = try store.privateKey()
        XCTAssertEqual(first, second, "A valid stored key must be reused, never silently rotated.")

        // And it is what is actually in the Keychain.
        let persisted = backend.storage[service]?[account]
        XCTAssertNotNil(persisted)
        let persistedString = String(data: try XCTUnwrap(persisted), encoding: .utf8)
        let persistedData = Data(base64Encoded: try XCTUnwrap(persistedString))
        let persistedKey = try PiAgentRelayPrivateKey(rawRepresentation: try XCTUnwrap(persistedData))
        XCTAssertEqual(persistedKey, first)
    }

    func test_privateKey_regeneratesAndPersists_whenStoredBytesCorrupt() throws {
        // The security-sensitive path: present, base64-valid bytes that are NOT a
        // valid P-256 key. Pre-fix this silently rotated the pinned identity via
        // `try?`. Post-fix it must still recover (return a usable key) AND heal
        // the store by overwriting the corrupt bytes with a valid key, so the
        // anomaly does not recur on every launch.
        let backend = MattersTestKeychainBackend()
        let corrupt = Data([0x01, 0x02, 0x03]).base64EncodedString() // base64-valid, not a P-256 key
        try backend.set(Data(corrupt.utf8), service: service, account: account)

        let store = makeStore(backend: backend, fallbackCacheKey: uniqueFallbackKey())

        let recovered = try store.privateKey()

        // The store self-healed: the Keychain now holds a *valid* P-256 key that
        // equals the recovered key (not the corrupt bytes).
        let persisted = backend.storage[service]?[account]
        let persistedString = String(data: try XCTUnwrap(persisted), encoding: .utf8)
        XCTAssertNotEqual(persistedString, corrupt, "Corrupt bytes must be replaced, not left in place.")
        let persistedData = Data(base64Encoded: try XCTUnwrap(persistedString))
        let persistedKey = try PiAgentRelayPrivateKey(rawRepresentation: try XCTUnwrap(persistedData))
        XCTAssertEqual(persistedKey, recovered)

        // And the recovered key is stable on the next read (no thrash loop).
        let next = try store.privateKey()
        XCTAssertEqual(next, recovered)
    }

    func test_privateKey_generatesFreshKey_onFirstRunAbsence() throws {
        // Genuine first-run: nothing stored. Must mint + persist a usable key.
        let backend = MattersTestKeychainBackend()
        let store = makeStore(backend: backend, fallbackCacheKey: uniqueFallbackKey())

        let key = try store.privateKey()
        let persisted = backend.storage[service]?[account]
        XCTAssertNotNil(persisted, "First run must persist the freshly minted key.")
        let persistedString = String(data: try XCTUnwrap(persisted), encoding: .utf8)
        let persistedData = Data(base64Encoded: try XCTUnwrap(persistedString))
        XCTAssertEqual(try PiAgentRelayPrivateKey(rawRepresentation: try XCTUnwrap(persistedData)), key)
    }

    func test_privateKey_fallsBackToEphemeral_whenKeychainWriteFails() throws {
        // A Keychain that reads empty but rejects writes must not crash: the
        // store falls back to the in-process ephemeral cache and still returns a
        // usable key, stable across calls within the process.
        let backend = MattersTestKeychainBackend()
        backend.writeError = KeychainStoreError.unhandled(errSecNotAvailable)
        let cacheKey = uniqueFallbackKey()
        let store = makeStore(backend: backend, fallbackCacheKey: cacheKey)

        let first = try store.privateKey()
        let second = try store.privateKey()
        XCTAssertEqual(first, second, "Ephemeral fallback must be stable for the process lifetime.")
    }

    // MARK: - existingPublicKeyBase64() (backs the L133 silently(...) site)

    func test_existingPublicKey_returnsStoredPublicKey_whenValid() throws {
        let backend = MattersTestKeychainBackend()
        let store = makeStore(backend: backend, fallbackCacheKey: uniqueFallbackKey())

        let key = try store.privateKey() // persists a valid key
        let pub = try store.existingPublicKeyBase64()
        XCTAssertEqual(pub, key.publicKeyBase64)
    }

    func test_existingPublicKey_degradesToNil_whenCorruptAndNoFallbackCache() throws {
        // The L133 site wraps this in `silently(..., fallback: nil)`. The
        // load-bearing requirement is that a present-but-corrupt stored key with
        // no cached fallback degrades to a clean `nil` (skip advertising the key)
        // rather than throwing into the offline-publish flow.
        let backend = MattersTestKeychainBackend()
        let corrupt = Data([0xAA]).base64EncodedString()
        try backend.set(Data(corrupt.utf8), service: service, account: account)
        let store = makeStore(backend: backend, fallbackCacheKey: uniqueFallbackKey())

        XCTAssertNil(try store.existingPublicKeyBase64())
    }

    func test_existingPublicKey_degradesToNil_whenAbsentAndNoFallbackCache() throws {
        let backend = MattersTestKeychainBackend()
        let store = makeStore(backend: backend, fallbackCacheKey: uniqueFallbackKey())

        XCTAssertNil(try store.existingPublicKeyBase64())
    }

    func test_existingPublicKey_silentlyWrapper_returnsNil_whenReadThrows() {
        // Mirrors the exact L133 expression: even if the underlying read THREW,
        // the `silently(...)` wrapper at the call site must yield nil (and log),
        // never propagating into the offline publish. We exercise the wrapper
        // shape directly to pin the call-site contract.
        let backend = MattersTestKeychainBackend()
        backend.readError = KeychainStoreError.unhandled(errSecNotAvailable)
        // existingPublicKeyBase64() catches the read fault internally and falls
        // back to the (here empty) ephemeral cache, so it resolves to nil rather
        // than throwing; the silently(...) wrapper passes that nil through.
        let store = makeStore(backend: backend, fallbackCacheKey: uniqueFallbackKey())

        let value: String? = AppLogger.network.silently(
            "pi_agent_relay_offline_public_key_unavailable",
            try store.existingPublicKeyBase64() as String?,
            fallback: nil
        )
        XCTAssertNil(value)
    }

    // MARK: - Helpers

    private func uniqueFallbackKey() -> String {
        "com.openburnbar.pi-agent-relay-matters-tests.\(UUID().uuidString)"
    }
}

// MARK: - Fault-injecting Keychain backend

/// In-memory `KeychainStoreBackend` seam: `data(for:)` / `set(_:)` throw the
/// configured error so corrupt-stored, read-fault, and write-fault paths are
/// exercisable; absence is the empty `storage`.
private final class MattersTestKeychainBackend: KeychainStoreBackend {
    private struct State: Sendable {
        var storage: [String: [String: Data]] = [:]
        var readError: KeychainStoreError?
        var writeError: KeychainStoreError?
    }

    private let state = Locked(State())

    var storage: [String: [String: Data]] {
        state.read().storage
    }

    var readError: KeychainStoreError? {
        get { state.read().readError }
        set { state.withLock { $0.readError = newValue } }
    }

    var writeError: KeychainStoreError? {
        get { state.read().writeError }
        set { state.withLock { $0.writeError = newValue } }
    }

    func set(_ value: Data, service: String, account: String) throws {
        try state.withLock { state in
            if let writeError = state.writeError { throw writeError }
            state.storage[service, default: [:]][account] = value
        }
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        try state.withLock { state in
            if let readError = state.readError { throw readError }
            return state.storage[service]?[account]
        }
    }

    func delete(service: String, account: String) throws {
        state.withLock { $0.storage[service]?[account] = nil }
    }
}

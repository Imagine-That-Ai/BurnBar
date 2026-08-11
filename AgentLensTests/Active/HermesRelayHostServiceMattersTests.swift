import XCTest
import Security
import OpenBurnBarCore
import OpenBurnBarIrohRelay
@testable import OpenBurnBar

/// Focused coverage for the `try?` error-swallow sites in
/// `HermesRelayHostService` that were judged to MATTER:
///
/// - The relay key-advertisement mapping (publishRelayConnection /
///   publishRelayOffline / publishLegacyRelayReplacement) must never write a
///   partial / keyless crypto surface.
/// - A real keychain read fault must be SURFACED (thrown), not silently mapped
///   to "no key configured", so the publish paths can fail closed instead of
///   advertising a keyless host.
/// - The stored relay private key must keep identity continuity: a valid stored
///   key is always returned unchanged; the host identity is only regenerated
///   when the stored bytes are genuinely unrecoverable.
final class HermesRelayHostServiceMattersTests: XCTestCase {
    private let relayAccount = "settings.chat.hermes.relay.p256.v1"

    @MainActor
    func test_pairingRefreshCadenceStaysInsideSignedRecordFreshnessWindow() {
        let backgroundInterval = HermesRelayHostService.backgroundRelayRefreshInterval
        let activeInterval = HermesRelayHostService.activeRelayRefreshInterval
        XCTAssertLessThan(
            backgroundInterval,
            IrohPairingFreshness.maximumAgeSeconds
        )
        XCTAssertLessThanOrEqual(
            activeInterval,
            backgroundInterval
        )
    }

    @MainActor
    func test_controlStreamCloseRefreshesPairingOnlyAfterLastSiblingCloses() async {
        var events: [String] = []

        await HermesRelayHostService.handleMercuryControlStreamClose(
            removedLastStreamForConnection: false,
            routeClose: { events.append("route") },
            refreshPairing: { events.append("refresh") }
        )
        XCTAssertEqual(events, ["route"])

        events.removeAll()
        await HermesRelayHostService.handleMercuryControlStreamClose(
            removedLastStreamForConnection: true,
            routeClose: { events.append("route") },
            refreshPairing: { events.append("refresh") }
        )
        XCTAssertEqual(events, ["route", "refresh"])
    }

    @MainActor
    func test_relayFallbackListenerStartsBeforePotentiallySlowConnectionPublish() async {
        var events: [String] = []

        await HermesRelayHostService.establishRelayAvailability(
            ensureRequestListener: { events.append("listener") },
            publishConnection: { events.append("publish") }
        )

        XCTAssertEqual(events, ["listener", "publish"])
    }

    // MARK: - applyRelayKeyFields (L299 / L433 mapping)

    func test_applyRelayKeyFields_writesCompleteKeyTriple_neverPartial() {
        var data: [String: Any] = ["id": "relay-host-mac"]

        HermesRelayHostService.applyRelayKeyFields(
            to: &data,
            publicKey: "BPUBLICKEY==",
            keyVersion: HermesRelayCrypto.gatewayRelayKeyVersionV3,
            encryption: HermesRelayCrypto.relayEncryptionV3
        )

        XCTAssertEqual(data["relayPublicKey"] as? String, "BPUBLICKEY==")
        XCTAssertEqual(data["relayKeyVersion"] as? Int, HermesRelayCrypto.gatewayRelayKeyVersionV3)
        XCTAssertEqual(data["relayEncryption"] as? String, HermesRelayCrypto.relayEncryptionV3)
    }

    /// A record either advertises NO key fields or a COMPLETE triple. A keyless
    /// publish path (the failure branch) must leave none of the three fields set
    /// so a peer can never pick a half-advertised, downgradable crypto surface.
    func test_keylessRecord_carriesNoneOfTheKeyFields() {
        let data: [String: Any] = [
            "id": "relay-host-mac",
            "status": "offline"
        ]

        XCTAssertNil(data["relayPublicKey"])
        XCTAssertNil(data["relayKeyVersion"])
        XCTAssertNil(data["relayEncryption"])
    }

    // MARK: - existingPublicKeyBase64 fail-closed seam (L299 / L433)

    /// When the public-key resolution genuinely throws (keychain read fault
    /// that then hits an UNPARSEABLE ephemeral fallback entry), the error must
    /// PROPAGATE out of `existingPublicKeyBase64` so the publish paths can fail
    /// closed: the offline path logs + continues keyless, and the
    /// legacy-replacement path now skips the publish entirely. The previous bare
    /// `try?` at both call sites swallowed this fault and silently advertised a
    /// keyless host.
    func test_existingPublicKey_surfacesResolutionFault_callerCanFailClosed() {
        let service = "tests.hermes.relay.readfault.\(UUID().uuidString)"
        // Seed the process-wide ephemeral cache with bytes that decode from
        // base64 but are NOT a valid P-256 raw key, so the fallback resolution
        // throws (rather than returning nil) once the keychain read faults.
        let corruptFallback = Data([0x01, 0x02, 0x03, 0x04])
        _ = RelayEphemeralKeyCache.shared.data(for: service) { corruptFallback }

        let keyStore = HermesRelayKeyStore(
            keychain: KeychainStore(
                service: service,
                legacyServices: [],
                backend: ReadFaultKeychainBackend()
            ),
            fallbackCacheKey: service
        )

        XCTAssertThrowsError(try keyStore.existingPublicKeyBase64())
    }

    /// Absent (never-provisioned) is the benign case and must still map to nil —
    /// the fix only un-swallows genuine faults, it does not turn "no key yet"
    /// into an error.
    func test_existingPublicKey_returnsNilWhenGenuinelyAbsent() throws {
        let service = "tests.hermes.relay.absent.\(UUID().uuidString)"
        let keyStore = HermesRelayKeyStore(
            keychain: KeychainStore(
                service: service,
                legacyServices: [],
                backend: InMemoryKeychainBackend()
            ),
            fallbackCacheKey: service
        )

        XCTAssertNil(try keyStore.existingPublicKeyBase64())
    }

    // MARK: - privateKey identity continuity (L1267)

    /// Identity continuity: a VALID stored key is returned unchanged on every
    /// call. The host must never silently rotate its identity while a usable key
    /// exists.
    func test_privateKey_returnsStoredKeyUnchanged_preservingIdentityContinuity() throws {
        let service = "tests.hermes.relay.continuity.\(UUID().uuidString)"
        let backend = InMemoryKeychainBackend()
        let stored = HermesRelayCrypto.generatePrivateKey()
        try backend.set(
            Data(stored.rawRepresentation.base64EncodedString().utf8),
            service: service,
            account: relayAccount
        )
        let keyStore = HermesRelayKeyStore(
            keychain: KeychainStore(service: service, legacyServices: [], backend: backend),
            fallbackCacheKey: service
        )

        let first = try keyStore.privateKey()
        let second = try keyStore.privateKey()

        XCTAssertEqual(first.rawRepresentation, stored.rawRepresentation)
        XCTAssertEqual(second.rawRepresentation, stored.rawRepresentation)
        // A valid stored key is never overwritten — the persisted bytes are
        // still the originals after reads.
        let persisted = try XCTUnwrap(backend.storedString(service: service, account: relayAccount))
        XCTAssertEqual(persisted, stored.rawRepresentation.base64EncodedString())
    }

    /// A genuinely-unparseable stored key (corrupt bytes that decode from base64
    /// but are not a valid P-256 raw key) is unrecoverable, so regeneration is
    /// the only option. The result must still be a usable key, and the corrupt
    /// bytes must be replaced with the freshly generated, parseable key (proving
    /// the fix logs-then-regenerates rather than looping on the bad bytes).
    func test_privateKey_regeneratesOnlyWhenStoredKeyIsUnrecoverable() throws {
        let service = "tests.hermes.relay.corrupt.\(UUID().uuidString)"
        let backend = InMemoryKeychainBackend()
        // 4 bytes is valid base64 but not a valid 32-byte P-256 raw key.
        let corrupt = Data([0x01, 0x02, 0x03, 0x04]).base64EncodedString()
        try backend.set(Data(corrupt.utf8), service: service, account: relayAccount)
        let keyStore = HermesRelayKeyStore(
            keychain: KeychainStore(service: service, legacyServices: [], backend: backend),
            fallbackCacheKey: service
        )

        let regenerated = try keyStore.privateKey()

        // The corrupt bytes were replaced with a valid, parseable key.
        let persisted = try XCTUnwrap(backend.storedString(service: service, account: relayAccount))
        XCTAssertNotEqual(persisted, corrupt)
        let reparsed = try HermesRelayPrivateKey(rawRepresentation: Data(base64Encoded: persisted) ?? Data())
        XCTAssertEqual(reparsed.rawRepresentation, regenerated.rawRepresentation)

        // And the regenerated key is now stable across subsequent reads.
        let again = try keyStore.privateKey()
        XCTAssertEqual(again.rawRepresentation, regenerated.rawRepresentation)
    }
}

// MARK: - Test Keychain Backends

/// A backend that always throws an unhandled keychain fault on read,
/// simulating a locked / inaccessible Keychain.
private final class ReadFaultKeychainBackend: KeychainStoreBackend {
    func set(_: Data, service _: String, account _: String) throws {}

    func data(for _: String, account _: String, allowUserInteraction _: Bool) throws -> Data? {
        throw KeychainStoreError.unhandled(errSecIO)
    }

    func delete(service _: String, account _: String) throws {}
}

/// A minimal in-memory backend with read-back helpers for assertions.
private final class InMemoryKeychainBackend: KeychainStoreBackend {
    private let storage = Locked<[String: [String: Data]]>([:])

    func set(_ value: Data, service: String, account: String) throws {
        storage.withLock { $0[service, default: [:]][account] = value }
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage.withLock { $0[service]?[account] }
    }

    func delete(service: String, account: String) throws {
        storage.withLock { $0[service]?[account] = nil }
    }

    func storedString(service: String, account: String) -> String? {
        guard let data = storage.withLock({ $0[service]?[account] }) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

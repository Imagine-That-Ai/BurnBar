import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class SettingsManagerSecretStorageTests: XCTestCase {
    func test_macInfoPlistDeclaresLocalNetworkUsageForMercuryTransport() throws {
        let plist = try XCTUnwrap(Bundle.main.infoDictionary)

        let description = try XCTUnwrap(plist["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertTrue(description.localizedCaseInsensitiveContains("trusted iPhone"))
        XCTAssertTrue(description.localizedCaseInsensitiveContains("Mercury media sessions"))
        XCTAssertTrue(description.localizedCaseInsensitiveContains("screen sharing"))

        let services = Set(try XCTUnwrap(plist["NSBonjourServices"] as? [String]))
        XCTAssertTrue(services.contains("_googlecast._tcp"))
        XCTAssertTrue(services.contains("_http._tcp"))
    }

    func test_initMigratesLegacyDefaultsTokensIntoKeychain() throws {
        let suiteName = "com.openburnbar.tests.settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("legacy-openclaw-token", forKey: "openClawBearerToken")
        defaults.set("legacy-hermes-token", forKey: "hermesBearerToken")
        defaults.set("legacy-telegram-token", forKey: "controllerTelegramBotToken")
        defaults.set("legacy-gateway-token", forKey: "gatewayAuthToken")

        let controllerSecrets = KeychainStore(
            service: "tests.controller.\(UUID().uuidString)",
            legacyServices: [],
            backend: SettingsManagerTestKeychainBackend()
        )
        let gatewaySecrets = KeychainStore(
            service: "tests.gateway.\(UUID().uuidString)",
            legacyServices: [],
            backend: SettingsManagerTestKeychainBackend()
        )

        let settings = SettingsManager(
            defaults: defaults,
            controllerRuntimeSecrets: controllerSecrets,
            chatGatewaySecrets: gatewaySecrets,
            flushDelayNanoseconds: 0
        )

        XCTAssertEqual(settings.openClawBearerToken, "legacy-openclaw-token")
        XCTAssertEqual(settings.hermesBearerToken, "legacy-hermes-token")
        XCTAssertEqual(settings.controllerTelegramBotToken, "legacy-telegram-token")
        XCTAssertEqual(settings.gatewayAuthToken, "legacy-gateway-token")
        XCTAssertNil(defaults.object(forKey: "openClawBearerToken"))
        XCTAssertNil(defaults.object(forKey: "hermesBearerToken"))
        XCTAssertNil(defaults.object(forKey: "controllerTelegramBotToken"))
        XCTAssertNil(defaults.object(forKey: "gatewayAuthToken"))
        XCTAssertEqual(
            try gatewaySecrets.string(for: OpenBurnBarIdentity.openClawBearerTokenAccount),
            "legacy-openclaw-token"
        )
        XCTAssertEqual(
            try gatewaySecrets.string(for: OpenBurnBarIdentity.hermesBearerTokenAccount),
            "legacy-hermes-token"
        )
        XCTAssertEqual(
            try gatewaySecrets.string(for: OpenBurnBarIdentity.gatewayAuthTokenAccount),
            "legacy-gateway-token"
        )
        XCTAssertEqual(
            try controllerSecrets.string(for: OpenBurnBarIdentity.controllerTelegramBotTokenAccount),
            "legacy-telegram-token"
        )
    }

    func test_savePersistsTokensToKeychainWithoutUserDefaultsCopies() throws {
        let suiteName = "com.openburnbar.tests.settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controllerSecrets = KeychainStore(
            service: "tests.controller.\(UUID().uuidString)",
            legacyServices: [],
            backend: SettingsManagerTestKeychainBackend()
        )
        let gatewaySecrets = KeychainStore(
            service: "tests.gateway.\(UUID().uuidString)",
            legacyServices: [],
            backend: SettingsManagerTestKeychainBackend()
        )
        let settings = SettingsManager(
            defaults: defaults,
            controllerRuntimeSecrets: controllerSecrets,
            chatGatewaySecrets: gatewaySecrets,
            flushDelayNanoseconds: 0
        )

        settings.controllerTelegramBotToken = "controller-token"
        settings.controllerTelegramChatID = "chat-id"
        settings.openClawBearerToken = "openclaw-token"
        settings.hermesBearerToken = "hermes-token"
        settings.gatewayAuthToken = "gateway-token"

        XCTAssertNil(defaults.object(forKey: "controllerTelegramBotToken"))
        XCTAssertNil(defaults.object(forKey: "openClawBearerToken"))
        XCTAssertNil(defaults.object(forKey: "hermesBearerToken"))
        XCTAssertNil(defaults.object(forKey: "gatewayAuthToken"))
        XCTAssertEqual(defaults.string(forKey: "controllerTelegramChatID"), "chat-id")
        XCTAssertEqual(
            try controllerSecrets.string(for: OpenBurnBarIdentity.controllerTelegramBotTokenAccount),
            "controller-token"
        )
        XCTAssertEqual(
            try gatewaySecrets.string(for: OpenBurnBarIdentity.openClawBearerTokenAccount),
            "openclaw-token"
        )
        XCTAssertEqual(
            try gatewaySecrets.string(for: OpenBurnBarIdentity.hermesBearerTokenAccount),
            "hermes-token"
        )
        XCTAssertEqual(
            try gatewaySecrets.string(for: OpenBurnBarIdentity.gatewayAuthTokenAccount),
            "gateway-token"
        )

        settings.controllerTelegramBotToken = ""
        settings.openClawBearerToken = ""
        settings.hermesBearerToken = ""
        settings.gatewayAuthToken = ""

        XCTAssertNil(try controllerSecrets.string(for: OpenBurnBarIdentity.controllerTelegramBotTokenAccount))
        XCTAssertNil(try gatewaySecrets.string(for: OpenBurnBarIdentity.openClawBearerTokenAccount))
        XCTAssertNil(try gatewaySecrets.string(for: OpenBurnBarIdentity.hermesBearerTokenAccount))
        XCTAssertNil(try gatewaySecrets.string(for: OpenBurnBarIdentity.gatewayAuthTokenAccount))
    }

    func test_generateGatewayAuthToken_producesUniqueURLSafeSecrets() {
        let first = GatewaySettings.generateAuthToken()
        let second = GatewaySettings.generateAuthToken()
        XCTAssertNotEqual(first, second, "Each launch must mint a distinct token")
        XCTAssertFalse(first.isEmpty)
        XCTAssertGreaterThanOrEqual(first.count, 32, "Token must carry meaningful entropy")
        // URL-safe + ps-redaction-safe: hex only, no separators or whitespace.
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        XCTAssertTrue(
            first.unicodeScalars.allSatisfy { allowed.contains($0) },
            "Token must be hex so it survives plist + header transport unescaped"
        )
    }

    func test_ensureGatewayAuthTokenForLaunch_failsClosedByAutoGeneratingToken() {
        let settings = makeIsolatedSettingsManager()

        // A1 fail-closed: a blank token with no explicit opt-in must mint and
        // persist a bearer token so the gateway never launches unauthenticated.
        XCTAssertTrue(settings.gatewayAuthToken.isEmpty)
        XCTAssertFalse(settings.gatewayAllowUnauthenticatedLoopback)

        let generated = settings.ensureGatewayAuthTokenForLaunch()
        let token = try? XCTUnwrap(generated)
        XCTAssertEqual(token, settings.gatewayAuthToken, "Generated token must be persisted to settings")
        XCTAssertFalse((token ?? "").isEmpty)
    }

    func test_ensureGatewayAuthTokenForLaunch_preservesExistingTokenAcrossLaunches() {
        let settings = makeIsolatedSettingsManager()
        settings.gatewayAuthToken = "operator-supplied-token"

        let resolved = settings.ensureGatewayAuthTokenForLaunch()
        XCTAssertEqual(resolved, "operator-supplied-token", "An existing token must survive restarts unchanged")
        XCTAssertEqual(settings.gatewayAuthToken, "operator-supplied-token")
    }

    func test_ensureGatewayAuthTokenForLaunch_returnsNilWhenUnauthenticatedLoopbackOptIn() {
        let settings = makeIsolatedSettingsManager()
        settings.gatewayAllowUnauthenticatedLoopback = true

        let resolved = settings.ensureGatewayAuthTokenForLaunch()
        XCTAssertNil(resolved, "Explicit opt-in must skip token generation")
        XCTAssertTrue(settings.gatewayAuthToken.isEmpty, "No token should be minted when opted out")
    }

    /// Builds a `SettingsManager` backed by an isolated defaults suite and
    /// in-memory keychains so token persistence does not touch the real keychain.
    private func makeIsolatedSettingsManager() -> SettingsManager {
        let suiteName = "com.openburnbar.tests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        return SettingsManager(
            defaults: defaults,
            controllerRuntimeSecrets: KeychainStore(
                service: "tests.controller.\(UUID().uuidString)",
                legacyServices: [],
                backend: SettingsManagerTestKeychainBackend()
            ),
            chatGatewaySecrets: KeychainStore(
                service: "tests.gateway.\(UUID().uuidString)",
                legacyServices: [],
                backend: SettingsManagerTestKeychainBackend()
            ),
            flushDelayNanoseconds: 0
        )
    }

    func test_keychainSet_rewritesEntryWhenNonInteractiveReadInitiallyFails() throws {
        let service = "tests.keychain.rewrite.\(UUID().uuidString)"
        let backend = InteractionLockedWriteTestKeychainBackend()
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)

        try store.set("zai-token", for: "zai")

        XCTAssertEqual(try store.string(for: "zai", allowUserInteraction: false), "zai-token")
        XCTAssertEqual(backend.writeCount(for: service, account: "zai"), 2)
        XCTAssertEqual(backend.deleteCount(for: service, account: "zai"), 1)
    }

    func test_keychainSet_throwsWhenEntryRemainsInteractionLockedAfterRewrite() throws {
        let service = "tests.keychain.fail.\(UUID().uuidString)"
        let store = KeychainStore(
            service: service,
            legacyServices: [],
            backend: AlwaysInteractionLockedTestKeychainBackend()
        )

        XCTAssertThrowsError(try store.set("minimax-token", for: "minimax")) { error in
            guard case KeychainStoreError.writeVerificationFailed = error else {
                return XCTFail("Expected writeVerificationFailed, got \(error)")
            }
        }
    }

    func test_providerAPIKeyStore_setPersistsReadableTokenForQuotaRefreshPath() throws {
        let service = "tests.providerkeys.\(UUID().uuidString)"
        let backend = InteractionLockedWriteTestKeychainBackend()
        let keyStore = ProviderAPIKeyStore(
            keychain: KeychainStore(service: service, legacyServices: [], backend: backend)
        )

        try keyStore.setAPIKey("sk-cp-minimax", for: "minimax")

        XCTAssertEqual(keyStore.apiKey(for: "minimax", allowUserInteraction: false), "sk-cp-minimax")
        XCTAssertEqual(backend.writeCount(for: service, account: "minimax"), 2)
        XCTAssertEqual(backend.deleteCount(for: service, account: "minimax"), 1)
    }

    func test_hermesRelayPublicKeyLookup_doesNotCreateMissingBackgroundKey() throws {
        let service = "tests.hermes.relay.\(UUID().uuidString)"
        let backend = InteractionLockedWriteTestKeychainBackend()
        let keyStore = HermesRelayKeyStore(
            keychain: KeychainStore(service: service, legacyServices: [], backend: backend)
        )

        XCTAssertNil(try keyStore.existingPublicKeyBase64())
        XCTAssertEqual(
            backend.writeCount(for: service, account: "settings.chat.hermes.relay.p256.v1"),
            0
        )
    }

    func test_hermesRelayPrivateKeyFallsBackToStableEphemeralKeyWhenKeychainWriteFails() throws {
        let service = "tests.hermes.relay.fallback.\(UUID().uuidString)"
        let keyStore = HermesRelayKeyStore(
            keychain: KeychainStore(service: service, legacyServices: [], backend: FailingWriteKeychainBackend()),
            fallbackCacheKey: service
        )

        let first = try keyStore.privateKey()
        let second = try keyStore.privateKey()

        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
        XCTAssertEqual(try keyStore.existingPublicKeyBase64(), first.publicKeyBase64)
    }

    func test_piRelayPublicKeyLookup_doesNotCreateMissingBackgroundKey() throws {
        let service = "tests.pi.relay.\(UUID().uuidString)"
        let backend = InteractionLockedWriteTestKeychainBackend()
        let keyStore = PiAgentRelayKeyStore(
            keychain: KeychainStore(service: service, legacyServices: [], backend: backend)
        )

        XCTAssertNil(try keyStore.existingPublicKeyBase64())
        XCTAssertEqual(
            backend.writeCount(for: service, account: "settings.chat.piagent.relay.p256.v1"),
            0
        )
    }

    func test_piRelayPrivateKeyFallsBackToStableEphemeralKeyWhenKeychainWriteFails() throws {
        let service = "tests.pi.relay.fallback.\(UUID().uuidString)"
        let keyStore = PiAgentRelayKeyStore(
            keychain: KeychainStore(service: service, legacyServices: [], backend: FailingWriteKeychainBackend()),
            fallbackCacheKey: service
        )

        let first = try keyStore.privateKey()
        let second = try keyStore.privateKey()

        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
        XCTAssertEqual(try keyStore.existingPublicKeyBase64(), first.publicKeyBase64)
    }

    // MARK: - Keychain Migration Data-Loss Protection (D12)

    func test_load_keychainWriteFails_retainsLegacyDefaultsKey() throws {
        let suiteName = "com.openburnbar.tests.settings.migration-fail.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Seed a legacy value in UserDefaults
        defaults.set("legacy-secret-value", forKey: "openClawBearerToken")

        let backend = FailingWriteKeychainBackend()
        let keychain = KeychainStore(
            service: "tests.failing.\(UUID().uuidString)",
            legacyServices: [],
            backend: backend
        )
        let persistence = SettingsSecretPersistence(defaults: defaults, keychain: keychain)

        let result = persistence.load(
            account: OpenBurnBarIdentity.openClawBearerTokenAccount,
            legacyDefaultsKey: "openClawBearerToken"
        )

        // The legacy value is still returned
        XCTAssertEqual(result, "legacy-secret-value")
        // The legacy UserDefaults key must NOT be deleted when Keychain write fails
        XCTAssertEqual(defaults.string(forKey: "openClawBearerToken"), "legacy-secret-value")
    }

    func test_persist_keychainWriteFails_retainsLegacyDefaultsKey() throws {
        let suiteName = "com.openburnbar.tests.settings.persist-fail.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Seed a legacy value so there's something to protect
        defaults.set("legacy-persist-value", forKey: "hermesBearerToken")

        let backend = FailingWriteKeychainBackend()
        let keychain = KeychainStore(
            service: "tests.failing-persist.\(UUID().uuidString)",
            legacyServices: [],
            backend: backend
        )
        let persistence = SettingsSecretPersistence(defaults: defaults, keychain: keychain)

        persistence.persist(
            "new-hermes-token",
            account: OpenBurnBarIdentity.hermesBearerTokenAccount,
            legacyDefaultsKey: "hermesBearerToken"
        )

        // The legacy UserDefaults key must NOT be deleted when Keychain write fails
        XCTAssertEqual(defaults.string(forKey: "hermesBearerToken"), "legacy-persist-value")
    }

    func test_load_keychainVerificationFails_retainsLegacyDefaultsKey() throws {
        let suiteName = "com.openburnbar.tests.settings.verify-fail.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Seed a legacy value in UserDefaults
        defaults.set("legacy-verify-value", forKey: "gatewayAuthToken")

        let backend = VerificationMismatchKeychainBackend()
        let keychain = KeychainStore(
            service: "tests.verify-mismatch.\(UUID().uuidString)",
            legacyServices: [],
            backend: backend
        )
        let persistence = SettingsSecretPersistence(defaults: defaults, keychain: keychain)

        let result = persistence.load(
            account: OpenBurnBarIdentity.gatewayAuthTokenAccount,
            legacyDefaultsKey: "gatewayAuthToken"
        )

        // The legacy value is still returned
        XCTAssertEqual(result, "legacy-verify-value")
        // The legacy UserDefaults key must NOT be deleted when Keychain verification mismatches
        XCTAssertEqual(defaults.string(forKey: "gatewayAuthToken"), "legacy-verify-value")
    }

}

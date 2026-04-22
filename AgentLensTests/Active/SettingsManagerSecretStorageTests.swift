import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class SettingsManagerSecretStorageTests: XCTestCase {
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
            chatGatewaySecrets: gatewaySecrets
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
            chatGatewaySecrets: gatewaySecrets
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

private final class SettingsManagerTestKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

private final class InteractionLockedWriteTestKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]
    private var lockedEntries = Set<String>()
    private var writeCounts: [String: Int] = [:]
    private var deleteCounts: [String: Int] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        let key = entryKey(service: service, account: account)
        let nextWriteCount = (writeCounts[key] ?? 0) + 1
        writeCounts[key] = nextWriteCount
        storage[service, default: [:]][account] = value
        if nextWriteCount == 1 {
            lockedEntries.insert(key)
        } else {
            lockedEntries.remove(key)
        }
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        let key = entryKey(service: service, account: account)
        if !allowUserInteraction && lockedEntries.contains(key) {
            return nil
        }
        return storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        let key = entryKey(service: service, account: account)
        storage[service]?[account] = nil
        lockedEntries.remove(key)
        deleteCounts[key, default: 0] += 1
    }

    func writeCount(for service: String, account: String) -> Int {
        writeCounts[entryKey(service: service, account: account)] ?? 0
    }

    func deleteCount(for service: String, account: String) -> Int {
        deleteCounts[entryKey(service: service, account: account)] ?? 0
    }

    private func entryKey(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}

private final class AlwaysInteractionLockedTestKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        if !allowUserInteraction {
            return nil
        }
        return storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

/// A KeychainStore backend that always fails on `set` and `delete`,
/// simulating a locked or inaccessible Keychain.
private final class FailingWriteKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_: Data, service: String, account: String) throws {
        throw KeychainStoreError.unhandled(errSecIO)
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service _: String, account _: String) throws {
        throw KeychainStoreError.unhandled(errSecIO)
    }
}

/// A KeychainStore backend that accepts writes but returns a different value on read,
/// simulating a verification mismatch after migration.
private final class VerificationMismatchKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        // Store a *different* value to simulate verification mismatch
        storage[service, default: [:]][account] = "mismatched-value".data(using: .utf8) ?? value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

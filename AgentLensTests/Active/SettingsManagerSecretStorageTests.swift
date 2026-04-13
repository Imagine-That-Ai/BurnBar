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

}

@MainActor

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

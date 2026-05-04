import Foundation

// MARK: - Gateway Settings

@Observable
@MainActor
final class GatewaySettings {
    private let persistence: SettingsPersistenceCoordinator
    private let secretPersistence: SettingsSecretPersistence

    var gatewayEnabled: Bool = false {
        didSet { persistence.set(gatewayEnabled, forKey: "gatewayEnabled") }
    }

    var gatewayHost: String = "127.0.0.1" {
        didSet { persistence.set(gatewayHost, forKey: "gatewayHost") }
    }

    var gatewayPort: Int = 8317 {
        didSet { persistence.set(gatewayPort, forKey: "gatewayPort") }
    }

    var gatewayAuthToken: String = "" {
        didSet {
            secretPersistence.persist(
                gatewayAuthToken,
                account: OpenBurnBarIdentity.gatewayAuthTokenAccount,
                legacyDefaultsKey: SettingsSecretDefaultsKey.gatewayAuthToken
            )
        }
    }

    var gatewayConfigurationDict: [String: Any] {
        [
            "enabled": gatewayEnabled,
            "host": gatewayHost.isEmpty ? "127.0.0.1" : gatewayHost,
            "port": gatewayPort > 0 ? gatewayPort : 8317
        ]
    }

    init(persistence: SettingsPersistenceCoordinator, secretPersistence: SettingsSecretPersistence) {
        self.persistence = persistence
        self.secretPersistence = secretPersistence
        self.gatewayEnabled = persistence.bool(forKey: "gatewayEnabled")
        self.gatewayHost = persistence.string(forKey: "gatewayHost", defaultValue: "127.0.0.1")
        self.gatewayPort = persistence.objectExists(forKey: "gatewayPort")
            ? persistence.integer(forKey: "gatewayPort")
            : 8317
        self.gatewayAuthToken = secretPersistence.load(
            account: OpenBurnBarIdentity.gatewayAuthTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.gatewayAuthToken
        )
    }
}

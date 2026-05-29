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

    /// **Experimental, off by default.** Routes eligible Anthropic subscription
    /// requests through a genuine interactive `claude` TUI (no `-p`) instead of
    /// the metered programmatic path. Gray-area: Anthropic's terms prohibit
    /// routing Pro/Max credentials through third-party apps, and the detection
    /// heuristic is undocumented. When on, the daemon is launched with
    /// `OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE=1`. Requires a daemon restart.
    var experimentalInteractiveClaudeEnabled: Bool = false {
        didSet { persistence.set(experimentalInteractiveClaudeEnabled, forKey: "experimentalInteractiveClaudeEnabled") }
    }

    /// **Experimental, off by default.** When the requested model can't be served
    /// (its provider family is exhausted or unconfigured), substitutes an
    /// allow-listed OpenAI-compatible vendor (DeepSeek/Z.ai/Moonshot) on the
    /// user's own key. When on, the daemon is launched with
    /// `OPENBURNBAR_CROSS_VENDOR_DEGRADE=1`. Requires a daemon restart.
    var crossVendorDegradeEnabled: Bool = false {
        didSet { persistence.set(crossVendorDegradeEnabled, forKey: "crossVendorDegradeEnabled") }
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
        self.experimentalInteractiveClaudeEnabled = persistence.bool(forKey: "experimentalInteractiveClaudeEnabled")
        self.crossVendorDegradeEnabled = persistence.bool(forKey: "crossVendorDegradeEnabled")
    }
}

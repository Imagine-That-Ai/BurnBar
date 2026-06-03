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

    /// Opt-in, off-by-default escape hatch that permits the HTTP gateway to bind
    /// loopback (127.0.0.1) without a bearer token. Fail-closed by default: any
    /// same-host process can POST to the gateway and spend the user's provider
    /// credits, so the gateway auto-generates and enforces a token unless the
    /// user explicitly opts out here. Maps to the daemon
    /// `OPENBURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK` env var at launch.
    var allowUnauthenticatedLoopback: Bool = false {
        didSet { persistence.set(allowUnauthenticatedLoopback, forKey: "gatewayAllowUnauthenticatedLoopback") }
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
        self.allowUnauthenticatedLoopback = persistence.bool(forKey: "gatewayAllowUnauthenticatedLoopback")
        self.experimentalInteractiveClaudeEnabled = persistence.bool(forKey: "experimentalInteractiveClaudeEnabled")
        self.crossVendorDegradeEnabled = persistence.bool(forKey: "crossVendorDegradeEnabled")
    }

    /// Generates a random URL-safe bearer token. The hex-encoded UUID form
    /// matches `rotateDaemonSocketAuthToken()` so both runtime secrets read the
    /// same way and survive a `ps auxww` redaction audit identically.
    static func generateAuthToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Ensures the gateway has a bearer token to enforce before the daemon is
    /// launched. Returns the token that should be injected as
    /// `OPENBURNBAR_GATEWAY_AUTH_TOKEN`, or `nil` when the user has explicitly
    /// opted into an unauthenticated loopback bind.
    ///
    /// Fail-closed: when no token is stored and the user has NOT opted out, a
    /// fresh token is generated and persisted to the keychain so every gateway
    /// launch is authenticated by default. An existing token is preserved so
    /// configured clients (CLI bridges, connectors) keep working across restarts.
    @discardableResult
    func ensureAuthTokenForLaunch() -> String? {
        let trimmed = gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        guard !allowUnauthenticatedLoopback else {
            return nil
        }
        let generated = Self.generateAuthToken()
        gatewayAuthToken = generated
        return generated
    }
}

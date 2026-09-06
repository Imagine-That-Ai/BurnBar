import Foundation
import OpenBurnBarCore

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
                account: OpenBurnBarCore.OpenBurnBarIdentity.gatewayAuthTokenAccount,
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

    /// **Experimental, off by default.** When the requested model can't be served
    /// (its provider family is exhausted or unconfigured), substitutes an
    /// allow-listed OpenAI-compatible vendor (DeepSeek/Z.ai/Moonshot) on the
    /// user's own key. When on, the daemon is launched with
    /// `OPENBURNBAR_CROSS_VENDOR_DEGRADE=1`. Requires a daemon restart.
    var crossVendorDegradeEnabled: Bool = false {
        didSet { persistence.set(crossVendorDegradeEnabled, forKey: "crossVendorDegradeEnabled") }
    }

    init(
        persistence: SettingsPersistenceCoordinator,
        secretPersistence: SettingsSecretPersistence,
        launchAgentAuthTokenReader: @escaping () -> String? = { GatewaySettings.readLaunchAgentAuthToken() }
    ) {
        self.persistence = persistence
        self.secretPersistence = secretPersistence
        self.gatewayEnabled = persistence.bool(forKey: "gatewayEnabled")
        self.gatewayHost = persistence.string(forKey: "gatewayHost", defaultValue: "127.0.0.1")
        self.gatewayPort = persistence.objectExists(forKey: "gatewayPort")
            ? persistence.integer(forKey: "gatewayPort")
            : 8317
        let storedAuthToken = secretPersistence.load(
            account: OpenBurnBarCore.OpenBurnBarIdentity.gatewayAuthTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.gatewayAuthToken
        )
        if storedAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let launchAgentToken = launchAgentAuthTokenReader()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !launchAgentToken.isEmpty {
            self.gatewayAuthToken = launchAgentToken
            secretPersistence.persist(
                launchAgentToken,
                account: OpenBurnBarCore.OpenBurnBarIdentity.gatewayAuthTokenAccount,
                legacyDefaultsKey: SettingsSecretDefaultsKey.gatewayAuthToken
            )
        } else {
            self.gatewayAuthToken = storedAuthToken
        }
        self.allowUnauthenticatedLoopback = persistence.bool(forKey: "gatewayAllowUnauthenticatedLoopback")
        self.crossVendorDegradeEnabled = persistence.bool(forKey: "crossVendorDegradeEnabled")
    }

    /// Generates a 256-bit URL-safe bearer token from the OS CSPRNG. The format
    /// matches `rotateDaemonSocketAuthToken()` so both runtime secrets read the
    /// same way and survive a `ps auxww` redaction audit identically.
    ///
    /// Throws on CSPRNG failure so callers can fail closed instead of crashing
    /// the host process or launching an unauthenticated gateway.
    static func generateAuthToken() throws -> String {
        try OpenBurnBarSecureToken.randomBase64URL()
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
    /// If secure randomness fails, returns nil so the gateway does not launch
    /// without authentication.
    @discardableResult
    func ensureAuthTokenForLaunch() -> String? {
        let trimmed = gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        guard !allowUnauthenticatedLoopback else {
            return nil
        }
        let generated: String
        do {
            generated = try Self.generateAuthToken()
        } catch {
            return nil
        }
        gatewayAuthToken = generated
        return generated
    }

    nonisolated static func readLaunchAgentAuthToken(
        plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.openburnbar.daemon.plist", isDirectory: false)
    ) -> String? {
        let plist: Any
        do {
            let data = try Data(contentsOf: plistURL)
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            return nil
        }
        guard let dictionary = plist as? [String: Any],
              let environment = dictionary["EnvironmentVariables"] as? [String: Any],
              let token = environment["OPENBURNBAR_GATEWAY_AUTH_TOKEN"] as? String else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

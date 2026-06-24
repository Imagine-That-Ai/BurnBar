import Foundation
import OpenBurnBarCore

/// Bootstraps Anthropic gateway routes from an already-signed-in Claude Code OAuth
/// session when the user wires Claude Code but has not yet added an Anthropic
/// provider slot in OpenBurnBar.
enum ClaudeOAuthProviderBootstrap {
    enum BootstrapError: LocalizedError {
        case daemonUnavailable
        case importFailed(String)

        var errorDescription: String? {
            switch self {
            case .daemonUnavailable:
                return "OpenBurnBar daemon must be healthy before Claude OAuth can be imported."
            case .importFailed(let message):
                return message
            }
        }
    }

    /// Returns true when Anthropic has no enabled credential slot in daemon config.
    static func anthropicNeedsCredential(in snapshot: BurnBarProviderConfigurationSnapshot) -> Bool {
        guard let settings = snapshot.providerSettings(id: "anthropic") else { return true }
        guard settings.isEnabled else { return true }
        return !settings.credentialSlots.contains(where: { slot in
            slot.isEnabled && slot.status == .ready
        })
    }

    /// Imports Claude Code OAuth into the Anthropic provider when needed.
    static func bootstrapIfNeeded(
        daemonManager: OpenBurnBarDaemonManager,
        configDirectory: String? = nil,
        allowDefaultKeychainFallback: Bool = true
    ) async throws -> Bool {
        guard case .healthy = await daemonManager.refreshHealthAndReturnStatus() else {
            throw BootstrapError.daemonUnavailable
        }

        let snapshot = try await daemonManager.providerConfigurationSnapshot()
        guard anthropicNeedsCredential(in: snapshot) else { return false }

        let credentials: ClaudeOAuthCredentials
        do {
            credentials = try ClaudeCodeOAuthCredentialImporter(
                configDirectory: configDirectory,
                allowDefaultKeychainFallback: allowDefaultKeychainFallback
            ).load(allowUserInteraction: false)
        } catch {
            throw BootstrapError.importFailed(error.localizedDescription)
        }

        _ = try await daemonManager.addProviderCredentialSlotReturningID(
            providerID: "anthropic",
            label: "Claude Code OAuth",
            apiKey: credentials.routeCredentialStoragePayload(),
            isEnabled: true,
            authMethodID: "anthropic-claude-oauth"
        )
        return true
    }
}

private extension OpenBurnBarDaemonManager {
    func refreshHealthAndReturnStatus() async -> OpenBurnBarDaemonStatus {
        await forceRefreshHealth()
        return status
    }

    func providerConfigurationSnapshot() async throws -> BurnBarProviderConfigurationSnapshot {
        try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.config(at: paths.socketURL)
        }
    }
}
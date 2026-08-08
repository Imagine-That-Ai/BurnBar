import Foundation
import OpenBurnBarCore

// MARK: - Visual Capture Source

/// Where BurnBar visually captures a provider's UI.
///
/// - `cliPTY`: the PTY terminal (default, safe, always available)
/// - `desktopApp`: the provider's desktop app / IDE window (when installed)
public enum VisualCaptureSource: String, Codable, Sendable, CaseIterable {
    case cliPTY = "cli_pty"
    case desktopApp = "desktop_app"
}

// MARK: - Visual Capture Preferences

/// Per-provider + global preference for which visual surface BurnBar shares.
///
/// Persists to `UserDefaults` via `SettingsPersistenceCoordinator`:
/// - `visualCaptureGlobalDefault` → `String` (`VisualCaptureSource.rawValue`)
/// - `visualCapturePerProvider`   → JSON `String` of `[persistedToken: rawValue]`
/// - `visualCaptureSourceToggleEnabled` → `Bool` (feature flag, default `false`)
///
/// Eligibility is hard-coded to the audit-corrected Both set (11 active):
/// `codex`, `claudeCode` (`anthropic`), `cursor` + `cursorAgent`, `factory`,
/// `minimax`, `zai`, `devin`, `hermes`, `warp`, `openCode`, `ollama`.
/// `windsurf` is legacy (now `devin-desktop`) and not toggle-eligible.
/// Plugin-only (`cline`, `kiloCode`, `rooCode`, `augment`, `junie`) and
/// CLI-only (`antigravity`, `geminiCLI`, etc.) always resolve to `.cliPTY`.
@Observable
@MainActor
final class VisualCapturePreferences {
    // MARK: - Keys

    static let globalDefaultKey = "visualCaptureGlobalDefault"
    static let perProviderKey = "visualCapturePerProvider"
    static let toggleEnabledKey = "visualCaptureSourceToggleEnabled"

    // MARK: - Eligibility

    /// Providers that have both a CLI and a Desktop surface and can be toggled.
    ///
    /// Catalog `visualSurfaces` is `["cli","desktop"]` for these; hard-coded here
    /// so the store does not need to decode `catalog.json` at runtime.
    static let toggleEligibleProviders: Set<AgentProvider> = [
        .codex,
        .claudeCode,
        .cursor,
        .cursorAgent,
        .factory,
        .minimax,
        .zai,
        .devin,
        .hermes,
        .warp,
        .openCode,
        .ollama,
    ]

    private let persistence: SettingsPersistenceCoordinator

    // MARK: - Stored state

    var visualCaptureGlobalDefault: VisualCaptureSource = .cliPTY {
        didSet {
            persistence.set(visualCaptureGlobalDefault.rawValue, forKey: Self.globalDefaultKey)
        }
    }

    var visualCapturePerProvider: [AgentProvider: VisualCaptureSource] = [:] {
        didSet {
            persistPerProvider()
        }
    }

    /// Feature flag — gates UI and capture-engine branching. Default `false`
    /// until C/D/E land. Flip via rollout or local toggle.
    var visualCaptureSourceToggleEnabled: Bool = false {
        didSet {
            persistence.set(visualCaptureSourceToggleEnabled, forKey: Self.toggleEnabledKey)
        }
    }

    // MARK: - Init

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence

        // Global default
        if let raw = persistence.optionalString(forKey: Self.globalDefaultKey),
           let parsed = VisualCaptureSource(rawValue: raw) {
            self.visualCaptureGlobalDefault = parsed
        } else {
            self.visualCaptureGlobalDefault = .cliPTY
        }

        // Per-provider map — JSON blob [persistedToken: rawValue]
        if let json = persistence.optionalString(forKey: Self.perProviderKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            var mapped: [AgentProvider: VisualCaptureSource] = [:]
            for (token, rawValue) in decoded {
                guard let provider = AgentProvider.fromPersistedToken(token),
                      let source = VisualCaptureSource(rawValue: rawValue) else { continue }
                mapped[provider] = source
            }
            self.visualCapturePerProvider = mapped
        } else {
            self.visualCapturePerProvider = [:]
        }

        // Feature flag
        if persistence.objectExists(forKey: Self.toggleEnabledKey) {
            self.visualCaptureSourceToggleEnabled = persistence.bool(forKey: Self.toggleEnabledKey)
        } else {
            self.visualCaptureSourceToggleEnabled = false
        }
    }

    // MARK: - Eligibility

    func isToggleEligible(_ provider: AgentProvider) -> Bool {
        Self.toggleEligibleProviders.contains(provider)
    }

    /// Resolves the effective capture source for a provider.
    ///
    /// Ineligible providers (CLI-only or plugin-only) always return `.cliPTY`,
    /// even if a per-provider pref was previously stored (migration safety).
    func visualCaptureSource(for provider: AgentProvider) -> VisualCaptureSource {
        guard isToggleEligible(provider) else { return .cliPTY }
        return visualCapturePerProvider[provider] ?? visualCaptureGlobalDefault
    }

    // MARK: - Mutators

    func setVisualCaptureSource(_ source: VisualCaptureSource, for provider: AgentProvider) {
        var next = visualCapturePerProvider
        next[provider] = source
        visualCapturePerProvider = next
    }

    func clearVisualCaptureSource(for provider: AgentProvider) {
        var next = visualCapturePerProvider
        next.removeValue(forKey: provider)
        visualCapturePerProvider = next
    }

    func clearAllPerProviderPreferences() {
        visualCapturePerProvider = [:]
    }

    // MARK: - Persistence

    private func persistPerProvider() {
        // Encode as [persistedToken: rawValue] with sorted keys for stability.
        let rawDict: [String: String] = Dictionary(
            uniqueKeysWithValues: visualCapturePerProvider.map { ($0.key.persistedToken, $0.value.rawValue) }
        )
        if rawDict.isEmpty {
            // Remove the key when empty so fresh-install checks see nil.
            if persistence.objectExists(forKey: Self.perProviderKey) {
                persistence.removeObject(forKey: Self.perProviderKey)
            }
            return
        }
        if let data = try? JSONEncoder().encode(rawDict),
           let json = String(data: data, encoding: .utf8) {
            persistence.set(json, forKey: Self.perProviderKey)
        }
    }
}

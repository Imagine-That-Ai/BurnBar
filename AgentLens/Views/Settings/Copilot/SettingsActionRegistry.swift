import Foundation
import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Action Registry

/// A declarative whitelist of safe, typed mutations the Settings Copilot can
/// propose and apply. Each action carries a human-readable description, the
/// exact mutation closure, and a deep-link anchor so the user can verify the
/// change after applying.
///
/// **Security contract:** secrets (API keys, bearer tokens, passwords) are
/// NEVER writable through the registry. The copilot can only navigate the
/// user to the right page for those — it cannot set them.
@MainActor
final class SettingsActionRegistry: ObservableObject {

    var settingsManager: SettingsManager
    weak var router: SettingsRouter?

    init(settingsManager: SettingsManager, router: SettingsRouter? = nil) {
        self.settingsManager = settingsManager
        self.router = router
    }

    // MARK: - Action Definition

    /// A single typed, whitelisted mutation.
    struct Action: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        /// Anchor to deep-link + highlight after applying.
        let anchor: String?
        /// Tab to navigate to before applying (so the user sees it happen).
        let tab: SettingsTab?

        static func == (lhs: Action, rhs: Action) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Every action the copilot can propose, keyed by id.
    /// The system prompt carries these as a grammar the LLM can reference.
    static let actionCatalog: [String: String] = [
        "setAppearanceDark": "Switch appearance to Dark mode",
        "setAppearanceLight": "Switch appearance to Light mode",
        "setAppearanceSystem": "Switch appearance to follow System",
        "setSkinAurora": "Switch to the Aurora skin",
        "setSkinEditorial": "Switch to the Editorial skin",
        "enableIndexing": "Turn on conversation indexing and search",
        "disableIndexing": "Turn off conversation indexing",
        "enableModelProxy": "Turn on the local model proxy gateway",
        "disableModelProxy": "Turn off the local model proxy gateway",
        "enableControllerRuntime": "Turn on the controller runtime",
        "disableControllerRuntime": "Turn off the controller runtime",
        "enableAutoSummaries": "Turn on auto session summaries",
        "setRefresh30s": "Set refresh interval to 30 seconds",
        "setRefresh1m": "Set refresh interval to 1 minute",
        "setRefresh5m": "Set refresh interval to 5 minutes",
        "enableDailyDigest": "Turn on the daily spend digest",
        "enableCloudSync": "Turn on cloud sync",
        "openAccounts": "Navigate to agent accounts",
        "openCLIs": "Navigate to CLI connections",
        "openModelProxy": "Navigate to the model proxy settings",
        "openAppearance": "Navigate to appearance settings",
        "openRuntimes": "Navigate to runtime settings",
        "openAlerts": "Navigate to spend alerts",
        "openTextExpansion": "Navigate to text expansion",
        "openDataPrivacy": "Navigate to data and privacy",
        "openCloud": "Navigate to cloud settings",
        "runSetupWizard": "Run the onboarding setup wizard"
    ]

    // MARK: - Apply

    /// Applies a whitelisted action by id. Returns `nil` if the id is unknown.
    @discardableResult
    func apply(actionID: String) -> Action? {
        guard let action = action(for: actionID) else { return nil }

        // Navigate to the owning tab first so the user sees the change land.
        if let tab = action.tab {
            router?.selectedTab = tab
            router?.path.removeAll()
        }

        // Execute the mutation.
        execute(actionID: actionID)

        // Deep-link to the anchor so the changed row highlights.
        if let anchor = action.anchor {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.router?.highlightedAnchor = anchor
                self.router?.scheduleHighlightClear(for: anchor, after: 1.4)
            }
        }

        return action
    }

    /// Builds an `Action` descriptor for a given id (without executing it).
    /// Used by the copilot to render confirm chips.
    func action(for id: String) -> Action? {
        switch id {
        // Appearance
        case "setAppearanceDark":
            return Action(id: id, title: "Dark Mode", detail: "Switch OpenBurnBar to Dark appearance", anchor: SettingsAnchor.appearanceTheme, tab: .general)
        case "setAppearanceLight":
            return Action(id: id, title: "Light Mode", detail: "Switch OpenBurnBar to Light appearance", anchor: SettingsAnchor.appearanceTheme, tab: .general)
        case "setAppearanceSystem":
            return Action(id: id, title: "System Mode", detail: "Follow macOS appearance setting", anchor: SettingsAnchor.appearanceTheme, tab: .general)
        case "setSkinAurora":
            return Action(id: id, title: "Aurora Skin", detail: "Switch to the signature ember Aurora look", anchor: SettingsAnchor.appearanceSkin, tab: .general)
        case "setSkinEditorial":
            return Action(id: id, title: "Editorial Skin", detail: "Switch to the light, paper-bright Editorial palette", anchor: SettingsAnchor.appearanceSkin, tab: .general)

        // Indexing
        case "enableIndexing":
            return Action(id: id, title: "Enable Indexing", detail: "Turn on local conversation indexing and search", anchor: SettingsAnchor.indexingToggle, tab: .general)
        case "disableIndexing":
            return Action(id: id, title: "Disable Indexing", detail: "Turn off local conversation indexing", anchor: SettingsAnchor.indexingToggle, tab: .general)

        // Model Proxy
        case "enableModelProxy":
            return Action(id: id, title: "Enable Model Proxy", detail: "Turn on the local OpenAI-compatible gateway", anchor: SettingsAnchor.gatewayEnabled, tab: .modelProxy)
        case "disableModelProxy":
            return Action(id: id, title: "Disable Model Proxy", detail: "Turn off the local gateway", anchor: SettingsAnchor.gatewayEnabled, tab: .modelProxy)

        // Controller Runtime
        case "enableControllerRuntime":
            return Action(id: id, title: "Enable Controller Runtime", detail: "Mirror daemon missions and replay state", anchor: SettingsAnchor.controllerEnabled, tab: .daemon)
        case "disableControllerRuntime":
            return Action(id: id, title: "Disable Controller Runtime", detail: "Stop polling the daemon for missions", anchor: SettingsAnchor.controllerEnabled, tab: .daemon)

        // Summaries
        case "enableAutoSummaries":
            return Action(id: id, title: "Auto Summaries", detail: "Generate session recaps on each scan", anchor: SettingsAnchor.summariesAuto, tab: .general)

        // Refresh
        case "setRefresh30s":
            return Action(id: id, title: "Refresh: 30s", detail: "Set the scan interval to 30 seconds", anchor: SettingsAnchor.refreshInterval, tab: .general)
        case "setRefresh1m":
            return Action(id: id, title: "Refresh: 1m", detail: "Set the scan interval to 1 minute", anchor: SettingsAnchor.refreshInterval, tab: .general)
        case "setRefresh5m":
            return Action(id: id, title: "Refresh: 5m", detail: "Set the scan interval to 5 minutes", anchor: SettingsAnchor.refreshInterval, tab: .general)

        // Digest
        case "enableDailyDigest":
            return Action(id: id, title: "Daily Digest", detail: "Receive a daily spend summary", anchor: SettingsAnchor.alertsDigest, tab: .alerts)

        // Cloud Sync
        case "enableCloudSync":
            return Action(id: id, title: "Cloud Sync", detail: "Sync usage and conversations to the cloud", anchor: SettingsAnchor.cloudSyncToggle, tab: .devicesAndSync)

        // Navigation-only actions
        case "openAccounts":
            return Action(id: id, title: "Open Accounts", detail: "Go to agent API key management", anchor: nil, tab: .agents)
        case "openCLIs":
            return Action(id: id, title: "Open CLIs", detail: "Go to CLI connection profiles", anchor: nil, tab: .agents)
        case "openModelProxy":
            return Action(id: id, title: "Open Model Proxy", detail: "Go to gateway and routing settings", anchor: nil, tab: .modelProxy)
        case "openAppearance":
            return Action(id: id, title: "Open Appearance", detail: "Go to theme and background settings", anchor: nil, tab: .general)
        case "openRuntimes":
            return Action(id: id, title: "Open Runtimes", detail: "Go to Hermes, Pi, and OpenClaw runtime settings", anchor: nil, tab: .agents)
        case "openAlerts":
            return Action(id: id, title: "Open Alerts", detail: "Go to spend threshold settings", anchor: nil, tab: .alerts)
        case "openTextExpansion":
            return Action(id: id, title: "Open Text Expansion", detail: "Go to snippet and trigger management", anchor: nil, tab: .textExpansion)
        case "openDataPrivacy":
            return Action(id: id, title: "Open Data & Privacy", detail: "Go to vault and privacy controls", anchor: nil, tab: .dataPrivacy)
        case "openCloud":
            return Action(id: id, title: "Open Cloud", detail: "Go to OpenBurnBar Cloud settings", anchor: nil, tab: .cloud)
        case "runSetupWizard":
            return Action(id: id, title: "Run Setup Wizard", detail: "Launch the guided onboarding wizard", anchor: SettingsAnchor.operatorWizard, tab: .general)

        default:
            return nil
        }
    }

    /// Executes the mutation for a known action id.
    private func execute(actionID: String) {
        switch actionID {
        case "setAppearanceDark":   settingsManager.appearanceMode = .dark
        case "setAppearanceLight":  settingsManager.appearanceMode = .light
        case "setAppearanceSystem": settingsManager.appearanceMode = .system
        case "setSkinAurora":       settingsManager.appearanceSkin = .aurora
        case "setSkinEditorial":    settingsManager.appearanceSkin = .editorial

        case "enableIndexing":      settingsManager.conversationIndexingEnabled = true
        case "disableIndexing":     settingsManager.conversationIndexingEnabled = false

        case "enableModelProxy":    settingsManager.gatewayEnabled = true
        case "disableModelProxy":   settingsManager.gatewayEnabled = false

        case "enableControllerRuntime":   settingsManager.controllerRuntimeEnabled = true
        case "disableControllerRuntime":  settingsManager.controllerRuntimeEnabled = false

        case "enableAutoSummaries": settingsManager.autoSessionSummariesEnabled = true

        case "setRefresh30s":       settingsManager.refreshInterval = 30
        case "setRefresh1m":        settingsManager.refreshInterval = 60
        case "setRefresh5m":        settingsManager.refreshInterval = 300

        case "enableDailyDigest":   settingsManager.dailyDigestEnabled = true

        case "enableCloudSync":     settingsManager.conversationCloudBackupEnabled = true

        case "runSetupWizard":
            // Navigate to the General tab where the wizard lives.
            // The user can click "Run Setup Wizard" from there.
            break

        // Navigation-only actions: no mutation needed.
        case "openAccounts", "openCLIs", "openModelProxy", "openAppearance",
             "openRuntimes", "openAlerts", "openTextExpansion", "openDataPrivacy",
             "openCloud":
            break

        default:
            break
        }

        Analytics.shared.track(.settingsChanged, [
            "setting_key": "copilot_action",
            "new_value": .string(actionID)
        ])
    }

    // MARK: - Snapshot

    /// A human-readable snapshot of the current settings state, injected into
    /// the copilot's system prompt so the LLM has context.
    func settingsSnapshot() -> String {
        var lines: [String] = []
        lines.append("Appearance mode: \(settingsManager.appearanceMode.rawValue)")
        lines.append("Skin: \(settingsManager.appearanceSkin.rawValue)")
        lines.append("Indexing: \(settingsManager.conversationIndexingEnabled ? "on" : "off")")
        lines.append("Model proxy: \(settingsManager.gatewayEnabled ? "on" : "off")")
        if settingsManager.gatewayEnabled {
            lines.append("  endpoint: \(settingsManager.gatewayHost):\(settingsManager.gatewayPort)")
        }
        lines.append("Controller runtime: \(settingsManager.controllerRuntimeEnabled ? "on" : "off")")
        lines.append("Auto summaries: \(settingsManager.autoSessionSummariesEnabled ? "on" : "off")")
        lines.append("Refresh interval: \(Int(settingsManager.refreshInterval))s")
        lines.append("Daily digest: \(settingsManager.dailyDigestEnabled ? "on" : "off")")
        lines.append("Cloud sync: \(settingsManager.conversationCloudBackupEnabled ? "on" : "off")")
        lines.append("Hermes auto-launch: \(settingsManager.launchHermesWithOpenBurnBar ? "on" : "off")")
        return lines.joined(separator: "\n")
    }
}

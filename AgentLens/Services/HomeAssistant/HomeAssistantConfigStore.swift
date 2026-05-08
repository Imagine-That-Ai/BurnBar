import Foundation

// MARK: - HA Config Store
//
// Wraps the JSON-encoded representation of `HomeAssistantConfig` that
// lives in UserDefaults. The token+webhook secret are stored separately
// in `HomeAssistantTokenStore`; this store is only for non-secret
// metadata (URL, entity ID, last verified at).

protocol HomeAssistantConfigStoring: AnyObject, Sendable {
    func loadConfig() -> HomeAssistantConfig?
    func saveConfig(_ config: HomeAssistantConfig)
    func clear()
    var legacyWebhookURLString: String { get }
    func clearLegacyWebhookURL()
}

@MainActor
final class HomeAssistantConfigStore: HomeAssistantConfigStoring, @unchecked Sendable {

    private let settingsManager: SettingsManager
    private let key = "smartHubHomeAssistantConfigJSON"

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    func loadConfig() -> HomeAssistantConfig? {
        let raw = settingsManager.persistence.string(forKey: key, defaultValue: "")
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HomeAssistantConfig.self, from: data)
    }

    func saveConfig(_ config: HomeAssistantConfig) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(config), let json = String(data: data, encoding: .utf8) else {
            return
        }
        settingsManager.persistence.set(json, forKey: key)
        // Mirror webhook URL to the legacy raw URL field so all the
        // existing call sites (CastReconnectStrategy, listener, manual
        // test button) keep working without lookups.
        if let url = config.webhookURL {
            settingsManager.smartHubHomeAssistantRecoveryWebhookURL = url.absoluteString
        }
        settingsManager.persistence.flush()
    }

    func clear() {
        settingsManager.persistence.set("", forKey: key)
        settingsManager.smartHubHomeAssistantRecoveryWebhookURL = ""
        settingsManager.persistence.flush()
    }

    /// User may have already pasted a raw webhook URL via Advanced
    /// settings before installing the wizard. We expose it as a
    /// "legacy" path so the wizard's first step can present it as
    /// an existing manual setup the user can keep or replace.
    var legacyWebhookURLString: String {
        settingsManager.smartHubHomeAssistantRecoveryWebhookURL
    }

    func clearLegacyWebhookURL() {
        settingsManager.smartHubHomeAssistantRecoveryWebhookURL = ""
    }
}

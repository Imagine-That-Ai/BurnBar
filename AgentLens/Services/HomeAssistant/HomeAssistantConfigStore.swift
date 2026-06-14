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

/// Minimal encoding seam for `HomeAssistantConfig`, injectable so tests can
/// drive the encode-failure path deterministically without depending on
/// `JSONEncoder` subclassing semantics.
protocol HomeAssistantConfigEncoding: Sendable {
    func encode(_ config: HomeAssistantConfig) throws -> Data
}

/// Production encoder: ISO8601 dates, matching `HomeAssistantConfigStore.loadConfig`.
struct HomeAssistantConfigJSONEncoder: HomeAssistantConfigEncoding {
    func encode(_ config: HomeAssistantConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(config)
    }
}

@MainActor
final class HomeAssistantConfigStore: @preconcurrency HomeAssistantConfigStoring {

    private let settingsManager: SettingsManager
    private let key = "smartHubHomeAssistantConfigJSON"

    /// Encoder used by `saveConfig`. Injectable so tests can drive the
    /// encode-failure path deterministically; production uses the ISO8601 JSON
    /// encoder that mirrors `loadConfig`'s decoder.
    private let encoder: HomeAssistantConfigEncoding

    init(
        settingsManager: SettingsManager,
        encoder: HomeAssistantConfigEncoding = HomeAssistantConfigJSONEncoder()
    ) {
        self.settingsManager = settingsManager
        self.encoder = encoder
    }

    func loadConfig() -> HomeAssistantConfig? {
        let raw = settingsManager.persistence.string(forKey: key, defaultValue: "")
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HomeAssistantConfig.self, from: data) // try?-ok(optional decode, nil-handled)
    }

    func saveConfig(_ config: HomeAssistantConfig) {
        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            // A dropped save must be observable: the persisted config feeds
            // later recovery behavior (webhook URL mirrored to settings, last
            // verified state). Swallowing this silently would lose the user's
            // configuration with no signal. Skip the write but log the fault.
            AppLogger.dataStore.error(
                "ha_config_save_encode_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return
        }
        guard let json = String(data: data, encoding: .utf8) else {
            // JSON output is always UTF-8, so this is effectively unreachable,
            // but a non-nil failure here would still silently drop the save —
            // log it instead of returning blindly.
            AppLogger.dataStore.error("ha_config_save_utf8_decode_failed")
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

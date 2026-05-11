import Foundation
import OpenBurnBarCore

// MARK: - Quota Settings

@Observable
@MainActor
final class QuotaSettings {
    private let persistence: SettingsPersistenceCoordinator

    var miniMaxQuotaMode: MiniMaxQuotaMode = .tokenPlan {
        didSet { persistence.set(miniMaxQuotaMode, forKey: "miniMaxQuotaMode") }
    }

    var factoryQuotaPlanTier: FactoryQuotaPlanTier = .unknown {
        didSet { persistence.set(factoryQuotaPlanTier, forKey: "factoryQuotaPlanTier") }
    }

    var tokenizerAssistedFallbackEnabled: Bool = false {
        didSet { persistence.set(tokenizerAssistedFallbackEnabled, forKey: "tokenizerAssistedFallbackEnabled") }
    }

    var smartHubQuotaDisplayEnabled: Bool = false {
        didSet { persistence.set(smartHubQuotaDisplayEnabled, forKey: "smartHubQuotaDisplayEnabled") }
    }

    var smartHubQuotaDashboardURL: String = "http://127.0.0.1:8787/render.html" {
        didSet { persistence.set(smartHubQuotaDashboardURL, forKey: "smartHubQuotaDashboardURL") }
    }

    var smartHubQuotaRefreshURL: String = "http://127.0.0.1:8787/refresh" {
        didSet { persistence.set(smartHubQuotaRefreshURL, forKey: "smartHubQuotaRefreshURL") }
    }

    var smartHubQuotaVoiceRefreshURL: String = "http://127.0.0.1:8787/voice-refresh" {
        didSet { persistence.set(smartHubQuotaVoiceRefreshURL, forKey: "smartHubQuotaVoiceRefreshURL") }
    }

    var smartHubQuotaTimePeriod: SmartHubTimePeriod = .rolling5h {
        didSet { persistence.set(smartHubQuotaTimePeriod.rawValue, forKey: "smartHubQuotaTimePeriod") }
    }

    var smartHubHomeAssistantRecoveryWebhookURL: String = "" {
        didSet { persistence.set(smartHubHomeAssistantRecoveryWebhookURL, forKey: "smartHubHomeAssistantRecoveryWebhookURL") }
    }

    var pixelClockConfig: PixelClockConfig = .disabled {
        didSet {
            if let data = try? JSONEncoder().encode(pixelClockConfig),
               let raw = String(data: data, encoding: .utf8) {
                persistence.set(raw, forKey: "pixelClockConfig")
            }
        }
    }

    var smartHubDisplayConfig: SmartHubDisplayConfig = .default {
        didSet {
            if let data = try? JSONEncoder().encode(smartHubDisplayConfig),
               let raw = String(data: data, encoding: .utf8) {
                persistence.set(raw, forKey: "smartHubDisplayConfig")
            }
        }
    }

    var smartDisplayOrder: SmartDisplayOrder = .default {
        didSet {
            if let data = try? JSONEncoder().encode(smartDisplayOrder),
               let raw = String(data: data, encoding: .utf8) {
                persistence.set(raw, forKey: "smartDisplayOrder")
            }
        }
    }

    // MARK: Cast Wizard Selection
    //
    // Persisted choice from the Setup Cast Wizard. The service name is
    // the canonical mDNS instance id and survives IP changes; we cache
    // friendly name + model so the Settings status card doesn't need a
    // rescan to render.

    var castSelectedDeviceServiceName: String = "" {
        didSet { persistence.set(castSelectedDeviceServiceName, forKey: "castSelectedDeviceServiceName") }
    }

    var castSelectedDeviceFriendlyName: String = "" {
        didSet { persistence.set(castSelectedDeviceFriendlyName, forKey: "castSelectedDeviceFriendlyName") }
    }

    var castSelectedDeviceModel: String = "" {
        didSet { persistence.set(castSelectedDeviceModel, forKey: "castSelectedDeviceModel") }
    }

    var castSelectedDeviceHost: String = "" {
        didSet { persistence.set(castSelectedDeviceHost, forKey: "castSelectedDeviceHost") }
    }

    var castSelectedDevicePort: Int = 8009 {
        didSet { persistence.set(castSelectedDevicePort, forKey: "castSelectedDevicePort") }
    }

    var castSelectedDeviceIdentifier: String = "" {
        didSet { persistence.set(castSelectedDeviceIdentifier, forKey: "castSelectedDeviceIdentifier") }
    }

    var castSelectedDeviceSupportsDisplay: Bool = true {
        didSet { persistence.set(castSelectedDeviceSupportsDisplay, forKey: "castSelectedDeviceSupportsDisplay") }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        if let billingModeRaw = persistence.optionalString(forKey: "miniMaxQuotaMode"),
           let billingMode = MiniMaxQuotaMode(rawValue: billingModeRaw) {
            self.miniMaxQuotaMode = billingMode
        } else {
            self.miniMaxQuotaMode = .tokenPlan
        }
        if let planTierRaw = persistence.optionalString(forKey: "factoryQuotaPlanTier"),
           let planTier = FactoryQuotaPlanTier(rawValue: planTierRaw) {
            self.factoryQuotaPlanTier = planTier
        } else {
            self.factoryQuotaPlanTier = .unknown
        }
        if persistence.objectExists(forKey: "tokenizerAssistedFallbackEnabled") {
            self.tokenizerAssistedFallbackEnabled = persistence.bool(forKey: "tokenizerAssistedFallbackEnabled")
        } else {
            self.tokenizerAssistedFallbackEnabled = false
        }
        self.smartHubQuotaDisplayEnabled = persistence.bool(forKey: "smartHubQuotaDisplayEnabled")
        self.smartHubQuotaDashboardURL = persistence.string(
            forKey: "smartHubQuotaDashboardURL",
            defaultValue: "http://127.0.0.1:8787/render.html"
        )
        self.smartHubQuotaRefreshURL = persistence.string(
            forKey: "smartHubQuotaRefreshURL",
            defaultValue: "http://127.0.0.1:8787/refresh"
        )
        self.smartHubQuotaVoiceRefreshURL = persistence.string(
            forKey: "smartHubQuotaVoiceRefreshURL",
            defaultValue: "http://127.0.0.1:8787/voice-refresh"
        )
        if let raw = persistence.optionalString(forKey: "smartHubQuotaTimePeriod"),
           let value = SmartHubTimePeriod(rawValue: raw) {
            self.smartHubQuotaTimePeriod = value
        } else {
            self.smartHubQuotaTimePeriod = .rolling5h
        }
        self.smartHubHomeAssistantRecoveryWebhookURL = persistence.string(
            forKey: "smartHubHomeAssistantRecoveryWebhookURL",
            defaultValue: ""
        )
        if let raw = persistence.optionalString(forKey: "pixelClockConfig"),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PixelClockConfig.self, from: data) {
            self.pixelClockConfig = decoded
        } else {
            self.pixelClockConfig = .disabled
        }
        if let raw = persistence.optionalString(forKey: "smartHubDisplayConfig"),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SmartHubDisplayConfig.self, from: data) {
            self.smartHubDisplayConfig = decoded
        } else {
            self.smartHubDisplayConfig = .default
        }
        if let raw = persistence.optionalString(forKey: "smartDisplayOrder"),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SmartDisplayOrder.self, from: data) {
            self.smartDisplayOrder = decoded
        } else {
            self.smartDisplayOrder = .default
        }
        self.castSelectedDeviceServiceName = persistence.string(
            forKey: "castSelectedDeviceServiceName",
            defaultValue: ""
        )
        self.castSelectedDeviceFriendlyName = persistence.string(
            forKey: "castSelectedDeviceFriendlyName",
            defaultValue: ""
        )
        self.castSelectedDeviceModel = persistence.string(
            forKey: "castSelectedDeviceModel",
            defaultValue: ""
        )
        self.castSelectedDeviceHost = persistence.string(
            forKey: "castSelectedDeviceHost",
            defaultValue: ""
        )
        let storedPort = persistence.integer(forKey: "castSelectedDevicePort")
        self.castSelectedDevicePort = storedPort > 0 ? storedPort : 8009
        self.castSelectedDeviceIdentifier = persistence.string(
            forKey: "castSelectedDeviceIdentifier",
            defaultValue: ""
        )
        if persistence.objectExists(forKey: "castSelectedDeviceSupportsDisplay") {
            self.castSelectedDeviceSupportsDisplay = persistence.bool(forKey: "castSelectedDeviceSupportsDisplay")
        } else {
            self.castSelectedDeviceSupportsDisplay = true
        }
    }
}

import Foundation

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
    }
}

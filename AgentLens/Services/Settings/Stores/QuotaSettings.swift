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
    }
}

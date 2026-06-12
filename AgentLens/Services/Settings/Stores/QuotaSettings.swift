import Foundation
import OpenBurnBarCore

// MARK: - Quota Percentage Display Mode

public enum QuotaPercentageDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case remainingPercent
    case usedPercent
    case absoluteValues
    case fractional

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .remainingPercent: return "Remaining % (e.g., 20%)"
        case .usedPercent: return "Used % (e.g., 80%)"
        case .absoluteValues: return "Absolute values (e.g., 4.0M / 20.0M)"
        case .fractional: return "Decimal fraction (e.g., 0.20)"
        }
    }
}

// MARK: - Quota Settings

@Observable
@MainActor
final class QuotaSettings {
    private static let defaultProviderOrderCSV = AgentProvider.quotaSignalProviders
        .map(\.persistedToken)
        .joined(separator: ",")

    private static func quotaProviderTokens(from csv: String) -> [String] {
        csv
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func dedupedQuotaProviders(from providers: [AgentProvider]) -> [AgentProvider] {
        var deduped: [AgentProvider] = []
        for provider in providers where provider.isQuotaSignalProvider && !deduped.contains(provider) {
            deduped.append(provider)
        }
        return deduped
    }

    private static func quotaProviders(fromTokens tokens: [String]) -> [AgentProvider] {
        dedupedQuotaProviders(from: tokens.compactMap { AgentProvider.fromPersistedToken($0) })
    }

    private static func providerCSV(from providers: [AgentProvider]) -> String {
        dedupedQuotaProviders(from: providers)
            .map(\.persistedToken)
            .joined(separator: ",")
    }

    private static func visibleProviderCSV(from providers: Set<AgentProvider>) -> String {
        let visibleQuotaProviders = Set(providers.filter(\.isQuotaSignalProvider))
        return AgentProvider.quotaSignalProviders
            .filter { visibleQuotaProviders.contains($0) }
            .map(\.persistedToken)
            .joined(separator: ",")
    }

    private let persistence: SettingsPersistenceCoordinator

    var providerOrderCSV: String = QuotaSettings.defaultProviderOrderCSV {
        didSet { persistence.set(providerOrderCSV, forKey: "providerOrderCSV") }
    }

    var visibleProvidersCSV: String = QuotaSettings.defaultProviderOrderCSV {
        didSet { persistence.set(visibleProvidersCSV, forKey: "visibleProvidersCSV") }
    }

    var hiddenBuckets: Set<String> = [] {
        didSet {
            let array = Array(hiddenBuckets)
            if let data = try? JSONEncoder().encode(array),
               let raw = String(data: data, encoding: .utf8) {
                persistence.set(raw, forKey: "hiddenBucketsJSON")
            }
        }
    }

    var bucketOrders: [String: [String]] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(bucketOrders),
               let raw = String(data: data, encoding: .utf8) {
                persistence.set(raw, forKey: "bucketOrdersJSON")
            }
        }
    }

    var percentageDisplayMode: QuotaPercentageDisplayMode = .remainingPercent {
        didSet { persistence.set(percentageDisplayMode.rawValue, forKey: "percentageDisplayMode") }
    }

    var providerOrder: [AgentProvider] {
        get {
            let tokens = Self.quotaProviderTokens(from: providerOrderCSV)
            let parsed = Self.quotaProviders(fromTokens: tokens)
            if parsed.isEmpty {
                return AgentProvider.quotaSignalProviders
            }
            var ordered = parsed
            for provider in AgentProvider.quotaSignalProviders where !ordered.contains(provider) {
                ordered.append(provider)
            }
            return ordered
        }
        set {
            providerOrderCSV = Self.providerCSV(from: newValue)
        }
    }

    var visibleProviders: Set<AgentProvider> {
        get {
            let tokens = Self.quotaProviderTokens(from: visibleProvidersCSV)
            guard !tokens.isEmpty else { return [] }
            let parsed = Self.quotaProviders(fromTokens: tokens)
            guard !parsed.isEmpty else {
                return Set(AgentProvider.quotaSignalProviders)
            }
            return Set(parsed)
        }
        set {
            visibleProvidersCSV = Self.visibleProviderCSV(from: newValue)
        }
    }

    func setProvider(_ provider: AgentProvider, visible: Bool) {
        guard provider.isQuotaSignalProvider else { return }
        var providers = visibleProviders
        if visible {
            providers.insert(provider)
        } else {
            providers.remove(provider)
        }
        visibleProviders = providers
    }

    func showAllProviders() {
        visibleProviders = Set(AgentProvider.quotaSignalProviders)
    }

    func resetProviderOrder() {
        providerOrder = AgentProvider.quotaSignalProviders
    }

    var miniMaxQuotaMode: MiniMaxQuotaMode = .tokenPlan {
        didSet { persistence.set(miniMaxQuotaMode, forKey: "miniMaxQuotaMode") }
    }

    var factoryQuotaPlanTier: FactoryQuotaPlanTier = .unknown {
        didSet { persistence.set(factoryQuotaPlanTier, forKey: "factoryQuotaPlanTier") }
    }

    var xaiQuotaPlanTier: XAIQuotaPlanTier = .unknown {
        didSet { persistence.set(xaiQuotaPlanTier, forKey: "xaiQuotaPlanTier") }
    }

    var mimoTokenPlanRegion: ProviderEndpointRegion = .sgp {
        didSet { persistence.set(mimoTokenPlanRegion.rawValue, forKey: "mimoTokenPlanRegion") }
    }

    var mimoTokenPlanTier: MimoTokenPlanTier? {
        didSet {
            if let mimoTokenPlanTier {
                persistence.set(mimoTokenPlanTier.rawValue, forKey: "mimoTokenPlanTier")
            } else {
                persistence.removeObject(forKey: "mimoTokenPlanTier")
            }
        }
    }

    var mimoTokenPlanBillingCycle: MimoTokenPlanBillingCycle = .monthly {
        didSet { persistence.set(mimoTokenPlanBillingCycle.rawValue, forKey: "mimoTokenPlanBillingCycle") }
    }

    var tokenizerAssistedFallbackEnabled: Bool = false {
        didSet { persistence.set(tokenizerAssistedFallbackEnabled, forKey: "tokenizerAssistedFallbackEnabled") }
    }

    /// When true, the dashboard / popover / menu-bar collapse multi-account
    /// providers into one combined entry summed across accounts. Default
    /// off — preserves the per-account view for users with only one
    /// account on each provider.
    var cumulativeAcrossAccounts: Bool = false {
        didSet { persistence.set(cumulativeAcrossAccounts, forKey: "cumulativeAcrossAccounts") }
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
        if let xaiTierRaw = persistence.optionalString(forKey: "xaiQuotaPlanTier"),
           let xaiTier = XAIQuotaPlanTier(rawValue: xaiTierRaw) {
            self.xaiQuotaPlanTier = xaiTier
        } else {
            self.xaiQuotaPlanTier = .unknown
        }
        if let regionRaw = persistence.optionalString(forKey: "mimoTokenPlanRegion"),
           let region = ProviderEndpointRegion(rawValue: regionRaw) {
            self.mimoTokenPlanRegion = region
        } else {
            self.mimoTokenPlanRegion = .sgp
        }
        if let tierRaw = persistence.optionalString(forKey: "mimoTokenPlanTier"),
           let tier = MimoTokenPlanTier(rawValue: tierRaw) {
            self.mimoTokenPlanTier = tier
        } else {
            self.mimoTokenPlanTier = nil
        }
        if let cycleRaw = persistence.optionalString(forKey: "mimoTokenPlanBillingCycle"),
           let cycle = MimoTokenPlanBillingCycle(rawValue: cycleRaw) {
            self.mimoTokenPlanBillingCycle = cycle
        } else {
            self.mimoTokenPlanBillingCycle = .monthly
        }
        if persistence.objectExists(forKey: "tokenizerAssistedFallbackEnabled") {
            self.tokenizerAssistedFallbackEnabled = persistence.bool(forKey: "tokenizerAssistedFallbackEnabled")
        } else {
            self.tokenizerAssistedFallbackEnabled = false
        }
        if persistence.objectExists(forKey: "cumulativeAcrossAccounts") {
            self.cumulativeAcrossAccounts = persistence.bool(forKey: "cumulativeAcrossAccounts")
        } else {
            self.cumulativeAcrossAccounts = false
        }
        self.providerOrderCSV = persistence.string(
            forKey: "providerOrderCSV",
            defaultValue: Self.defaultProviderOrderCSV
        )
        self.visibleProvidersCSV = persistence.string(
            forKey: "visibleProvidersCSV",
            defaultValue: Self.defaultProviderOrderCSV
        )
        if let raw = persistence.optionalString(forKey: "hiddenBucketsJSON"),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.hiddenBuckets = Set(decoded)
        } else {
            self.hiddenBuckets = []
        }
        if let raw = persistence.optionalString(forKey: "bucketOrdersJSON"),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.bucketOrders = decoded
        } else {
            self.bucketOrders = [:]
        }
        if let raw = persistence.optionalString(forKey: "percentageDisplayMode"),
           let mode = QuotaPercentageDisplayMode(rawValue: raw) {
            self.percentageDisplayMode = mode
        } else {
            self.percentageDisplayMode = .remainingPercent
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

import Foundation
import FirebaseCore
import FirebaseRemoteConfig
import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Manager

/// Composition root for all app configuration.
///
/// `SettingsManager` is no longer a god-object. It exposes domain-specific stores as `let`
/// properties and delegates persistence to `SettingsPersistenceCoordinator`, which tracks
/// dirty keys and flushes coalesced writes after a short debounce.
@Observable
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private static let controllerRuntimeSecrets = KeychainStore(
        service: OpenBurnBarIdentity.controllerRuntimeKeychainService,
        legacyServices: OpenBurnBarIdentity.legacyControllerRuntimeKeychainServices
    )

    private static let chatGatewaySecrets = KeychainStore(
        service: OpenBurnBarIdentity.chatGatewayKeychainService,
        legacyServices: OpenBurnBarIdentity.legacyChatGatewayKeychainServices
    )

    // MARK: - Domain Stores

    let persistence: SettingsPersistenceCoordinator
    let appearance: AppearanceSettings
    let behavior: BehaviorSettings
    let alerts: AlertSettings
    let controller: ControllerSettings
    let gateway: GatewaySettings
    let chatBackend: ChatBackendSettings
    let index: IndexSettings
    let crossEncoder: CrossEncoderSettings
    let cloudSync: CloudSyncSettings
    let cliAssistant: CLIAssistantSettings
    let summary: SummarySettings
    let quotas: QuotaSettings
    let providerPath: ProviderPathSettings
    let artifactDiscovery: ArtifactDiscoverySettings
    private var computerUseRemoteConfigTask: Task<Void, Never>?

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        controllerRuntimeSecrets: KeychainStore = SettingsManager.controllerRuntimeSecrets,
        chatGatewaySecrets: KeychainStore = SettingsManager.chatGatewaySecrets,
        flushDelayNanoseconds: UInt64 = 100_000_000
    ) {
        let coordinator = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: flushDelayNanoseconds)
        self.persistence = coordinator

        let controllerSecretPersistence = SettingsSecretPersistence(
            defaults: defaults,
            keychain: controllerRuntimeSecrets
        )
        let chatGatewaySecretPersistence = SettingsSecretPersistence(
            defaults: defaults,
            keychain: chatGatewaySecrets
        )

        self.appearance = AppearanceSettings(persistence: coordinator)
        self.behavior = BehaviorSettings(persistence: coordinator)
        self.alerts = AlertSettings(persistence: coordinator)
        self.controller = ControllerSettings(
            persistence: coordinator,
            secretPersistence: controllerSecretPersistence
        )
        self.gateway = GatewaySettings(
            persistence: coordinator,
            secretPersistence: chatGatewaySecretPersistence
        )
        self.chatBackend = ChatBackendSettings(
            persistence: coordinator,
            secretPersistence: chatGatewaySecretPersistence
        )
        self.index = IndexSettings(persistence: coordinator)
        self.crossEncoder = CrossEncoderSettings(persistence: coordinator)
        self.cloudSync = CloudSyncSettings(persistence: coordinator)
        self.cliAssistant = CLIAssistantSettings(persistence: coordinator)
        self.summary = SummarySettings(persistence: coordinator)
        self.quotas = QuotaSettings(persistence: coordinator)
        self.providerPath = ProviderPathSettings(persistence: coordinator)
        self.artifactDiscovery = ArtifactDiscoverySettings(persistence: coordinator)

        // Register periodic flush on app background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(flushPendingWrites),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        startComputerUseRemoteConfigPolling()
    }

    @objc private func flushPendingWrites() {
        persistence.flush()
    }

    private func startComputerUseRemoteConfigPolling() {
        computerUseRemoteConfigTask?.cancel()
        computerUseRemoteConfigTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshComputerUseRemoteConfigOnce()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func refreshComputerUseRemoteConfigOnce() async {
        guard FirebaseApp.app() != nil else { return }
        let remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.setDefaults([
            "computer_use_watch_enabled": false as NSObject,
            "computer_use_browser_enabled": false as NSObject,
            "computer_use_system_enabled": false as NSObject,
            "computer_use_phone_control_enabled": false as NSObject,
            "computer_use_trust_modes_enabled": false as NSObject,
            "computer_use_polish_enabled": false as NSObject,
            "computer_use_kill_switch": false as NSObject
        ])

        _ = await withCheckedContinuation { continuation in
            remoteConfig.fetchAndActivate { status, error in
                continuation.resume(returning: (status, error))
            }
        }

        computerUseWatchEnabled = remoteConfig.configValue(forKey: "computer_use_watch_enabled").boolValue
        computerUseBrowserEnabled = remoteConfig.configValue(forKey: "computer_use_browser_enabled").boolValue
        computerUseSystemEnabled = remoteConfig.configValue(forKey: "computer_use_system_enabled").boolValue
        computerUsePhoneControlEnabled = remoteConfig.configValue(forKey: "computer_use_phone_control_enabled").boolValue
        computerUseTrustedScopesEnabled = remoteConfig.configValue(forKey: "computer_use_trust_modes_enabled").boolValue
        computerUseAuditExportEnabled = remoteConfig.configValue(forKey: "computer_use_polish_enabled").boolValue

        let killSwitchEnabled = remoteConfig.configValue(forKey: "computer_use_kill_switch").boolValue
        computerUseKillSwitch = killSwitchEnabled
        if killSwitchEnabled {
            NotificationCenter.default.post(name: .computerUseRemoteConfigKillSwitchDidFire, object: self)
        }
    }

    // MARK: - Backward Compatibility (Computed Properties)

    // These computed properties bridge the old SettingsManager interface to the new
    // domain stores, allowing views and services to migrate incrementally.

    // MARK: Appearance / Behavior
    var appearanceMode: AppearanceMode {
        get { appearance.appearanceMode }
        set { appearance.appearanceMode = newValue }
    }

    var showInMenuBar: Bool {
        get { appearance.showInMenuBar }
        set { appearance.showInMenuBar = newValue }
    }

    var preferredSwiftUIColorScheme: ColorScheme? {
        appearance.appearanceMode.colorScheme
    }

    var launchAtLogin: Bool {
        get { behavior.launchAtLogin }
        set { behavior.launchAtLogin = newValue }
    }

    var refreshInterval: TimeInterval {
        get { behavior.refreshInterval }
        set { behavior.refreshInterval = newValue }
    }

    var refreshIntervalMinutes: Double {
        get { behavior.refreshIntervalMinutes }
        set { behavior.refreshInterval = newValue * 60 }
    }

    var defaultTimeRange: TimeRange {
        get { behavior.defaultTimeRange }
        set { behavior.defaultTimeRange = newValue }
    }

    var usageDisplayMode: UsageDisplayMode {
        get { behavior.usageDisplayMode }
        set { behavior.usageDisplayMode = newValue }
    }

    // MARK: Alerts
    var costAlertThreshold: Double? {
        get { alerts.costAlertThreshold }
        set { alerts.costAlertThreshold = newValue }
    }

    var dailyDigestEnabled: Bool {
        get { alerts.dailyDigestEnabled }
        set { alerts.dailyDigestEnabled = newValue }
    }

    var dailyDigestHour: Int {
        get { alerts.dailyDigestHour }
        set { alerts.dailyDigestHour = newValue }
    }

    // MARK: Controller
    var controllerRuntimeEnabled: Bool {
        get { controller.controllerRuntimeEnabled }
        set { controller.controllerRuntimeEnabled = newValue }
    }

    var controllerRuntimeRefreshMinutes: Int {
        get { controller.controllerRuntimeRefreshMinutes }
        set { controller.controllerRuntimeRefreshMinutes = newValue }
    }

    var controllerLocalNotificationsEnabled: Bool {
        get { controller.controllerLocalNotificationsEnabled }
        set { controller.controllerLocalNotificationsEnabled = newValue }
    }

    var controllerTelegramEnabled: Bool {
        get { controller.controllerTelegramEnabled }
        set { controller.controllerTelegramEnabled = newValue }
    }

    var controllerTelegramBotToken: String {
        get { controller.controllerTelegramBotToken }
        set { controller.controllerTelegramBotToken = newValue }
    }

    var controllerTelegramChatID: String {
        get { controller.controllerTelegramChatID }
        set { controller.controllerTelegramChatID = newValue }
    }

    var controllerCalendarIntegrationEnabled: Bool {
        get { controller.controllerCalendarIntegrationEnabled }
        set { controller.controllerCalendarIntegrationEnabled = newValue }
    }

    var controllerCalendarDefaultMinutes: Int {
        get { controller.controllerCalendarDefaultMinutes }
        set { controller.controllerCalendarDefaultMinutes = newValue }
    }

    var controllerDefaultSnoozeMinutes: Int {
        get { controller.controllerDefaultSnoozeMinutes }
        set { controller.controllerDefaultSnoozeMinutes = newValue }
    }

    var controllerSimulatorToolsEnabled: Bool {
        get { controller.controllerSimulatorToolsEnabled }
        set { controller.controllerSimulatorToolsEnabled = newValue }
    }

    // MARK: Gateway
    var gatewayEnabled: Bool {
        get { gateway.gatewayEnabled }
        set { gateway.gatewayEnabled = newValue }
    }

    var gatewayHost: String {
        get { gateway.gatewayHost }
        set { gateway.gatewayHost = newValue }
    }

    var gatewayPort: Int {
        get { gateway.gatewayPort }
        set { gateway.gatewayPort = newValue }
    }

    var gatewayAuthToken: String {
        get { gateway.gatewayAuthToken }
        set { gateway.gatewayAuthToken = newValue }
    }

    var gatewayConfigurationDict: [String: Any] {
        [
            "enabled": gatewayEnabled,
            "host": gatewayHost.isEmpty ? "127.0.0.1" : gatewayHost,
            "port": gatewayPort > 0 ? gatewayPort : 8317
        ]
    }

    // MARK: Indexing
    var conversationIndexingEnabled: Bool {
        get { index.conversationIndexingEnabled }
        set { index.conversationIndexingEnabled = newValue }
    }

    var restrictedLogAccess: Bool {
        get { index.restrictedLogAccess }
        set { index.restrictedLogAccess = newValue }
    }

    var databaseEncryptionEnabled: Bool {
        get { index.databaseEncryptionEnabled }
        set { index.databaseEncryptionEnabled = newValue }
    }

    var preferredIndexEmbeddingVersionID: String {
        get { index.preferredIndexEmbeddingVersionID }
        set { index.preferredIndexEmbeddingVersionID = newValue }
    }

    var preferredIndexEmbeddingVersionIDValue: String? {
        let trimmed = preferredIndexEmbeddingVersionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var indexEmbeddingProvider: IndexEmbeddingProviderID {
        get { index.indexEmbeddingProvider }
        set { index.indexEmbeddingProvider = newValue }
    }

    var indexOpenAIModel: String {
        get { index.indexOpenAIModel }
        set { index.indexOpenAIModel = newValue }
    }

    var conversationIndexingConsentShown: Bool {
        get { index.conversationIndexingConsentShown }
        set { index.conversationIndexingConsentShown = newValue }
    }

    // MARK: Cloud Sync
    var conversationCloudBackupEnabled: Bool {
        get { cloudSync.conversationCloudBackupEnabled }
        set { cloudSync.conversationCloudBackupEnabled = newValue }
    }

    var iCloudSessionMirrorEnabled: Bool {
        get { cloudSync.iCloudSessionMirrorEnabled }
        set { cloudSync.iCloudSessionMirrorEnabled = newValue }
    }

    var sessionLogCloudBackupEnabled: Bool {
        get { cloudSync.sessionLogCloudBackupEnabled }
        set { cloudSync.sessionLogCloudBackupEnabled = newValue }
    }

    var sessionLogCloudBackupConsentShown: Bool {
        get { cloudSync.sessionLogCloudBackupConsentShown }
        set { cloudSync.sessionLogCloudBackupConsentShown = newValue }
    }

    var chatThreadContentCloudBackupEnabled: Bool {
        get { cloudSync.chatThreadContentCloudBackupEnabled }
        set { cloudSync.chatThreadContentCloudBackupEnabled = newValue }
    }

    var chatThreadContentCloudBackupConsentShown: Bool {
        get { cloudSync.chatThreadContentCloudBackupConsentShown }
        set { cloudSync.chatThreadContentCloudBackupConsentShown = newValue }
    }

    // MARK: Artifact Discovery
    var artifactDiscoveryEnabled: Bool {
        get { artifactDiscovery.artifactDiscoveryEnabled }
        set { artifactDiscovery.artifactDiscoveryEnabled = newValue }
    }

    var artifactDiscoveryRegisteredRootsJSON: String {
        get { artifactDiscovery.artifactDiscoveryRegisteredRootsJSON }
        set { artifactDiscovery.artifactDiscoveryRegisteredRootsJSON = newValue }
    }

    var artifactDiscoveryAdditionalKnownPatternsJSON: String {
        get { artifactDiscovery.artifactDiscoveryAdditionalKnownPatternsJSON }
        set { artifactDiscovery.artifactDiscoveryAdditionalKnownPatternsJSON = newValue }
    }

    var artifactDiscoveryRegisteredRoots: [String] {
        get { artifactDiscovery.artifactDiscoveryRegisteredRoots }
        set { artifactDiscovery.artifactDiscoveryRegisteredRoots = newValue }
    }

    var artifactDiscoveryAdditionalKnownPatterns: [String] {
        get { artifactDiscovery.artifactDiscoveryAdditionalKnownPatterns }
        set { artifactDiscovery.artifactDiscoveryAdditionalKnownPatterns = newValue }
    }

    // MARK: CLI Assistant
    var cliAssistantAllowed: Bool {
        get { cliAssistant.cliAssistantAllowed }
        set {
            cliAssistant.cliAssistantAllowed = newValue
            if newValue { cliAssistant.cliAssistantConsentShown = true }
        }
    }

    var cliAssistantConsentShown: Bool {
        get { cliAssistant.cliAssistantConsentShown }
        set { cliAssistant.cliAssistantConsentShown = newValue }
    }

    // MARK: Chat Backend
    var openClawGatewayBaseURL: String {
        get { chatBackend.openClawGatewayBaseURL }
        set { chatBackend.openClawGatewayBaseURL = newValue }
    }

    var openClawBearerToken: String {
        get { chatBackend.openClawBearerToken }
        set { chatBackend.openClawBearerToken = newValue }
    }

    var hermesBearerToken: String {
        get { chatBackend.hermesBearerToken }
        set { chatBackend.hermesBearerToken = newValue }
    }

    var hermesChatModelOverride: String {
        get { chatBackend.hermesChatModelOverride }
        set { chatBackend.hermesChatModelOverride = newValue }
    }

    var hermesGatewayBaseURL: String {
        get { chatBackend.hermesGatewayBaseURL }
        set { chatBackend.hermesGatewayBaseURL = newValue }
    }

    var hermesRemoteRelayEnabled: Bool {
        get { chatBackend.hermesRemoteRelayEnabled }
        set { chatBackend.hermesRemoteRelayEnabled = newValue }
    }

    var hermesRealtimeRelayURL: String {
        get { chatBackend.hermesRealtimeRelayURL }
        set { chatBackend.hermesRealtimeRelayURL = newValue }
    }

    var hermesIrohTransportEnabled: Bool {
        get { chatBackend.hermesIrohTransportEnabled }
        set { chatBackend.hermesIrohTransportEnabled = newValue }
    }

    /// Mercury Phase 1 — see `ChatBackendSettings.mediaBlobTransferEnabled`.
    var mediaBlobTransferEnabled: Bool {
        get { chatBackend.mediaBlobTransferEnabled }
        set { chatBackend.mediaBlobTransferEnabled = newValue }
    }

    var computerUseWatchEnabled: Bool {
        get { chatBackend.computerUseWatchEnabled }
        set { chatBackend.computerUseWatchEnabled = newValue }
    }

    var computerUseBrowserEnabled: Bool {
        get { chatBackend.computerUseBrowserEnabled }
        set { chatBackend.computerUseBrowserEnabled = newValue }
    }

    var computerUseSystemEnabled: Bool {
        get { chatBackend.computerUseSystemEnabled }
        set { chatBackend.computerUseSystemEnabled = newValue }
    }

    var computerUsePhoneControlEnabled: Bool {
        get { chatBackend.computerUsePhoneControlEnabled }
        set { chatBackend.computerUsePhoneControlEnabled = newValue }
    }

    var computerUseTrustedScopesEnabled: Bool {
        get { chatBackend.computerUseTrustedScopesEnabled }
        set { chatBackend.computerUseTrustedScopesEnabled = newValue }
    }

    var computerUseAuditExportEnabled: Bool {
        get { chatBackend.computerUseAuditExportEnabled }
        set { chatBackend.computerUseAuditExportEnabled = newValue }
    }

    var computerUseKillSwitch: Bool {
        get { chatBackend.computerUseKillSwitch }
        set { chatBackend.computerUseKillSwitch = newValue }
    }

    var launchHermesWithOpenBurnBar: Bool {
        get { chatBackend.launchHermesWithOpenBurnBar }
        set { chatBackend.launchHermesWithOpenBurnBar = newValue }
    }

    // MARK: Pi Agent Connection Profile

    var piAgentGatewayBaseURL: String {
        get { chatBackend.piAgentGatewayBaseURL }
        set { chatBackend.piAgentGatewayBaseURL = newValue }
    }

    var piAgentBearerToken: String {
        get { chatBackend.piAgentBearerToken }
        set { chatBackend.piAgentBearerToken = newValue }
    }

    var piAgentRedisURL: String {
        get { chatBackend.piAgentRedisURL }
        set { chatBackend.piAgentRedisURL = newValue }
    }

    var piAgentSelectedInstanceID: String {
        get { chatBackend.piAgentSelectedInstanceID }
        set { chatBackend.piAgentSelectedInstanceID = newValue }
    }

    var piAgentChatModelOverride: String {
        get { chatBackend.piAgentChatModelOverride }
        set { chatBackend.piAgentChatModelOverride = newValue }
    }

    var launchPiAgentsWithOpenBurnBar: Bool {
        get { chatBackend.launchPiAgentsWithOpenBurnBar }
        set { chatBackend.launchPiAgentsWithOpenBurnBar = newValue }
    }

    var piRemoteRelayEnabled: Bool {
        get { chatBackend.piRemoteRelayEnabled }
        set { chatBackend.piRemoteRelayEnabled = newValue }
    }

    var piRealtimeRelayURL: String {
        get { chatBackend.piRealtimeRelayURL }
        set { chatBackend.piRealtimeRelayURL = newValue }
    }

    var chatBackendOnboardingCompleted: Bool {
        get { chatBackend.chatBackendOnboardingCompleted }
        set { chatBackend.chatBackendOnboardingCompleted = newValue }
    }

    var hermesSetupWizardCompleted: Bool {
        get { chatBackend.hermesSetupWizardCompleted }
        set { chatBackend.hermesSetupWizardCompleted = newValue }
    }

    var switcherOnboardingCompleted: Bool {
        get { chatBackend.switcherOnboardingCompleted }
        set { chatBackend.switcherOnboardingCompleted = newValue }
    }

    var selectedOnboardingProvidersCSV: String {
        get { chatBackend.selectedOnboardingProvidersCSV }
        set { chatBackend.selectedOnboardingProvidersCSV = newValue }
    }

    var selectedOnboardingProviders: Set<AgentProvider> {
        get { chatBackend.selectedOnboardingProviders }
        set { chatBackend.selectedOnboardingProviders = newValue }
    }

    var enabledChatBackendIDsCSV: String {
        get { chatBackend.enabledChatBackendIDsCSV }
        set { chatBackend.enabledChatBackendIDsCSV = newValue }
    }

    var enabledChatBackends: [ChatBackendID] {
        chatBackend.enabledChatBackends
    }

    func setEnabledChatBackends(_ backends: [ChatBackendID]) {
        chatBackend.setEnabledChatBackends(backends)
    }

    func setChatBackendEnabled(_ id: ChatBackendID, enabled: Bool) {
        chatBackend.setChatBackendEnabled(id, enabled: enabled)
    }

    // MARK: Hermes model picker

    var enabledHermesModelIDsCSV: String {
        get { chatBackend.enabledHermesModelIDsCSV }
        set { chatBackend.enabledHermesModelIDsCSV = newValue }
    }

    var enabledHermesModels: [HermesModelID] {
        chatBackend.enabledHermesModels
    }

    var selectedHermesModel: HermesModelID? {
        get { chatBackend.selectedHermesModel }
        set { chatBackend.applyHermesModelSelection(newValue) }
    }

    func setEnabledHermesModels(_ models: [HermesModelID]) {
        chatBackend.setEnabledHermesModels(models)
    }

    func setHermesModelEnabled(_ id: HermesModelID, enabled: Bool) {
        chatBackend.setHermesModelEnabled(id, enabled: enabled)
    }

    func applyHermesModelSelection(_ model: HermesModelID?) {
        chatBackend.applyHermesModelSelection(model)
    }

    // MARK: Summary
    var autoSessionSummariesEnabled: Bool {
        get { summary.autoSessionSummariesEnabled }
        set { summary.autoSessionSummariesEnabled = newValue }
    }

    var summaryProviderOrderCSV: String {
        get { summary.summaryProviderOrderCSV }
        set { summary.summaryProviderOrderCSV = newValue }
    }

    var summaryProviderOrder: [SummaryProviderID] {
        summary.summaryProviderOrder
    }

    func setSummaryProviderOrder(_ order: [SummaryProviderID]) {
        summary.setSummaryProviderOrder(order)
    }

    var summaryDailyCapUSD: Double? {
        get { summary.summaryDailyCapUSD }
        set { summary.summaryDailyCapUSD = newValue }
    }

    var summaryOpenRouterPrimaryModel: String {
        get { summary.summaryOpenRouterPrimaryModel }
        set { summary.summaryOpenRouterPrimaryModel = newValue }
    }

    var summaryOpenRouterFallbackModel: String {
        get { summary.summaryOpenRouterFallbackModel }
        set { summary.summaryOpenRouterFallbackModel = newValue }
    }

    var summaryMiniMaxModel: String {
        get { summary.summaryMiniMaxModel }
        set { summary.summaryMiniMaxModel = newValue }
    }

    var summaryZaiModel: String {
        get { summary.summaryZaiModel }
        set { summary.summaryZaiModel = newValue }
    }

    var summaryOllamaModel: String {
        get { summary.summaryOllamaModel }
        set { summary.summaryOllamaModel = newValue }
    }

    var summaryOllamaBaseURL: String {
        get { summary.summaryOllamaBaseURL }
        set { summary.summaryOllamaBaseURL = newValue }
    }

    var summaryLocalModel: String {
        get { summary.summaryLocalModel }
        set { summary.summaryLocalModel = newValue }
    }

    var summaryLocalBaseURL: String {
        get { summary.summaryLocalBaseURL }
        set { summary.summaryLocalBaseURL = newValue }
    }

    var summaryMLXModel: String {
        get { summary.summaryMLXModel }
        set { summary.summaryMLXModel = newValue }
    }

    var summaryMLXBaseURL: String {
        get { summary.summaryMLXBaseURL }
        set { summary.summaryMLXBaseURL = newValue }
    }

    var summaryMaxPromptChars: Int {
        get { summary.summaryMaxPromptChars }
        set { summary.summaryMaxPromptChars = newValue }
    }

    var summaryMaxOutputTokens: Int {
        get { summary.summaryMaxOutputTokens }
        set { summary.summaryMaxOutputTokens = newValue }
    }

    var summaryRetryCount: Int {
        get { summary.summaryRetryCount }
        set { summary.summaryRetryCount = newValue }
    }

    var summaryBatchSize: Int {
        get { summary.summaryBatchSize }
        set { summary.summaryBatchSize = newValue }
    }

    var summaryFirstLoadBatchSize: Int {
        get { summary.summaryFirstLoadBatchSize }
        set { summary.summaryFirstLoadBatchSize = newValue }
    }

    var summaryInitialSweepCompleted: Bool {
        get { summary.summaryInitialSweepCompleted }
        set { summary.summaryInitialSweepCompleted = newValue }
    }

    var summaryRequestTimeoutSeconds: Double {
        get { summary.summaryRequestTimeoutSeconds }
        set { summary.summaryRequestTimeoutSeconds = newValue }
    }

    var summaryMaxConcurrency: Int {
        get { summary.summaryMaxConcurrency }
        set { summary.summaryMaxConcurrency = newValue }
    }

    var summaryTimeLimitMinutes: Int {
        get { summary.summaryTimeLimitMinutes }
        set { summary.summaryTimeLimitMinutes = newValue }
    }

    // MARK: Cross Encoder
    var crossEncoderRerankEnabled: Bool {
        get { crossEncoder.crossEncoderRerankEnabled }
        set { crossEncoder.crossEncoderRerankEnabled = newValue }
    }

    var crossEncoderProvider: CrossEncoderProviderID {
        get { crossEncoder.crossEncoderProvider }
        set { crossEncoder.crossEncoderProvider = newValue }
    }

    var crossEncoderModel: String {
        get { crossEncoder.crossEncoderModel }
        set { crossEncoder.crossEncoderModel = newValue }
    }

    var crossEncoderBaseURL: String {
        get { crossEncoder.crossEncoderBaseURL }
        set { crossEncoder.crossEncoderBaseURL = newValue }
    }

    var crossEncoderMaxCandidates: Int {
        get { crossEncoder.crossEncoderMaxCandidates }
        set { crossEncoder.crossEncoderMaxCandidates = newValue }
    }

    var crossEncoderMaxCharsPerCandidate: Int {
        get { crossEncoder.crossEncoderMaxCharsPerCandidate }
        set { crossEncoder.crossEncoderMaxCharsPerCandidate = newValue }
    }

    // MARK: Quotas
    var miniMaxQuotaMode: MiniMaxQuotaMode {
        get { quotas.miniMaxQuotaMode }
        set { quotas.miniMaxQuotaMode = newValue }
    }

    var factoryQuotaPlanTier: FactoryQuotaPlanTier {
        get { quotas.factoryQuotaPlanTier }
        set { quotas.factoryQuotaPlanTier = newValue }
    }

    var tokenizerAssistedFallbackEnabled: Bool {
        get { quotas.tokenizerAssistedFallbackEnabled }
        set { quotas.tokenizerAssistedFallbackEnabled = newValue }
    }

    var smartHubQuotaDisplayEnabled: Bool {
        get { quotas.smartHubQuotaDisplayEnabled }
        set { quotas.smartHubQuotaDisplayEnabled = newValue }
    }

    var smartHubQuotaDashboardURL: String {
        get { quotas.smartHubQuotaDashboardURL }
        set { quotas.smartHubQuotaDashboardURL = newValue }
    }

    var smartHubQuotaRefreshURL: String {
        get { quotas.smartHubQuotaRefreshURL }
        set { quotas.smartHubQuotaRefreshURL = newValue }
    }

    var smartHubQuotaTimePeriod: SmartHubTimePeriod {
        get { quotas.smartHubQuotaTimePeriod }
        set { quotas.smartHubQuotaTimePeriod = newValue }
    }

    var smartHubQuotaVoiceRefreshURL: String {
        get { quotas.smartHubQuotaVoiceRefreshURL }
        set { quotas.smartHubQuotaVoiceRefreshURL = newValue }
    }

    var smartHubHomeAssistantRecoveryWebhookURL: String {
        get { quotas.smartHubHomeAssistantRecoveryWebhookURL }
        set { quotas.smartHubHomeAssistantRecoveryWebhookURL = newValue }
    }

    var pixelClockConfig: PixelClockConfig {
        get { quotas.pixelClockConfig }
        set { quotas.pixelClockConfig = newValue }
    }

    var smartHubDisplayConfig: SmartHubDisplayConfig {
        get { quotas.smartHubDisplayConfig }
        set { quotas.smartHubDisplayConfig = newValue }
    }

    var smartDisplayOrder: SmartDisplayOrder {
        get { quotas.smartDisplayOrder }
        set { quotas.smartDisplayOrder = newValue }
    }

    var castSelectedDeviceServiceName: String {
        get { quotas.castSelectedDeviceServiceName }
        set { quotas.castSelectedDeviceServiceName = newValue }
    }

    var castSelectedDeviceFriendlyName: String {
        get { quotas.castSelectedDeviceFriendlyName }
        set { quotas.castSelectedDeviceFriendlyName = newValue }
    }

    var castSelectedDeviceModel: String {
        get { quotas.castSelectedDeviceModel }
        set { quotas.castSelectedDeviceModel = newValue }
    }

    var castSelectedDeviceHost: String {
        get { quotas.castSelectedDeviceHost }
        set { quotas.castSelectedDeviceHost = newValue }
    }

    var castSelectedDevicePort: Int {
        get { quotas.castSelectedDevicePort }
        set { quotas.castSelectedDevicePort = newValue }
    }

    var castSelectedDeviceIdentifier: String {
        get { quotas.castSelectedDeviceIdentifier }
        set { quotas.castSelectedDeviceIdentifier = newValue }
    }

    var castSelectedDeviceSupportsDisplay: Bool {
        get { quotas.castSelectedDeviceSupportsDisplay }
        set { quotas.castSelectedDeviceSupportsDisplay = newValue }
    }

    // MARK: Provider Paths
    var logPaths: [AgentProvider: String] {
        get { providerPath.logPaths }
        set { providerPath.logPaths = newValue }
    }

    func resetPathsToDefaults() {
        providerPath.resetPathsToDefaults()
    }

    func detectAvailableProviders() -> [AgentProvider: Bool] {
        providerPath.detectAvailableProviders()
    }

    func pathExists(for provider: AgentProvider) -> Bool {
        providerPath.pathExists(for: provider, restrictedLogAccess: index.restrictedLogAccess)
    }

    func restrictedLogDirectory(for provider: AgentProvider) -> String {
        providerPath.restrictedLogDirectory(for: provider, restrictedLogAccess: index.restrictedLogAccess)
    }

    func resolvedPath(for provider: AgentProvider) -> URL? {
        providerPath.resolvedPath(for: provider, restrictedLogAccess: index.restrictedLogAccess)
    }

    // MARK: First Launch
    var isFirstLaunch: Bool {
        !persistence.bool(forKey: "hasLaunchedBefore")
    }

    // MARK: Usage Formatting
    func formatUsageMetric(cost: Double, tokens: Int) -> String {
        switch usageDisplayMode {
        case .currency: return cost.formatAsCost()
        case .tokens: return tokens.formatAsTokenVolume()
        }
    }

    // MARK: Hermes Model Resolution
    static func resolvedHermesChatModel(override: String, gatewayAdvertisedModel: String?) -> String {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let advertised = gatewayAdvertisedModel?.trimmingCharacters(in: .whitespacesAndNewlines), !advertised.isEmpty else {
            return "hermes"
        }
        return advertised
    }

    func resolvedHermesChatModel(gatewayAdvertisedModel: String?) -> String {
        Self.resolvedHermesChatModel(override: hermesChatModelOverride, gatewayAdvertisedModel: gatewayAdvertisedModel)
    }

    // MARK: Pi Agent Model Resolution
    static func resolvedPiChatModel(override: String, gatewayAdvertisedModel: String?) -> String {
        ChatBackendSettings.resolvedPiChatModel(override: override, gatewayAdvertisedModel: gatewayAdvertisedModel)
    }

    func resolvedPiChatModel(gatewayAdvertisedModel: String?) -> String {
        chatBackend.resolvedPiChatModel(gatewayAdvertisedModel: gatewayAdvertisedModel)
    }

    // MARK: JSON Helpers
    static func decodeJSONStringArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func encodeJSONStringArray(_ values: [String]) -> String {
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(normalized),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    // MARK: - Explicit Save

    /// Forces an immediate flush of all dirty settings.
    /// Most mutations are coalesced automatically; this is only needed
    /// before critical transitions (e.g., app termination).
    func save() {
        persistence.flush()
    }
}

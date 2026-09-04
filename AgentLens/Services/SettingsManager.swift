import AppKit
import Foundation
import FirebaseCore
import FirebaseRemoteConfig
import Observation
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
        service: OpenBurnBarCore.OpenBurnBarIdentity.controllerRuntimeKeychainService,
        legacyServices: OpenBurnBarCore.OpenBurnBarIdentity.legacyControllerRuntimeKeychainServices
    )

    private static let chatGatewaySecrets = KeychainStore(
        service: OpenBurnBarCore.OpenBurnBarIdentity.chatGatewayKeychainService,
        legacyServices: OpenBurnBarCore.OpenBurnBarIdentity.legacyChatGatewayKeychainServices
    )

    // MARK: - Domain Stores

    let persistence: SettingsPersistenceCoordinator
    let appearance: AppearanceSettings

    /// Bumped by `appearanceSubStoreDidChange()` whenever an
    /// `AppearanceSettings` property changes. Referenced by the
    /// computed property bridges below so SwiftUI observation
    /// tracking always re-evaluates when appearance shifts.
    private var appearanceMutationVersion: Int = 0
    var appearanceMutationVersionForPresentation: Int { appearanceMutationVersion }
    let behavior: BehaviorSettings
    let alerts: AlertSettings
    let controller: ControllerSettings
    let gateway: GatewaySettings
    let chatBackend: ChatBackendSettings
    let index: IndexSettings
    let crossEncoder: CrossEncoderSettings
    let cloudSync: CloudSyncSettings
    let cliAssistant: CLIAssistantSettings
    let memory: MemorySettings
    let summary: SummarySettings
    let quotas: QuotaSettings
    let providerPath: ProviderPathSettings
    let artifactDiscovery: ArtifactDiscoverySettings
    let routedClientWiring: RoutedClientWiringSettings
    let textExpansion: TextExpansionSettings
    let elderWand: ElderWandSettings
    let visualCapture: VisualCapturePreferences
    let activation: ActivationSettings
    private var computerUseRemoteConfigTask: Task<Void, Never>?
    private(set) var hasResolvedComputerUseRemoteConfig = false

    // MARK: - Init

    /// - Parameter usageMemoryRemoteConfigSeed: the active **cached** usage-memory
    ///   fleet switches, read synchronously at init so a cached kill is honored
    ///   before either usage lane can open. Defaults to Firebase's activated
    ///   config; returns `nil` when Firebase is not configured yet, which leaves
    ///   both usage lanes CLOSED until the first Remote Config refresh resolves
    ///   them. Injectable so tests can pin the cached-kill-at-init behavior.
    init(
        defaults: UserDefaults = .standard,
        controllerRuntimeSecrets: KeychainStore = SettingsManager.controllerRuntimeSecrets,
        chatGatewaySecrets: KeychainStore = SettingsManager.chatGatewaySecrets,
        launchAgentGatewayAuthTokenReader: @escaping () -> String? = { GatewaySettings.readLaunchAgentAuthToken() },
        flushDelayNanoseconds: UInt64 = 100_000_000,
        usageMemoryRemoteConfigSeed: () -> UsageMemoryRemoteConfigSnapshot? = {
            SettingsManager.activeUsageMemoryRemoteConfigSnapshot()
        }
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
            secretPersistence: chatGatewaySecretPersistence,
            launchAgentAuthTokenReader: launchAgentGatewayAuthTokenReader
        )
        self.chatBackend = ChatBackendSettings(
            persistence: coordinator,
            secretPersistence: chatGatewaySecretPersistence
        )
        self.index = IndexSettings(persistence: coordinator)
        self.crossEncoder = CrossEncoderSettings(persistence: coordinator)
        self.cloudSync = CloudSyncSettings(persistence: coordinator)
        self.cliAssistant = CLIAssistantSettings(persistence: coordinator)
        self.memory = MemorySettings(
            persistence: coordinator,
            usageRemoteConfigSeed: usageMemoryRemoteConfigSeed
        )
        if let cachedCloudModels = Self.cachedMemoryCloudModelsRemoteConfigEnabled(), !cachedCloudModels {
            memory.remoteConfigCloudModelsEnabled = false
        }
        self.summary = SummarySettings(persistence: coordinator)
        self.quotas = QuotaSettings(persistence: coordinator)
        self.providerPath = ProviderPathSettings(persistence: coordinator)
        self.artifactDiscovery = ArtifactDiscoverySettings(persistence: coordinator)
        self.routedClientWiring = RoutedClientWiringSettings(persistence: coordinator)
        self.textExpansion = TextExpansionSettings(persistence: coordinator)
        self.elderWand = ElderWandSettings(persistence: coordinator)
        self.visualCapture = VisualCapturePreferences(persistence: coordinator)
        self.activation = ActivationSettings(persistence: coordinator)

        // Register periodic flush on app background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(flushPendingWrites),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        // Forward appearance sub-store mutations so views observing
        // SettingsManager computed properties (e.g. useWebsiteBackground)
        // re-render when the underlying AppearanceSettings value changes.
        // @Observable only auto-tracks stored properties; computed bridges
        // need this forwarding to guarantee SwiftUI refreshes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .appearanceModeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .appearanceSkinDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .dashboardLayoutDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .useWebsiteBackgroundDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .useConstellationBackgroundDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .enableDesktopWallpaperDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .desktopWallpaperBackgroundDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .desktopWallpaperSpeedDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .desktopWallpaperProviderGlyphsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .enableSwarmSparklesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSubStoreDidChange),
            name: .excludeBrandShapesFromSwarmDidChange,
            object: nil
        )
        startComputerUseRemoteConfigPolling()
    }

    /// Triggered when any `AppearanceSettings` property that surfaces
    /// through a computed bridge on `SettingsManager` changes values.
    /// Bumps an internal version counter (a stored @Observable property)
    /// so that any SwiftUI view observing a computed property like
    /// `useWebsiteBackground` is guaranteed to re-render.
    @objc private func appearanceSubStoreDidChange() {
        appearanceMutationVersion &+= 1
    }

    @objc private func flushPendingWrites() {
        persistence.flush()
    }

    private func startComputerUseRemoteConfigPolling() {
        computerUseRemoteConfigTask?.cancel()
        // Coordinator-managed cadence: 60 s while foreground / display
        // awake, 5 min while backgrounded, paused while the display
        // sleeps. Remote Config is a slow-moving truth source (kill
        // switches + feature flags) so we never want to be hitting
        // Firebase on a sleeping laptop.
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.cadenceIDRemoteConfig,
                activeInterval: 60,
                backgroundInterval: 300,
                sleepInterval: nil,
                isEnabled: { FirebaseApp.app() != nil },
                fireImmediately: true,
                cancellableInFlight: false,
                work: { [weak self] in
                    await self?.refreshComputerUseRemoteConfigOnce()
                }
            )
        )
        // Sentinel so re-entrant calls are no-ops; the actual loop runs
        // inside the cadence coordinator.
        computerUseRemoteConfigTask = Task { @MainActor in }
    }

    private static let cadenceIDRemoteConfig = "settings-remote-config"

    private static let commercialRemoteConfigDefaults: [String: NSObject] = [
        "computer_use_watch_enabled": NSNumber(value: false),
        "computer_use_browser_enabled": NSNumber(value: false),
        "computer_use_system_enabled": NSNumber(value: false),
        "computer_use_phone_control_enabled": NSNumber(value: false),
        "computer_use_phone_control_attestation_required": NSNumber(value: false),
        "computer_use_trust_modes_enabled": NSNumber(value: false),
        "computer_use_polish_enabled": NSNumber(value: false),
        "computer_use_kill_switch": NSNumber(value: true),
        // Secure default: a verified phone NEVER silently bypasses an
        // accessibility deny region (password field / system auth sheet /
        // login window). The gate also enforces this structurally — a deny
        // region beats this flag regardless — but the Remote Config default
        // must itself be the secure value so a fresh/offline install (where
        // the server has not published the key) is not fail-open.
        "computer_use_phone_control_respects_deny_regions": NSNumber(value: true),
        // Future SKU model evolution — individual feature gating.
        // Uncomment and wire into refreshEntitlement() when the SKU model
        // supports per-feature Remote Config overrides:
        // "computer_use_browser_allowed": NSNumber(value: true),
        // "computer_use_system_allowed": NSNumber(value: true),
        // "computer_use_phone_control_allowed": NSNumber(value: true),
        // "computer_use_trusted_scopes_allowed": NSNumber(value: true),
        // "computer_use_audit_export_allowed": NSNumber(value: true),
        "media_kill_switch": NSNumber(value: true),
        // War Room (the Wire + the Flame). Secure default: engaged, so an
        // install that cannot reach Remote Config keeps the shipped
        // single-machine experience instead of opening the Mac⇄Mac lane.
        "war_room_kill_switch": NSNumber(value: true),
        // Memory extraction fleet kill switch. Default true (extraction allowed);
        // Remote Config sets false to halt extraction instantly. Fetch transport
        // errors keep any active cached false authoritative while avoiding
        // stranding opted-in local extraction when no kill is cached.
        "memory_extraction_enabled": NSNumber(value: true),
        // Memory Pro cloud-models fleet kill switch. Default true (allowed);
        // Remote Config sets false to close the gate and hand the daemon a
        // disabled policy. Same transport posture as memory_extraction_enabled.
        "memory_cloud_models_enabled": NSNumber(value: true),
        // Usage-memory fleet kill switches. Same posture as memory_extraction_enabled:
        // default true (allowed); Remote Config sets false to halt usage-memory
        // extraction / durable authority writes instantly. Fetch transport errors
        // keep any active cached false authoritative.
        "memory_usage_extraction_enabled": NSNumber(value: true),
        "memory_usage_authority_writes_enabled": NSNumber(value: true),
        "media_budget_soft_usd": NSNumber(value: 600),
        "media_budget_hard_usd": NSNumber(value: 1_000),
        "media_normal_file_gb_per_day": NSNumber(value: 5),
        "media_soft_file_gb_per_day": NSNumber(value: 2),
        "media_normal_screen_share_min_per_day": NSNumber(value: 120),
        "media_soft_screen_share_min_per_day": NSNumber(value: 30),
        "computer_use_budget_soft_usd": NSNumber(value: 1_500),
        "computer_use_budget_hard_usd": NSNumber(value: 2_500),
        "computer_use_actions_per_run_normal": NSNumber(value: 50),
        "computer_use_actions_per_day_normal": NSNumber(value: 200),
        "computer_use_usd_per_user_day_normal": NSNumber(value: 5),
        "computer_use_actions_per_run_soft": NSNumber(value: 25),
        "computer_use_actions_per_day_soft": NSNumber(value: 100),
        "hosted_quota_daily_refresh_limit": NSNumber(value: 30),
        "hosted_quota_monthly_refresh_limit": NSNumber(value: 300),
        "cloud_pro_included_hosted_actions_monthly": NSNumber(value: 500),
        "cloud_pro_action_topup_unit": NSNumber(value: 100),
        "cloud_pro_monthly_hosted_action_cap": NSNumber(value: 2_000),
        "cloud_pro_included_relay_gb_monthly": NSNumber(value: 50),
        "cloud_pro_relay_topup_unit_gb": NSNumber(value: 50),
        "cloud_pro_monthly_relay_gb_cap": NSNumber(value: 300)
    ]

    /// The usage-memory fleet switches from the **active** Remote Config — the
    /// values already activated on disk, read synchronously with no network call.
    /// `nil` when Firebase is not configured (no fleet channel exists yet), which
    /// keeps both usage lanes closed rather than guessing.
    ///
    /// This is the seed that makes a cached fleet kill authoritative at init: the
    /// asynchronous `fetchAndActivate` below cannot land before a returning,
    /// already-consenting user's gates are first propagated.
    static func activeUsageMemoryRemoteConfigSnapshot() -> UsageMemoryRemoteConfigSnapshot? {
        guard FirebaseApp.app() != nil else { return nil }
        let remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.setDefaults(Self.commercialRemoteConfigDefaults)
        return UsageMemoryRemoteConfigSnapshot(
            extractionEnabled: remoteConfig.configValue(forKey: "memory_usage_extraction_enabled").boolValue,
            authorityWritesEnabled: remoteConfig.configValue(
                forKey: "memory_usage_authority_writes_enabled"
            ).boolValue
        )
    }

    /// The ACTIVE CACHED `memory_cloud_models_enabled` value, read synchronously
    /// at init so a returning opted-in install never opens the cloud-models gate
    /// ahead of a fleet kill that is already on disk. Nil without Firebase.
    private static func cachedMemoryCloudModelsRemoteConfigEnabled() -> Bool? {
        guard FirebaseApp.app() != nil else { return nil }
        let remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.setDefaults(commercialRemoteConfigDefaults)
        return remoteConfig.configValue(forKey: "memory_cloud_models_enabled").boolValue
    }

    private func refreshComputerUseRemoteConfigOnce() async {
        guard FirebaseApp.app() != nil else { return }
        let remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.setDefaults(Self.commercialRemoteConfigDefaults)

        // Apply the ACTIVE CACHED usage switches BEFORE awaiting the network
        // fetch. A cached fleet kill must not be ignored for the duration of a
        // round-trip, and when Firebase was configured after this manager was
        // built (so the init seed returned nil) this is what first resolves the
        // usage lanes out of their held-closed state.
        applyUsageMemoryRemoteConfig(
            extractionEnabled: remoteConfig.configValue(forKey: "memory_usage_extraction_enabled").boolValue,
            authorityWritesEnabled: remoteConfig.configValue(
                forKey: "memory_usage_authority_writes_enabled"
            ).boolValue
        )

        // Same for the Memory Pro cloud-models switch: a cached fleet kill must
        // close the gate (and re-send the daemon a disabled policy) before the
        // round trip, not after it.
        if !remoteConfig.configValue(forKey: "memory_cloud_models_enabled").boolValue,
           memoryCloudModelsRemoteConfigEnabled {
            memoryCloudModelsRemoteConfigEnabled = false
            NotificationCenter.default.post(name: .memoryCloudModelsRemoteConfigKillSwitchDidFire, object: self)
        }

        let fetchResult = await withCheckedContinuation { continuation in
            remoteConfig.fetchAndActivate { status, error in
                continuation.resume(returning: (status, error))
            }
        }
        let activeMemoryExtractionEnabled = remoteConfig.configValue(forKey: "memory_extraction_enabled").boolValue
        let activeMemoryCloudModelsEnabled = remoteConfig.configValue(forKey: "memory_cloud_models_enabled").boolValue
        let activeUsageExtractionEnabled = remoteConfig.configValue(forKey: "memory_usage_extraction_enabled").boolValue
        let activeUsageAuthorityWritesEnabled = remoteConfig.configValue(
            forKey: "memory_usage_authority_writes_enabled"
        ).boolValue
        if fetchResult.1 != nil {
            computerUseKillSwitch = true
            hasResolvedComputerUseRemoteConfig = true
            mediaKillSwitch = true
            warRoomKillSwitch = true
            // Preserve opted-in local memory only when the active cached config is
            // not a fleet kill. A previously activated false value remains
            // authoritative even if this refresh cannot reach Firebase.
            if !activeMemoryExtractionEnabled {
                memoryExtractionRemoteConfigEnabled = false
                NotificationCenter.default.post(name: .memoryRemoteConfigKillSwitchDidFire, object: self)
            }
            if !activeMemoryCloudModelsEnabled {
                memoryCloudModelsRemoteConfigEnabled = false
                NotificationCenter.default.post(name: .memoryCloudModelsRemoteConfigKillSwitchDidFire, object: self)
            }
            // The usage switches need no transport-error branch of their own: the
            // pre-fetch apply above already made this same active config (a cached
            // fleet kill included) authoritative and resolved both lanes. Same
            // posture as chat — an unreachable Firebase never strands opted-in
            // local usage extraction, but an active cached false still wins.
            NotificationCenter.default.post(name: .computerUseRemoteConfigKillSwitchDidFire, object: self)
            return
        }

        computerUseWatchEnabled = remoteConfig.configValue(forKey: "computer_use_watch_enabled").boolValue
        computerUseBrowserEnabled = remoteConfig.configValue(forKey: "computer_use_browser_enabled").boolValue
        computerUseSystemEnabled = remoteConfig.configValue(forKey: "computer_use_system_enabled").boolValue
        computerUsePhoneControlEnabled = remoteConfig.configValue(forKey: "computer_use_phone_control_enabled").boolValue
        computerUsePhoneControlAttestationRequired = remoteConfig.configValue(
            forKey: "computer_use_phone_control_attestation_required"
        ).boolValue
        computerUseTrustedScopesEnabled = remoteConfig.configValue(forKey: "computer_use_trust_modes_enabled").boolValue
        computerUseAuditExportEnabled = remoteConfig.configValue(forKey: "computer_use_polish_enabled").boolValue

        let killSwitchEnabled = remoteConfig.configValue(forKey: "computer_use_kill_switch").boolValue
        computerUseKillSwitch = killSwitchEnabled
        hasResolvedComputerUseRemoteConfig = true
        if killSwitchEnabled {
            NotificationCenter.default.post(name: .computerUseRemoteConfigKillSwitchDidFire, object: self)
        }

        computerUsePhoneControlRespectsDenyRegions = remoteConfig.configValue(
            forKey: "computer_use_phone_control_respects_deny_regions"
        ).boolValue

        mediaKillSwitch = remoteConfig.configValue(forKey: "media_kill_switch").boolValue
        warRoomKillSwitch = remoteConfig.configValue(forKey: "war_room_kill_switch").boolValue

        let memoryRCEnabled = activeMemoryExtractionEnabled
        memoryExtractionRemoteConfigEnabled = memoryRCEnabled
        if !memoryRCEnabled {
            NotificationCenter.default.post(name: .memoryRemoteConfigKillSwitchDidFire, object: self)
        }
        memoryCloudModelsRemoteConfigEnabled = activeMemoryCloudModelsEnabled
        if !activeMemoryCloudModelsEnabled {
            NotificationCenter.default.post(name: .memoryCloudModelsRemoteConfigKillSwitchDidFire, object: self)
        }

        applyUsageMemoryRemoteConfig(
            extractionEnabled: activeUsageExtractionEnabled,
            authorityWritesEnabled: activeUsageAuthorityWritesEnabled
        )
    }

    // MARK: - Backward Compatibility (Computed Properties)

    // These computed properties bridge the old SettingsManager interface to the new
    // domain stores, allowing views and services to migrate incrementally.

    // MARK: Appearance / Behavior
    var appearanceMode: AppearanceMode {
        get { _ = appearanceMutationVersion; return appearance.appearanceMode }
        set { appearance.appearanceMode = newValue }
    }

    /// The app skin (Aurora ember vs. Editorial paper). See `AppSkin`.
    var appearanceSkin: AppSkin {
        get { _ = appearanceMutationVersion; return appearance.appearanceSkin }
        set { appearance.appearanceSkin = newValue }
    }

    var dashboardLayout: DashboardLayout {
        get { _ = appearanceMutationVersion; return appearance.dashboardLayout }
        set { appearance.dashboardLayout = newValue }
    }

    /// Which screen the dashboard window opens on. See `DashboardLaunchSurface`.
    var dashboardLaunchSurface: DashboardLaunchSurface {
        get { _ = appearanceMutationVersion; return appearance.dashboardLaunchSurface }
        set { appearance.dashboardLaunchSurface = newValue }
    }

    var showInMenuBar: Bool {
        get { _ = appearanceMutationVersion; return appearance.showInMenuBar }
        set { appearance.showInMenuBar = newValue }
    }

    var colorfulMenuBarIcon: Bool {
        get { _ = appearanceMutationVersion; return appearance.colorfulMenuBarIcon }
        set { appearance.colorfulMenuBarIcon = newValue }
    }

    var usePremiumSOTAUX: Bool {
        get { _ = appearanceMutationVersion; return appearance.usePremiumSOTAUX }
        set { appearance.usePremiumSOTAUX = newValue }
    }

    var useWebsiteBackground: Bool {
        get { _ = appearanceMutationVersion; return appearance.useWebsiteBackground }
        set { appearance.useWebsiteBackground = newValue }
    }

    var useConstellationBackground: Bool {
        get { _ = appearanceMutationVersion; return appearance.useConstellationBackground }
        set { appearance.useConstellationBackground = newValue }
    }

    var enableDesktopWallpaper: Bool {
        get { _ = appearanceMutationVersion; return appearance.enableDesktopWallpaper }
        set { appearance.enableDesktopWallpaper = newValue }
    }

    var desktopWallpaperBackground: DesktopWallpaperBackground {
        get { _ = appearanceMutationVersion; return appearance.desktopWallpaperBackground }
        set { appearance.desktopWallpaperBackground = newValue }
    }

    var amoledDarkBackground: Bool {
        get { _ = appearanceMutationVersion; return appearance.amoledDarkBackground }
        set { appearance.amoledDarkBackground = newValue }
    }

    var cycleShapesScreensaver: Bool {
        get { _ = appearanceMutationVersion; return appearance.cycleShapesScreensaver }
        set { appearance.cycleShapesScreensaver = newValue }
    }

    var enableSwarmSparkles: Bool {
        get { _ = appearanceMutationVersion; return appearance.enableSwarmSparkles }
        set { appearance.enableSwarmSparkles = newValue }
    }

    var clickDesktopToCycleSwarm: Bool {
        get { _ = appearanceMutationVersion; return appearance.clickDesktopToCycleSwarm }
        set { appearance.clickDesktopToCycleSwarm = newValue }
    }

    var desktopWallpaperSpeed: Double {
        get { _ = appearanceMutationVersion; return appearance.desktopWallpaperSpeed }
        set { appearance.desktopWallpaperSpeed = newValue }
    }

    var desktopWallpaperProviderGlyphs: [AgentProvider] {
        get { _ = appearanceMutationVersion; return appearance.desktopWallpaperProviderGlyphs }
        set { appearance.desktopWallpaperProviderGlyphs = newValue }
    }

    var excludeBrandShapesFromSwarm: Bool {
        get { _ = appearanceMutationVersion; return appearance.excludeBrandShapesFromSwarm }
        set { appearance.excludeBrandShapesFromSwarm = newValue }
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

    /// The user's saved **The Elder Wand** model-fusion presets.
    var elderWandPresets: [ElderWandPreset] { elderWand.presets }

    /// The active (default) Elder Wand preset, or `nil` when none is configured.
    var activeElderWandPreset: ElderWandPreset? { elderWand.activePreset }

    /// Lowers the active Elder Wand preset into the OpenRouter "Fusion"-compatible
    /// `plugins` block the daemon gateway reads. `nil` when no preset is configured.
    func elderWandPluginsPayload() -> [[String: any Sendable]]? {
        elderWand.elderWandPluginsPayload()
    }

    /// Opt-in escape hatch: bind the gateway on loopback without a bearer token.
    /// Off by default so the gateway is fail-closed against same-host credit theft.
    var gatewayAllowUnauthenticatedLoopback: Bool {
        get { gateway.allowUnauthenticatedLoopback }
        set { gateway.allowUnauthenticatedLoopback = newValue }
    }

    /// Auto-generates and persists a gateway bearer token (when none exists and
    /// the user has not opted into unauthenticated loopback) so the daemon launch
    /// always enforces auth. Returns the token to inject, or `nil` when the user
    /// has explicitly opted out. See `GatewaySettings.ensureAuthTokenForLaunch()`.
    @discardableResult
    func ensureGatewayAuthTokenForLaunch() -> String? {
        gateway.ensureAuthTokenForLaunch()
    }

    var gatewayConfigurationDict: [String: Any] {
        [
            "enabled": gatewayEnabled,
            "host": gatewayHost.isEmpty ? "127.0.0.1" : gatewayHost,
            "port": gatewayPort > 0 ? gatewayPort : 8317
        ]
    }

    /// Experimental: substitute an allow-listed OpenAI-compatible vendor on the
    /// user's own key when the requested model can't be served. Off by default;
    /// applied at daemon launch.
    var crossVendorDegradeEnabled: Bool {
        get { gateway.crossVendorDegradeEnabled }
        set { gateway.crossVendorDegradeEnabled = newValue }
    }

    // MARK: Indexing
    var conversationIndexingEnabled: Bool {
        get { index.conversationIndexingEnabled }
        set {
            let wasEnabled = index.conversationIndexingEnabled
            index.conversationIndexingEnabled = newValue
            if wasEnabled && !newValue {
                Task.detached(priority: .utility) {
                    OpenBurnBarCore.ParserConversationCacheScrubber().scrubKnownParserCaches()
                }
            }
        }
    }

    var restrictedLogAccess: Bool {
        get { index.restrictedLogAccess }
        set { index.restrictedLogAccess = newValue }
    }

    var databaseEncryptionEnabled: Bool {
        index.databaseEncryptionEnabled
    }

    /// Legacy banner flag from the pre-fail-closed database-encryption rollout.
    /// Current encrypted startup must throw before opening plaintext. This
    /// read-only compatibility value is always false after settings migration.
    var plaintextDatabaseAcknowledged: Bool {
        index.plaintextDatabaseAcknowledged
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

    var conversationBackupEnabled: Bool {
        get { cloudSync.sessionLogCloudBackupEnabled }
        set {
            cloudSync.sessionLogCloudBackupEnabled = newValue
            cloudSync.conversationCloudBackupEnabled = newValue
        }
    }

    var conversationFacetBackfillVersion: Int {
        get { cloudSync.conversationFacetBackfillVersion }
        set { cloudSync.conversationFacetBackfillVersion = newValue }
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

    // MARK: Memory (G4: user toggle + Remote Config fleet kill switch)

    /// User toggle: automatic extraction on terminal assistant commit (default ON).
    var memoryAutomaticExtraction: Bool {
        get { memory.automaticExtraction }
        set { memory.automaticExtraction = newValue }
    }

    /// Opt-in sub-toggle: high-recall per-reply (default OFF).
    var memoryHighRecallPerReply: Bool {
        get { memory.highRecallPerReply }
        set { memory.highRecallPerReply = newValue }
    }

    /// User consent to chat-memory extraction (gate G0, default OFF). Setting this
    /// true also marks the consent prompt as shown. Until granted, the whole
    /// memory loop is dormant (see `memoryExtractionEnabled`).
    var memoryConsentGranted: Bool {
        get { memory.consentGranted }
        set { memory.consentGranted = newValue }
    }

    /// Whether the first-run memory consent prompt has already been presented.
    var memoryConsentShown: Bool {
        get { memory.consentShown }
        set { memory.consentShown = newValue }
    }

    /// Remote Config `memory_extraction_enabled`. Not user-settable; written by
    /// successful RC refreshes. Explicit fleet kills set this false; fetch
    /// transport errors still honor an active cached false kill.
    var memoryExtractionRemoteConfigEnabled: Bool {
        get { memory.remoteConfigExtractionEnabled }
        set { memory.remoteConfigExtractionEnabled = newValue }
    }

    /// Combined extraction gate (G0 + G4): user CONSENT **and** the user toggle
    /// **and** the fleet kill switch must all allow. This is the single value the
    /// extraction chokepoint consults; with consent default OFF the whole loop is
    /// dormant out of the box.
    var memoryExtractionEnabled: Bool {
        MemoryExtractionGate.isEnabled(
            consentGranted: memory.consentGranted,
            automaticExtraction: memory.automaticExtraction,
            remoteConfigEnabled: memory.remoteConfigExtractionEnabled
        )
    }

    /// Raw user opt-in to replicate approved sealed memory facts to the cloud
    /// vault (default OFF — PR-E2). This is the persisted toggle only; the value
    /// the cloud-sync scheduler actually consults is `memoryApprovedCloudBackupEnabled`,
    /// which additionally clamps this under the fleet ceiling.
    var memoryApprovedCloudBackupOptIn: Bool {
        get { memory.approvedCloudBackupEnabled }
        set { memory.approvedCloudBackupEnabled = newValue }
    }

    /// Combined cloud-backup gate for derived memory: the explicit user opt-in
    /// AND the Remote Config fleet ceiling (`remoteConfigExtractionEnabled`).
    /// Folding the egress switch under the same fleet kill switch that halts
    /// extraction means one Remote Config flip stops both producing new memory
    /// and shipping existing memory off-device. Default OFF (the opt-in defaults
    /// false), so `MemoryCloudSyncDomain` performs zero egress out of the box.
    var memoryApprovedCloudBackupEnabled: Bool {
        memory.approvedCloudBackupEnabled && memory.remoteConfigExtractionEnabled
    }

    /// Raw user opt-in to the PULL half of memory sync — reading the member's own
    /// sealed facts back down onto this device (default OFF — Memory Blind Sync
    /// PR-2). Persisted toggle only; the scheduler consults
    /// `memoryDeviceSyncEnabled`, which folds this under the backup gate.
    var memoryDeviceSyncOptIn: Bool {
        get { memory.deviceSyncEnabled }
        set { memory.deviceSyncEnabled = newValue }
    }

    /// Combined gate for the pull half: the backup gate (user opt-in AND fleet
    /// ceiling) AND the device-sync sub-toggle. Default OFF, and turning cloud
    /// backup off stops downloads too — a member who revokes memory egress does
    /// not keep an active memory sync channel.
    var memoryDeviceSyncEnabled: Bool {
        memoryApprovedCloudBackupEnabled && memory.deviceSyncEnabled
    }

    /// Live Data Vault entitlement check for the device-sync ROW (default
    /// OFF — fail closed, not persisted). Set by the Privacy & Indexing view
    /// from `MacCloudEntitlementStore` as the member's resolved tier changes.
    /// See `MemorySettings.deviceSyncEntitlementSatisfied`.
    var memoryDeviceSyncEntitlementSatisfied: Bool {
        get { memory.deviceSyncEntitlementSatisfied }
        set { memory.deviceSyncEntitlementSatisfied = newValue }
    }

    /// Whether the device-sync row can be interacted with at all: the backup
    /// gate (opt-in AND fleet ceiling) AND the Data Vault entitlement.
    /// Deliberately excludes the sub-toggle itself — a member who has satisfied
    /// every other lever must still be free to flip the sub-toggle on or off.
    var memoryDeviceSyncRowUnlocked: Bool {
        memoryApprovedCloudBackupEnabled && memory.deviceSyncEntitlementSatisfied
    }

    /// Presentation gate for the "Sync memories to my other devices" row: the
    /// sub-toggle, the backup opt-in, the Data Vault entitlement, and the
    /// Remote Config fleet ceiling, all ANDed (`MemoryDeviceSyncGate`). Distinct
    /// from `memoryDeviceSyncEnabled` (which `MemoryCloudSyncDomain` actually
    /// consults to run the pull) because the entitlement is independently
    /// enforced server-side; this gate exists purely so the row never invites a
    /// member who cannot use the feature to flip a switch that looks live.
    var memoryDeviceSyncRowEnabled: Bool {
        MemoryDeviceSyncGate.isEnabled(
            deviceSyncOptIn: memory.deviceSyncEnabled,
            backupOptIn: memory.approvedCloudBackupEnabled,
            entitlementSatisfied: memory.deviceSyncEntitlementSatisfied,
            remoteConfigEnabled: memory.remoteConfigExtractionEnabled
        )
    }

    // MARK: Memory Pro cloud models (opt-in, blind)

    /// Raw user opt-in to cloud / big models for memory (default OFF). The
    /// value the daemon actually receives is `memoryCloudModelsEnabled`.
    var memoryCloudModelsOptIn: Bool {
        get { memory.cloudModelsEnabled }
        set { memory.cloudModelsEnabled = newValue }
    }

    var memoryCloudModelsConsentShown: Bool {
        get { memory.cloudModelsConsentShown }
        set { memory.cloudModelsConsentShown = newValue }
    }

    var memoryCloudModelsRequireNoRetention: Bool {
        get { memory.cloudModelsRequireNoRetention }
        set { memory.cloudModelsRequireNoRetention = newValue }
    }

    var memoryCloudModelsDailyCapUSD: Double {
        get { memory.cloudModelsDailyCapUSD }
        set { memory.cloudModelsDailyCapUSD = newValue }
    }

    var memoryCloudModelsConsentedProviders: [MemoryCloudProviderID] {
        get { memory.cloudModelsConsentedProviderIDs }
        set { memory.cloudModelsConsentedProviderIDs = newValue }
    }

    /// Remote Config `memory_cloud_models_enabled`. Not user-settable; written
    /// by RC refreshes with the same posture as `memoryExtractionRemoteConfigEnabled`.
    var memoryCloudModelsRemoteConfigEnabled: Bool {
        get { memory.remoteConfigCloudModelsEnabled }
        set { memory.remoteConfigCloudModelsEnabled = newValue }
    }

    /// Combined cloud-models gate: memory consent **and** the cloud-models
    /// toggle **and** the fleet switch. This is what the daemon policy carries.
    var memoryCloudModelsEnabled: Bool {
        MemoryCloudModelsGate.isEnabled(
            consentGranted: memory.consentGranted,
            cloudModelsEnabled: memory.cloudModelsEnabled,
            remoteConfigEnabled: memory.remoteConfigCloudModelsEnabled
        )
    }

    /// The daemon's memory egress policy as implied by these settings. CLI
    /// providers are included only while Mac CLI agents are allowed too; API
    /// providers map to daemon provider ids. Disabling keeps the provider list
    /// so re-enabling restores the member's choice.
    func memoryEgressPolicy(now: Date = Date()) -> BurnBarMemoryEgressPolicy {
        // "No retention only" is a promise about every route, and the daemon can
        // only enforce it for API providers; subscription CLIs (`localQuota`) and
        // provider-policy APIs are therefore left out of the policy entirely
        // while it is on, instead of being sent and trusted.
        let noRetentionOnly = memory.cloudModelsRequireNoRetention
        let consented = memory.cloudModelsConsentedProviderIDs
            .filter { !noRetentionOnly || $0.retention == .deny }
        var policy = BurnBarMemoryEgressPolicy()
        policy.enabled = memoryCloudModelsEnabled
        policy.consentedProviderIDs = consented.compactMap(\.daemonProviderID)
        policy.consentedCLIProviderIDs = cliAssistantAllowed
            ? consented.filter(\.requiresCLIConsent).map(\.rawValue)
            : []
        policy.allowedModelIDsByPurpose = [:]
        policy.requireNoRetention = memory.cloudModelsRequireNoRetention
        policy.dailyCapUSD = memory.cloudModelsDailyCapUSD
        policy.updatedAt = now
        return policy
    }

    // MARK: Activation Checklist

    /// The user closed the activation checklist by hand; it never returns.
    var activationChecklistDismissed: Bool {
        get { activation.checklistDismissed }
        set { activation.checklistDismissed = newValue }
    }

    /// When every activation step first read as done. Non-nil retires the card.
    var activationChecklistCompletedAt: Date? {
        get { activation.checklistCompletedAt }
        set { activation.checklistCompletedAt = newValue }
    }

    // MARK: Usage Memory (passive memory from Safari asks + agent session logs)

    /// User consent to usage-memory extraction (default OFF). Setting this true
    /// also marks the consent prompt as shown. Until granted, the whole usage
    /// loop is dormant (see `usageMemoryExtractionEnabled`).
    var usageMemoryConsentGranted: Bool {
        get { memory.usageMemoryConsentGranted }
        set { memory.usageMemoryConsentGranted = newValue }
    }

    /// Whether the usage-memory consent prompt has already been presented.
    var usageMemoryConsentShown: Bool {
        get { memory.usageMemoryConsentShown }
        set { memory.usageMemoryConsentShown = newValue }
    }

    /// Separate opt-in to CLOUD curation of usage memory (default OFF). Only
    /// effective when the extraction gate is open AND placement is a cloud model
    /// (see `usageMemoryCloudCurationEnabled`).
    var usageMemoryCloudCurationConsentGranted: Bool {
        get { memory.usageMemoryCloudCurationConsentGranted }
        set { memory.usageMemoryCloudCurationConsentGranted = newValue }
    }

    /// Where the usage-memory curation model runs (default `.local`).
    var usageMemoryModelPlacement: UsageMemoryModelPlacement {
        get { memory.usageMemoryModelPlacement }
        set { memory.usageMemoryModelPlacement = newValue }
    }

    /// Source toggle: Safari asks feed usage memory (default ON, inert until consent).
    var usageMemorySourceSafariAsksEnabled: Bool {
        get { memory.usageMemorySourceSafariAsksEnabled }
        set { memory.usageMemorySourceSafariAsksEnabled = newValue }
    }

    /// Source toggle: agent session logs feed usage memory (default ON, inert until consent).
    var usageMemorySourceAgentSessionsEnabled: Bool {
        get { memory.usageMemorySourceAgentSessionsEnabled }
        set { memory.usageMemorySourceAgentSessionsEnabled = newValue }
    }

    /// Remote Config `memory_usage_extraction_enabled`. Not user-settable;
    /// written by RC refreshes with the same fail-open-on-transport posture as
    /// `memoryExtractionRemoteConfigEnabled`. Writing this alone does NOT resolve
    /// the lanes — only `applyUsageMemoryRemoteConfig` does — so a stray `true`
    /// here can never open a lane on its own.
    var usageMemoryExtractionRemoteConfigEnabled: Bool {
        get { memory.remoteConfigUsageExtractionEnabled }
        set { memory.remoteConfigUsageExtractionEnabled = newValue }
    }

    /// Remote Config `memory_usage_authority_writes_enabled`. Not user-settable;
    /// written by RC refreshes with the same fail-open-on-transport posture, and
    /// with the same "writing it does not resolve the lanes" rule as above.
    var usageMemoryAuthorityWritesRemoteConfigEnabled: Bool {
        get { memory.remoteConfigUsageAuthorityWritesEnabled }
        set { memory.remoteConfigUsageAuthorityWritesEnabled = newValue }
    }

    /// Whether a Remote Config value (cached or fetched) has been applied to the
    /// usage fleet switches. Both usage lanes stay CLOSED until this is true.
    var usageMemoryRemoteConfigResolved: Bool { memory.hasResolvedUsageRemoteConfig }

    /// Apply a resolved Remote Config snapshot to both usage fleet switches at
    /// once and open the lanes for gating. The only path that resolves them.
    func applyUsageMemoryRemoteConfig(extractionEnabled: Bool, authorityWritesEnabled: Bool) {
        memory.applyUsageRemoteConfig(
            extractionEnabled: extractionEnabled,
            authorityWritesEnabled: authorityWritesEnabled
        )
    }

    /// Combined usage-memory extraction gate: user consent AND the fleet kill
    /// switch AND that fleet value having been resolved. With consent default OFF
    /// the whole usage loop is dormant out of the box, and it stays dormant
    /// through the startup window before Remote Config is read.
    var usageMemoryExtractionEnabled: Bool {
        UsageMemoryExtractionGate.isEnabled(
            usageConsentGranted: memory.usageMemoryConsentGranted,
            remoteConfigEnabled: memory.remoteConfigUsageExtractionEnabled,
            remoteConfigResolved: memory.hasResolvedUsageRemoteConfig
        )
    }

    /// Combined usage-memory authority-write gate: the dedicated fleet switch AND
    /// resolution. Independent of consent and of the extraction gate — this is the
    /// value mirrored into the registry's authority-writes lane.
    var usageMemoryAuthorityWritesEnabled: Bool {
        UsageMemoryAuthorityWriteGate.isEnabled(
            remoteConfigEnabled: memory.remoteConfigUsageAuthorityWritesEnabled,
            remoteConfigResolved: memory.hasResolvedUsageRemoteConfig
        )
    }

    /// Combined cloud-curation gate for usage memory: the extraction gate AND
    /// the separate cloud consent AND a cloud model placement. Triply dormant by
    /// default (no consent, no cloud consent, placement `.local`), so there is
    /// zero usage-derived cloud egress out of the box.
    var usageMemoryCloudCurationEnabled: Bool {
        UsageMemoryCloudGate.isEnabled(
            extractionEnabled: usageMemoryExtractionEnabled,
            cloudConsentGranted: memory.usageMemoryCloudCurationConsentGranted,
            placementIsCloud: memory.usageMemoryModelPlacement.isCloud
        )
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

    var computerUsePhoneControlAttestationRequired: Bool {
        get { chatBackend.computerUsePhoneControlAttestationRequired }
        set { updateComputerUsePhoneControlAttestationRequired(newValue) }
    }

    private func updateComputerUsePhoneControlAttestationRequired(_ required: Bool) {
        let previous = chatBackend.computerUsePhoneControlAttestationRequired
        chatBackend.computerUsePhoneControlAttestationRequired = required
        guard previous != required else { return }
        NotificationCenter.default.post(
            name: .phoneControlAttestationDidChange,
            object: self,
            userInfo: [
                ComputerUseRemoteConfigNotificationUserInfo.phoneControlAttestationRequired: required
            ]
        )
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

    var computerUsePhoneControlRespectsDenyRegions: Bool {
        get { chatBackend.computerUsePhoneControlRespectsDenyRegions }
        set { chatBackend.computerUsePhoneControlRespectsDenyRegions = newValue }
    }

    var mediaKillSwitch: Bool {
        get { chatBackend.mediaKillSwitch }
        set { chatBackend.mediaKillSwitch = newValue }
    }

    /// War Room's global stop (the Wire + the Flame). Fail-closed: engaged
    /// unless Remote Config says otherwise, so an unreachable config never
    /// opens the Mac⇄Mac lane.
    var warRoomKillSwitch: Bool {
        get { chatBackend.warRoomKillSwitch }
        set { chatBackend.warRoomKillSwitch = newValue }
    }

    /// Which machine the Hermes Room points at. Nil means this Mac.
    var activeHermesBodyID: String? {
        get { chatBackend.activeHermesBodyID.isEmpty ? nil : chatBackend.activeHermesBodyID }
        set { chatBackend.activeHermesBodyID = newValue ?? "" }
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

    var systemPermissionsOnboardingCompleted: Bool {
        get { chatBackend.systemPermissionsOnboardingCompleted }
        set { chatBackend.systemPermissionsOnboardingCompleted = newValue }
    }

    var systemPermissionsDeferredKinds: Set<String> {
        get {
            let csv = chatBackend.systemPermissionsDeferredKindsCSV
            return Set(csv.split(separator: ",").map { String($0) }.filter { !$0.isEmpty })
        }
        set {
            chatBackend.systemPermissionsDeferredKindsCSV = newValue.sorted().joined(separator: ",")
        }
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

    var xaiQuotaPlanTier: XAIQuotaPlanTier {
        get { quotas.xaiQuotaPlanTier }
        set { quotas.xaiQuotaPlanTier = newValue }
    }

    var mimoTokenPlanRegion: ProviderEndpointRegion {
        get { quotas.mimoTokenPlanRegion }
        set { quotas.mimoTokenPlanRegion = newValue }
    }

    var mimoTokenPlanTier: MimoTokenPlanTier? {
        get { quotas.mimoTokenPlanTier }
        set { quotas.mimoTokenPlanTier = newValue }
    }

    var mimoTokenPlanBillingCycle: MimoTokenPlanBillingCycle {
        get { quotas.mimoTokenPlanBillingCycle }
        set { quotas.mimoTokenPlanBillingCycle = newValue }
    }

    var tokenizerAssistedFallbackEnabled: Bool {
        get { quotas.tokenizerAssistedFallbackEnabled }
        set { quotas.tokenizerAssistedFallbackEnabled = newValue }
    }

    /// When true, surfaces that show per-account quota cards collapse
    /// multi-account providers into one combined card whose buckets are
    /// summed across accounts (same `(key, windowKind)` grouping).
    var cumulativeAcrossAccounts: Bool {
        get { quotas.cumulativeAcrossAccounts }
        set { quotas.cumulativeAcrossAccounts = newValue }
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
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { // try?-ok(malformed JSON -> [])
            return []
        }
        return decoded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func encodeJSONStringArray(_ values: [String]) -> String {
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let data = try JSONEncoder().encode(normalized)
            guard let json = String(data: data, encoding: .utf8) else {
                throw SettingsJSONEncodingError.nonUTF8Output
            }
            return json
        } catch {
            // Do NOT collapse to "[]" here: that would silently overwrite the
            // user's saved list with an empty array and permanently drop their
            // data on the next flush. Encoding a normalized [String] should be
            // infeasible to fail, so surface it loudly, then preserve the data
            // via a lossless manual serialization rather than discarding it.
            AppLogger.dataStore.error(
                "settings.encodeJSONStringArray.failed",
                metadata: [
                    "errorClass": "\(String(describing: type(of: error)))",
                    "count": "\(normalized.count)"
                ]
            )
            assertionFailure("encodeJSONStringArray failed for a normalized [String]: \(error)")
            return manuallySerializeJSONStringArray(normalized)
        }
    }

    /// Deterministic, infallible JSON-array serialization for `[String]`.
    ///
    /// Used as a data-preserving fallback when `JSONEncoder` somehow fails so we
    /// never silently drop the caller's values. Produces output byte-compatible
    /// with `JSONEncoder` for the subset of characters that require escaping per
    /// RFC 8259, so the round-trip through `decodeJSONStringArray` is preserved.
    static func manuallySerializeJSONStringArray(_ values: [String]) -> String {
        let escapedElements = values.map { value -> String in
            var escaped = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": escaped += "\\\""
                case "\\": escaped += "\\\\"
                // Foundation's JSONEncoder escapes forward slashes (`\/`); match
                // it so the fallback output is byte-identical to the happy path.
                case "/": escaped += "\\/"
                case "\u{08}": escaped += "\\b"
                case "\u{0C}": escaped += "\\f"
                case "\n": escaped += "\\n"
                case "\r": escaped += "\\r"
                case "\t": escaped += "\\t"
                default:
                    if scalar.value < 0x20 {
                        escaped += String(format: "\\u%04x", scalar.value)
                    } else {
                        escaped.unicodeScalars.append(scalar)
                    }
                }
            }
            escaped += "\""
            return escaped
        }
        return "[" + escapedElements.joined(separator: ",") + "]"
    }

    enum SettingsJSONEncodingError: Error {
        case nonUTF8Output
    }

    // MARK: - Visual Capture (Both toggle)

    var visualCaptureSourceToggleEnabled: Bool {
        get { visualCapture.visualCaptureSourceToggleEnabled }
        set { visualCapture.visualCaptureSourceToggleEnabled = newValue }
    }

    var visualCaptureGlobalDefault: VisualCaptureSource {
        get { visualCapture.visualCaptureGlobalDefault }
        set { visualCapture.visualCaptureGlobalDefault = newValue }
    }

    var visualCapturePerProvider: [AgentProvider: VisualCaptureSource] {
        get { visualCapture.visualCapturePerProvider }
        set { visualCapture.visualCapturePerProvider = newValue }
    }

    func visualCaptureSource(for provider: AgentProvider) -> VisualCaptureSource {
        visualCapture.visualCaptureSource(for: provider)
    }

    func isToggleEligible(_ provider: AgentProvider) -> Bool {
        visualCapture.isToggleEligible(provider)
    }

    func setVisualCaptureSource(_ source: VisualCaptureSource, for provider: AgentProvider) {
        visualCapture.setVisualCaptureSource(source, for: provider)
    }

    func clearVisualCaptureSource(for provider: AgentProvider) {
        visualCapture.clearVisualCaptureSource(for: provider)
    }

    // MARK: - Explicit Save

    /// Forces an immediate flush of all dirty settings.
    /// Most mutations are coalesced automatically; this is only needed
    /// before critical transitions (e.g., app termination).
    func save() {
        persistence.flush()
    }
}

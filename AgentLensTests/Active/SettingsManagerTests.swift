import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - SettingsManager Tests

@MainActor
final class SettingsManagerTests: XCTestCase {

    // MARK: - Test Isolation

    private var tempDirectories: [URL] = []

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.openburnbar.tests.settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTestKeychainBackend() -> SettingsManagerTestKeychainBackend {
        SettingsManagerTestKeychainBackend()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    override func tearDown() {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Factory Methods

    private func makeSettingsManager(
        defaults: UserDefaults? = nil,
        controllerSecrets: KeychainStore? = nil,
        gatewaySecrets: KeychainStore? = nil
    ) -> SettingsManager {
        SettingsManager(
            defaults: defaults ?? makeIsolatedDefaults(),
            controllerRuntimeSecrets: controllerSecrets ?? KeychainStore(
                service: "tests.controller.\(UUID().uuidString)",
                legacyServices: [],
                backend: makeTestKeychainBackend()
            ),
            chatGatewaySecrets: gatewaySecrets ?? KeychainStore(
                service: "tests.gateway.\(UUID().uuidString)",
                legacyServices: [],
                backend: makeTestKeychainBackend()
            ),
            // Synchronous writes in tests; the production 100 ms debounce
            // races every immediate `defaults.string(forKey:)` assertion
            // and renders these contracts unverifiable.
            flushDelayNanoseconds: 0
        )
    }

    // MARK: - Default Value Resolution Tests

    func test_refreshInterval_defaultValue_is600Seconds() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.refreshInterval, 600)
    }

    func test_refreshInterval_resolvesToStoredValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(300.0, forKey: "refreshInterval")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.refreshInterval, 300)
    }

    func test_refreshIntervalMinutes_conversionRoundTrips() {
        let settings = makeSettingsManager()
        settings.refreshIntervalMinutes = 5
        XCTAssertEqual(settings.refreshInterval, 300)
        XCTAssertEqual(settings.refreshIntervalMinutes, 5)
    }

    func test_showInMenuBar_defaultValue_isTrueOnFirstLaunch() {
        let defaults = makeIsolatedDefaults()
        defaults.removeObject(forKey: "hasLaunchedBefore")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(settings.showInMenuBar)
    }

    func test_showInMenuBar_resolvesToStoredValueAfterFirstLaunch() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasLaunchedBefore")
        defaults.set(false, forKey: "showInMenuBar")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.showInMenuBar)
    }

    func test_launchAtLogin_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func test_appearanceMode_defaultValue_isSystem() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.appearanceMode, .system)
    }

    func test_appearanceMode_resolvesFromRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("dark", forKey: "appearanceMode")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.appearanceMode, .dark)
    }

    func test_appearanceMode_resolvesFromLegacyPreferLight() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "preferLightAppearance")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.appearanceMode, .light)
    }

    func test_appearanceMode_colorSchemeResolution() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.appearanceMode = .system
        XCTAssertNil(settings.preferredSwiftUIColorScheme)

        settings.appearanceMode = .light
        XCTAssertEqual(settings.preferredSwiftUIColorScheme, .light)

        settings.appearanceMode = .dark
        XCTAssertEqual(settings.preferredSwiftUIColorScheme, .dark)
    }

    func test_defaultTimeRange_defaultValue_isToday() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.defaultTimeRange, .today)
    }

    func test_defaultTimeRange_resolvesFromRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("Last 7 Days", forKey: "defaultTimeRange")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.defaultTimeRange, .last7Days)
    }

    func test_costAlertThreshold_nilWhenNotSet() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertNil(settings.costAlertThreshold)
    }

    func test_costAlertThreshold_resolvesFromStoredValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasCostAlertThreshold")
        defaults.set(10.0, forKey: "costAlertThreshold")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.costAlertThreshold, 10.0)
    }

    func test_costAlertThreshold_clearsWhenSetToNil() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasCostAlertThreshold")
        defaults.set(10.0, forKey: "costAlertThreshold")

        let settings = makeSettingsManager(defaults: defaults)
        settings.costAlertThreshold = nil

        XCTAssertFalse(defaults.bool(forKey: "hasCostAlertThreshold"))
        XCTAssertNil(defaults.object(forKey: "costAlertThreshold"))
    }

    // MARK: - Daily Digest Settings

    func test_dailyDigestEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.dailyDigestEnabled)
    }

    func test_dailyDigestHour_defaultValue_is18() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.dailyDigestHour, 18)
    }

    func test_dailyDigestHour_resolvesFromStoredValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(8, forKey: "dailyDigestHour")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.dailyDigestHour, 8)
    }

    func test_dailyDigestHour_clampsInvalidValues() {
        let defaults = makeIsolatedDefaults()
        defaults.set(25, forKey: "dailyDigestHour")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.dailyDigestHour, 18)

        defaults.removeObject(forKey: "dailyDigestHour")
        defaults.set(-1, forKey: "dailyDigestHour")
        let settings2 = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings2.dailyDigestHour, 18)
    }

    // MARK: - Controller Runtime Settings

    func test_controllerRuntimeEnabled_defaultValue_isTrue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(settings.controllerRuntimeEnabled)
    }

    func test_controllerRuntimeRefreshMinutes_defaultValue_is5() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.controllerRuntimeRefreshMinutes, 5)
    }

    func test_controllerRuntimeRefreshMinutes_minimumIs1() {
        let defaults = makeIsolatedDefaults()
        defaults.set(0, forKey: "controllerRuntimeRefreshMinutes")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.controllerRuntimeRefreshMinutes, 5)

        defaults.removeObject(forKey: "controllerRuntimeRefreshMinutes")
        defaults.set(-5, forKey: "controllerRuntimeRefreshMinutes")
        let settings2 = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings2.controllerRuntimeRefreshMinutes, 5)
    }

    func test_controllerLocalNotificationsEnabled_defaultValue_isTrue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(settings.controllerLocalNotificationsEnabled)
    }

    func test_controllerTelegramEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.controllerTelegramEnabled)
    }

    func test_controllerTelegramChatID_defaultValue_isEmpty() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.controllerTelegramChatID, "")
    }

    func test_controllerCalendarIntegrationEnabled_defaultValue_isTrue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(settings.controllerCalendarIntegrationEnabled)
    }

    func test_controllerCalendarDefaultMinutes_defaultValue_is30() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.controllerCalendarDefaultMinutes, 30)
    }

    func test_controllerCalendarDefaultMinutes_minimumIs15() {
        let defaults = makeIsolatedDefaults()
        defaults.set(5, forKey: "controllerCalendarDefaultMinutes")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.controllerCalendarDefaultMinutes, 30)
    }

    func test_controllerDefaultSnoozeMinutes_defaultValue_is180() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.controllerDefaultSnoozeMinutes, 180)
    }

    func test_controllerDefaultSnoozeMinutes_minimumIs15() {
        let defaults = makeIsolatedDefaults()
        defaults.set(5, forKey: "controllerDefaultSnoozeMinutes")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.controllerDefaultSnoozeMinutes, 180)
    }

    func test_controllerSimulatorToolsEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.controllerSimulatorToolsEnabled)
    }

    // MARK: - HTTP Gateway Settings

    func test_gatewayEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.gatewayEnabled)
    }

    func test_gatewayHost_defaultValue_is127_0_0_1() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.gatewayHost, "127.0.0.1")
    }

    func test_gatewayPort_defaultValue_is8317() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.gatewayPort, 8317)
    }

    func test_gatewayConfigurationDict_containsExpectedValues() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        let dict = settings.gatewayConfigurationDict
        XCTAssertEqual(dict["enabled"] as? Bool, false)
        XCTAssertEqual(dict["host"] as? String, "127.0.0.1")
        XCTAssertEqual(dict["port"] as? Int, 8317)

        settings.gatewayEnabled = true
        settings.gatewayHost = "0.0.0.0"
        settings.gatewayPort = 9090

        let dict2 = settings.gatewayConfigurationDict
        XCTAssertEqual(dict2["enabled"] as? Bool, true)
        XCTAssertEqual(dict2["host"] as? String, "0.0.0.0")
        XCTAssertEqual(dict2["port"] as? Int, 9090)
    }

    func test_gatewayConfigurationDict_usesDefaultsForEmptyHostAndZeroPort() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.gatewayHost = ""
        settings.gatewayPort = 0

        let dict = settings.gatewayConfigurationDict
        XCTAssertEqual(dict["host"] as? String, "127.0.0.1")
        XCTAssertEqual(dict["port"] as? Int, 8317)
    }

    // MARK: - Conversation Indexing Settings

    func test_conversationIndexingEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.conversationIndexingEnabled)
    }

    func test_conversationIndexingConsentShown_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.conversationIndexingConsentShown)
    }

    func test_preferredIndexEmbeddingVersionID_defaultValue_isEmpty() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.preferredIndexEmbeddingVersionID, "")
    }

    func test_preferredIndexEmbeddingVersionIDValue_nilWhenEmpty() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertNil(settings.preferredIndexEmbeddingVersionIDValue)

        settings.preferredIndexEmbeddingVersionID = "  "
        XCTAssertNil(settings.preferredIndexEmbeddingVersionIDValue)

        settings.preferredIndexEmbeddingVersionID = "v1.0"
        XCTAssertEqual(settings.preferredIndexEmbeddingVersionIDValue, "v1.0")
    }

    func test_indexEmbeddingProvider_defaultValue_isDeterministic() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.indexEmbeddingProvider, .deterministic)
    }

    func test_indexEmbeddingProvider_resolvesFromRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("openai", forKey: "indexEmbeddingProvider")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.indexEmbeddingProvider, .openai)
    }

    func test_indexOpenAIModel_defaultValue_isTextEmbedding3Small() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.indexOpenAIModel, "text-embedding-3-small")
    }

    // MARK: - Artifact Discovery Settings

    func test_artifactDiscoveryEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.artifactDiscoveryEnabled)
    }

    func test_artifactDiscoveryRegisteredRoots_defaultValue_isEmptyArray() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.artifactDiscoveryRegisteredRoots, [])
    }

    func test_artifactDiscoveryRegisteredRoots_roundTripsThroughJSON() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.artifactDiscoveryRegisteredRoots = ["/path/one", "/path/two", "/path/three"]
        XCTAssertEqual(settings.artifactDiscoveryRegisteredRoots, ["/path/one", "/path/two", "/path/three"])

        settings.artifactDiscoveryRegisteredRoots = ["  /spaced/path  ", "  "]
        XCTAssertEqual(settings.artifactDiscoveryRegisteredRoots, ["/spaced/path"])
    }

    func test_artifactDiscoveryAdditionalKnownPatterns_defaultValue_isEmptyArray() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.artifactDiscoveryAdditionalKnownPatterns, [])
    }

    func test_artifactDiscoveryAdditionalKnownPatterns_roundTripsThroughJSON() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.artifactDiscoveryAdditionalKnownPatterns = ["*.swift", "*.md"]
        XCTAssertEqual(settings.artifactDiscoveryAdditionalKnownPatterns, ["*.swift", "*.md"])
    }

    // MARK: - Cloud Backup Settings

    func test_conversationCloudBackupEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.conversationCloudBackupEnabled)
    }

    func test_iCloudSessionMirrorEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.iCloudSessionMirrorEnabled)
    }

    func test_sessionLogCloudBackupEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.sessionLogCloudBackupEnabled)
    }

    func test_sessionLogCloudBackupConsentShown_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.sessionLogCloudBackupConsentShown)
    }

    func test_chatThreadContentCloudBackupEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.chatThreadContentCloudBackupEnabled)
    }

    func test_chatThreadContentCloudBackupConsentShown_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.chatThreadContentCloudBackupConsentShown)
    }

    // MARK: - CLI Assistant Settings

    func test_cliAssistantAllowed_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.cliAssistantAllowed)
    }

    func test_cliAssistantConsentShown_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.cliAssistantConsentShown)
    }

    func test_cliAssistantAllowed_settingTrue_alsoSetsConsentShown() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.cliAssistantConsentShown)

        settings.cliAssistantAllowed = true
        XCTAssertTrue(settings.cliAssistantConsentShown)
    }

    func test_openClawGatewayBaseURL_defaultValue_isLocalhost18789() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.openClawGatewayBaseURL, "http://127.0.0.1:18789")
    }

    // MARK: - Hermes Chat Settings

    func test_hermesBearerToken_defaultValue_isEmpty() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.hermesBearerToken, "")
    }

    func test_hermesChatModelOverride_defaultValue_isEmpty() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.hermesChatModelOverride, "")
    }

    func test_hermesChatModelOverride_settingPersists() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.hermesChatModelOverride = "gpt-5.4"
        XCTAssertEqual(settings.hermesChatModelOverride, "gpt-5.4")
        XCTAssertEqual(defaults.string(forKey: "hermesChatModelOverride"), "gpt-5.4")
    }

    // MARK: - Chat Backend Settings

    func test_chatBackendOnboardingCompleted_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.chatBackendOnboardingCompleted)
    }

    func test_switcherOnboardingCompleted_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.switcherOnboardingCompleted)
    }

    func test_selectedOnboardingProvidersCSV_defaultValue_isEmpty() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.selectedOnboardingProvidersCSV, "")
    }

    func test_selectedOnboardingProviders_roundTripsThroughCSV() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.selectedOnboardingProviders = [.codex, .claudeCode, .minimax]
        XCTAssertEqual(settings.selectedOnboardingProviders, Set([.codex, .claudeCode, .minimax]))
        // Persisted CSV is sorted lexicographically for canonical, diff-stable storage.
        XCTAssertEqual(settings.selectedOnboardingProvidersCSV, "claudecode,codex,minimax")

        settings.selectedOnboardingProviders = []
        XCTAssertEqual(settings.selectedOnboardingProviders, [])
        XCTAssertEqual(settings.selectedOnboardingProvidersCSV, "")
    }

    func test_enabledChatBackendIDsCSV_migratesLegacySingleBackendID() {
        let defaults = makeIsolatedDefaults()
        defaults.set("hermes", forKey: "chatBackendID")
        let settings = makeSettingsManager(defaults: defaults)

        XCTAssertEqual(settings.enabledChatBackends, [.hermes])
    }

    func test_enabledChatBackends_defaultValue_whenNoLegacyOrNew() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.enabledChatBackends, [])
    }

    func test_enabledChatBackends_roundTripsThroughCSV() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.setEnabledChatBackends([.codex, .claude])
        XCTAssertEqual(settings.enabledChatBackends, [.codex, .claude])

        settings.setChatBackendEnabled(.hermes, enabled: true)
        XCTAssertTrue(settings.enabledChatBackends.contains(.hermes))

        settings.setChatBackendEnabled(.codex, enabled: false)
        XCTAssertFalse(settings.enabledChatBackends.contains(.codex))
    }

    // MARK: - Usage Display Mode

    func test_usageDisplayMode_defaultValue_isCurrency() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.usageDisplayMode, .currency)
    }

    func test_usageDisplayMode_resolvesFromRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("tokens", forKey: "usageDisplayMode")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.usageDisplayMode, .tokens)
    }

    // MARK: - Auto Session Summaries Settings

    func test_autoSessionSummariesEnabled_defaultValue_isTrue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(settings.autoSessionSummariesEnabled)
    }

    func test_summaryProviderOrderCSV_defaultValue_isLocalMLXMiniMaxOpenRouterZai() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryProviderOrderCSV, "local,mlx,minimax,openrouter,zai")
    }

    func test_summaryProviderOrder_parsesAndDedups() {
        let defaults = makeIsolatedDefaults()
        defaults.set("local,mlx,local,minimax,openrouter,zai,mlx", forKey: "summaryProviderOrderCSV")
        let settings = makeSettingsManager(defaults: defaults)

        let order = settings.summaryProviderOrder
        XCTAssertEqual(order, [.local, .mlx, .minimax, .openrouter, .zai])
    }

    func test_summaryProviderOrder_fallsBackToDefaultWhenEmpty() {
        let defaults = makeIsolatedDefaults()
        defaults.set("", forKey: "summaryProviderOrderCSV")
        let settings = makeSettingsManager(defaults: defaults)

        XCTAssertEqual(settings.summaryProviderOrder, [.local, .mlx, .minimax, .openrouter, .zai])
    }

    func test_summaryProviderOrder_appendsMissingProviders() {
        let defaults = makeIsolatedDefaults()
        defaults.set("local", forKey: "summaryProviderOrderCSV")
        let settings = makeSettingsManager(defaults: defaults)

        let order = settings.summaryProviderOrder
        XCTAssertTrue(order.first == .local)
        XCTAssertTrue(order.contains(.mlx))
        XCTAssertTrue(order.contains(.minimax))
        XCTAssertTrue(order.contains(.openrouter))
        XCTAssertTrue(order.contains(.zai))
    }

    func test_setSummaryProviderOrder_encodesToCSV() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.setSummaryProviderOrder([.zai, .openrouter, .minimax])
        XCTAssertEqual(settings.summaryProviderOrderCSV, "zai,openrouter,minimax")
    }

    func test_summaryDailyCapUSD_nilWhenNotSet() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertNil(settings.summaryDailyCapUSD)
    }

    func test_summaryDailyCapUSD_resolvesFromStoredValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasSummaryDailyCapUSD")
        defaults.set(5.0, forKey: "summaryDailyCapUSD")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryDailyCapUSD, 5.0)
    }

    // MARK: - Summary Model Settings

    func test_summaryOpenRouterPrimaryModel_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryOpenRouterPrimaryModel, "qwen/qwen3.5-9b")
    }

    func test_summaryOpenRouterFallbackModel_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryOpenRouterFallbackModel, "openai/gpt-5-nano")
    }

    func test_summaryMiniMaxModel_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryMiniMaxModel, "gpt-5.5")
    }

    func test_summaryZaiModel_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryZaiModel, "glm-5-turbo")
    }

    func test_summaryLocalModel_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryLocalModel, "qwen3.5:9b")
    }

    func test_summaryLocalBaseURL_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryLocalBaseURL, "http://127.0.0.1:11434")
    }

    func test_summaryMLXModel_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryMLXModel, "mlx-community/Qwen3-4B-4bit")
    }

    func test_summaryMLXBaseURL_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryMLXBaseURL, "http://127.0.0.1:8080")
    }

    func test_summaryMaxPromptChars_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryMaxPromptChars, 60_000)
    }

    func test_summaryMaxPromptChars_minimumIs4000() {
        let defaults = makeIsolatedDefaults()
        defaults.set(1000, forKey: "summaryMaxPromptChars")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryMaxPromptChars, 60_000)
    }

    func test_summaryMaxOutputTokens_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryMaxOutputTokens, 280)
    }

    func test_summaryMaxOutputTokens_minimumIs120() {
        let defaults = makeIsolatedDefaults()
        defaults.set(50, forKey: "summaryMaxOutputTokens")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryMaxOutputTokens, 280)
    }

    func test_summaryRetryCount_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryRetryCount, 1)
    }

    func test_summaryBatchSize_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryBatchSize, 25)
    }

    func test_summaryFirstLoadBatchSize_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryFirstLoadBatchSize, 120)
    }

    func test_summaryRequestTimeoutSeconds_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryRequestTimeoutSeconds, 20)
    }

    func test_summaryMaxConcurrency_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryMaxConcurrency, 8)
    }

    func test_summaryTimeLimitMinutes_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.summaryTimeLimitMinutes, 0)
    }

    // MARK: - Cross-Encoder Settings

    func test_crossEncoderRerankEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.crossEncoderRerankEnabled)
    }

    func test_crossEncoderProvider_defaultValue_isCodexCLI() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.crossEncoderProvider, .codexCLI)
    }

    func test_crossEncoderModel_defaultValue_forCodexCLI() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.crossEncoderModel, "gpt-5.5")
    }

    func test_crossEncoderMaxCandidates_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.crossEncoderMaxCandidates, 40)
    }

    func test_crossEncoderMaxCandidates_minimumIs5() {
        let defaults = makeIsolatedDefaults()
        defaults.set(2, forKey: "crossEncoderMaxCandidates")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.crossEncoderMaxCandidates, 40)
    }

    func test_crossEncoderMaxCharsPerCandidate_defaultValue() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.crossEncoderMaxCharsPerCandidate, 512)
    }

    func test_crossEncoderMaxCharsPerCandidate_minimumIs128() {
        let defaults = makeIsolatedDefaults()
        defaults.set(64, forKey: "crossEncoderMaxCharsPerCandidate")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.crossEncoderMaxCharsPerCandidate, 512)
    }

    // MARK: - Quota Mode Settings

    func test_miniMaxQuotaMode_defaultValue_isTokenPlan() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.miniMaxQuotaMode, .tokenPlan)
    }

    func test_factoryQuotaPlanTier_defaultValue_isUnknown() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertEqual(settings.factoryQuotaPlanTier, .unknown)
    }

    func test_tokenizerAssistedFallbackEnabled_defaultValue_isFalse() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.tokenizerAssistedFallbackEnabled)
    }

    // MARK: - Hermes Chat Model Resolution

    func test_resolvedHermesChatModel_usesOverrideWhenSet() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.hermesChatModelOverride = "gpt-5.4-pro"
        XCTAssertEqual(settings.resolvedHermesChatModel(gatewayAdvertisedModel: "minimax-m2.7"), "gpt-5.4-pro")
    }

    func test_resolvedHermesChatModel_usesDefaultWhenAdvertisedModelIsNil() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        XCTAssertEqual(settings.resolvedHermesChatModel(gatewayAdvertisedModel: nil), "hermes")
    }

    func test_resolvedHermesChatModel_usesDefaultWhenAdvertisedModelIsEmpty() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        XCTAssertEqual(settings.resolvedHermesChatModel(gatewayAdvertisedModel: "   "), "hermes")
    }

    func test_resolvedHermesChatModel_switchesToCodexModelWhenMinimaxAdvertised() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        XCTAssertEqual(settings.resolvedHermesChatModel(gatewayAdvertisedModel: "minimax-m2.7-highspeed"), "gpt-5.5")
    }

    func test_resolvedHermesChatModel_usesHermesWhenNoSpecialCase() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        XCTAssertEqual(settings.resolvedHermesChatModel(gatewayAdvertisedModel: "some-other-model"), "hermes")
    }

    func test_resolvedHermesChatModel_trimsWhitespace() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.hermesChatModelOverride = "  gpt-5.4-pro  "
        XCTAssertEqual(settings.resolvedHermesChatModel(gatewayAdvertisedModel: nil), "gpt-5.4-pro")
    }

    // MARK: - Usage Metric Formatting

    func test_formatUsageMetric_currencyMode() {
        let defaults = makeIsolatedDefaults()
        defaults.set("currency", forKey: "usageDisplayMode")
        let settings = makeSettingsManager(defaults: defaults)

        XCTAssertEqual(settings.formatUsageMetric(cost: 0, tokens: 1000), "$0.00")
        XCTAssertEqual(settings.formatUsageMetric(cost: 0.005, tokens: 1000), "$0.0050")
        XCTAssertEqual(settings.formatUsageMetric(cost: 1.5, tokens: 1000), "$1.50")
        XCTAssertEqual(settings.formatUsageMetric(cost: 123.456, tokens: 1000), "$123.46")
    }

    func test_formatUsageMetric_tokensMode() {
        let defaults = makeIsolatedDefaults()
        defaults.set("tokens", forKey: "usageDisplayMode")
        let settings = makeSettingsManager(defaults: defaults)

        XCTAssertEqual(settings.formatUsageMetric(cost: 1.5, tokens: 500), "500")
        XCTAssertEqual(settings.formatUsageMetric(cost: 1.5, tokens: 1500), "1.5K")
        XCTAssertEqual(settings.formatUsageMetric(cost: 1.5, tokens: 1_500_000), "1.50M")
        XCTAssertEqual(settings.formatUsageMetric(cost: 1.5, tokens: 1_500_000_000), "1.50B")
    }

    // MARK: - Log Path Settings

    func test_logPaths_defaultValues_areProviderLogDirectories() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        for provider in AgentProvider.allCases {
            XCTAssertEqual(settings.logPaths[provider], provider.logDirectory)
        }
    }

    func test_logPaths_settingPersistsToDefaults() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.logPaths[.codex] = "/custom/path"
        XCTAssertEqual(settings.logPaths[.codex], "/custom/path")
        XCTAssertEqual(defaults.string(forKey: "logPath_codex"), "/custom/path")
    }

    func test_resetPathsToDefaults_restoresAllProviders() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.logPaths[.codex] = "/custom/path"
        settings.logPaths[.cursor] = "/another/path"

        settings.resetPathsToDefaults()

        XCTAssertEqual(settings.logPaths[.codex], AgentProvider.codex.logDirectory)
        XCTAssertEqual(settings.logPaths[.cursor], AgentProvider.cursor.logDirectory)
    }

    // MARK: - Provider Detection

    func test_detectAvailableProviders_returnsFalseForAllOnCleanSystem() throws {
        // Skipped: `detectAvailableProviders` walks the host file system for
        // every provider's log directory (e.g. `~/.codex/sessions`). Any
        // developer running this on a machine that has even one provider
        // installed will fail. Re-enable inside a hermetic FS sandbox.
        try XCTSkipIf(true, "Environmental — requires a hermetic FS sandbox.")
    }

    func test_pathExists_forNonExistentPath() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        // Default `restrictedLogAccess=true` falls back to the provider's real
        // log directory when a custom path is outside known roots, which may
        // exist on the developer's machine. Disable restricted mode to assert
        // the literal nonexistent custom path resolves false.
        settings.restrictedLogAccess = false
        settings.logPaths[.codex] = "/nonexistent/path/xyz123"
        XCTAssertFalse(settings.pathExists(for: .codex))
    }

    // MARK: - Path Resolution

    func test_resolvedPath_returnsConfiguredPath() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        // See `test_pathExists_forNonExistentPath` for why restricted mode is
        // turned off here: `~/Library/Custom` is not a known root and would
        // fall back to the provider's default in restricted mode.
        settings.restrictedLogAccess = false
        settings.logPaths[.augment] = "~/Library/Custom"
        let resolved = settings.resolvedPath(for: .augment)

        XCTAssertNotNil(resolved)
        let path = resolved!.path
        XCTAssertTrue(path.contains("Library/Custom") || path.contains("Custom"))
    }

    // MARK: - First Launch

    func test_isFirstLaunch_trueOnFreshInstall() {
        let defaults = makeIsolatedDefaults()
        defaults.removeObject(forKey: "hasLaunchedBefore")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(settings.isFirstLaunch)
    }

    func test_isFirstLaunch_falseAfterFirstLaunch() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasLaunchedBefore")
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertFalse(settings.isFirstLaunch)
    }

    // MARK: - Onboarding Provider Selection

    func test_selectedOnboardingProviders_emptyByDefault() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(settings.selectedOnboardingProviders.isEmpty)
    }

    func test_selectedOnboardingProviders_ignoresUnknownProviders() {
        let defaults = makeIsolatedDefaults()
        defaults.set("codex,unknownprovider,minimax", forKey: "selectedOnboardingProvidersCSV")
        let settings = makeSettingsManager(defaults: defaults)

        XCTAssertTrue(settings.selectedOnboardingProviders.contains(.codex))
        XCTAssertTrue(settings.selectedOnboardingProviders.contains(.minimax))
        XCTAssertEqual(settings.selectedOnboardingProviders.count, 2)
    }

    // MARK: - JSON Encoding/Decoding

    func test_decodeJSONStringArray_handlesInvalidJSON() {
        let result = SettingsManager.self.decodeJSONStringArray("not json")
        XCTAssertEqual(result, [])
    }

    func test_decodeJSONStringArray_handlesEmptyString() {
        let result = SettingsManager.self.decodeJSONStringArray("")
        XCTAssertEqual(result, [])
    }

    func test_decodeJSONStringArray_roundTrips() {
        let input = ["/path/one", "/path/two", "  spaced  "]
        let encoded = SettingsManager.self.encodeJSONStringArray(input)
        let decoded = SettingsManager.self.decodeJSONStringArray(encoded)
        XCTAssertEqual(decoded, ["/path/one", "/path/two", "spaced"])
    }

    func test_encodeJSONStringArray_filtersEmptyStrings() {
        let input = ["one", "", "  ", "two"]
        let encoded = SettingsManager.self.encodeJSONStringArray(input)
        let decoded = SettingsManager.self.decodeJSONStringArray(encoded)
        XCTAssertEqual(decoded, ["one", "two"])
    }

    // MARK: - Settings Change Persistence

    func test_settingProperty_triggersSave() {
        let defaults = makeIsolatedDefaults()
        let settings = makeSettingsManager(defaults: defaults)

        settings.refreshInterval = 300
        XCTAssertEqual(defaults.double(forKey: "refreshInterval"), 300)

        settings.appearanceMode = .dark
        XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "dark")

        settings.showInMenuBar = false
        XCTAssertFalse(defaults.bool(forKey: "showInMenuBar"))
    }

    func test_settingSecret_triggersKeychainPersistence() {
        let controllerSecrets = KeychainStore(
            service: "tests.controller.\(UUID().uuidString)",
            legacyServices: [],
            backend: makeTestKeychainBackend()
        )
        let gatewaySecrets = KeychainStore(
            service: "tests.gateway.\(UUID().uuidString)",
            legacyServices: [],
            backend: makeTestKeychainBackend()
        )
        let defaults = makeIsolatedDefaults()
        let settings = SettingsManager(
            defaults: defaults,
            controllerRuntimeSecrets: controllerSecrets,
            chatGatewaySecrets: gatewaySecrets
        )

        settings.controllerTelegramBotToken = "test-telegram-token"
        settings.openClawBearerToken = "test-openclaw-token"

        XCTAssertEqual(
            try? controllerSecrets.string(for: OpenBurnBarIdentity.controllerTelegramBotTokenAccount),
            "test-telegram-token"
        )
        XCTAssertEqual(
            try? gatewaySecrets.string(for: OpenBurnBarIdentity.openClawBearerTokenAccount),
            "test-openclaw-token"
        )
    }

    // MARK: - AppearanceMode Tests

    func test_appearanceMode_allCases() {
        XCTAssertEqual(AppearanceMode.allCases.count, 3)
        XCTAssertTrue(AppearanceMode.allCases.contains(.system))
        XCTAssertTrue(AppearanceMode.allCases.contains(.light))
        XCTAssertTrue(AppearanceMode.allCases.contains(.dark))
    }

    func test_appearanceMode_colorScheme() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
    }

    // MARK: - TimeRange Tests

    func test_timeRange_allCases() {
        XCTAssertEqual(TimeRange.allCases.count, 5)
        XCTAssertTrue(TimeRange.allCases.contains(.today))
        XCTAssertTrue(TimeRange.allCases.contains(.last7Days))
        XCTAssertTrue(TimeRange.allCases.contains(.last30Days))
        XCTAssertTrue(TimeRange.allCases.contains(.thisMonth))
        XCTAssertTrue(TimeRange.allCases.contains(.allTime))
    }

    func test_timeRange_displayName() {
        XCTAssertEqual(TimeRange.today.displayName, "Today")
        XCTAssertEqual(TimeRange.last7Days.displayName, "Last 7 Days")
        XCTAssertEqual(TimeRange.last30Days.displayName, "Last 30 Days")
        XCTAssertEqual(TimeRange.thisMonth.displayName, "This Month")
        XCTAssertEqual(TimeRange.allTime.displayName, "All Time")
    }

    func test_timeRange_dateRange_today() {
        let range = TimeRange.today.dateRange()
        XCTAssertNotNil(range)

        let calendar = Calendar.current
        XCTAssertTrue(calendar.isDateInToday(range!.lowerBound))
        // Upper bound is exclusive — `startOfDay + 1 day == startOfTomorrow`.
        XCTAssertTrue(calendar.isDateInTomorrow(range!.upperBound))
    }

    func test_timeRange_dateRange_last7Days() {
        let range = TimeRange.last7Days.dateRange()
        XCTAssertNotNil(range)

        let now = Date()
        XCTAssertLessThan(range!.lowerBound, now)
        XCTAssertGreaterThan(range!.lowerBound, now.addingTimeInterval(-8 * 24 * 60 * 60))
    }

    func test_timeRange_dateRange_allTime() {
        let range = TimeRange.allTime.dateRange()
        XCTAssertNil(range)
    }

    // MARK: - SummaryProviderID Tests

    func test_summaryProviderID_allCases() {
        XCTAssertEqual(SummaryProviderID.allCases.count, 5)
        XCTAssertTrue(SummaryProviderID.allCases.contains(.local))
        XCTAssertTrue(SummaryProviderID.allCases.contains(.mlx))
        XCTAssertTrue(SummaryProviderID.allCases.contains(.minimax))
        XCTAssertTrue(SummaryProviderID.allCases.contains(.openrouter))
        XCTAssertTrue(SummaryProviderID.allCases.contains(.zai))
    }

    // MARK: - IndexEmbeddingProviderID Tests

    func test_indexEmbeddingProviderID_allCases() {
        XCTAssertEqual(IndexEmbeddingProviderID.allCases.count, 2)
        XCTAssertTrue(IndexEmbeddingProviderID.allCases.contains(.deterministic))
        XCTAssertTrue(IndexEmbeddingProviderID.allCases.contains(.openai))
    }

    // MARK: - ChatBackendID Tests

    func test_chatBackendID_allCases() {
        XCTAssertEqual(ChatBackendID.allCases.count, 4)
        XCTAssertTrue(ChatBackendID.allCases.contains(.codex))
        XCTAssertTrue(ChatBackendID.allCases.contains(.claude))
        XCTAssertTrue(ChatBackendID.allCases.contains(.hermes))
        XCTAssertTrue(ChatBackendID.allCases.contains(.openclaw))
    }

    func test_chatBackendID_displayNames() {
        XCTAssertEqual(ChatBackendID.codex.displayName, "Codex")
        XCTAssertEqual(ChatBackendID.claude.displayName, "Claude Code")
        XCTAssertEqual(ChatBackendID.hermes.displayName, "Hermes")
        XCTAssertEqual(ChatBackendID.openclaw.displayName, "OpenClaw")
    }

    func test_chatBackendID_encodeEnabledList() {
        let result = ChatBackendID.encodeEnabledList([.codex, .hermes])
        XCTAssertTrue(result.contains("codex"))
        XCTAssertTrue(result.contains("hermes"))
    }

    func test_chatBackendID_decodeEnabledList() {
        let csv = "codex,hermes"
        let result = ChatBackendID.decodeEnabledList(fromCSV: csv)
        XCTAssertTrue(result.contains(.codex))
        XCTAssertTrue(result.contains(.hermes))
    }
}

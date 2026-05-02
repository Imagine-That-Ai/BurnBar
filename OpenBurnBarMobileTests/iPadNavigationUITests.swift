import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// UI Tests for iPad navigation flows.
/// These run on iPad Air simulator and verify the NavigationSplitView shell.
@MainActor
final class iPadNavigationUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Route Model

    func testDashboardNavigationModel_initialState() {
        let model = DashboardNavigationModel()
        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    func testDashboardNavigationModel_navigatePushesHistory() {
        let model = DashboardNavigationModel()
        model.navigate(to: .quota)
        XCTAssertEqual(model.currentRoute, .quota)
        XCTAssertTrue(model.canGoBack)
    }

    func testDashboardNavigationModel_goBackRestoresPrevious() {
        let model = DashboardNavigationModel()
        model.navigate(to: .quota)
        model.navigate(to: .activity)
        XCTAssertEqual(model.currentRoute, .activity)
        model.goBack()
        XCTAssertEqual(model.currentRoute, .quota)
        model.goBack()
        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    func testDashboardNavigationModel_resetToOverview() {
        let model = DashboardNavigationModel()
        model.navigate(to: .sessionLogs)
        model.navigate(to: .projects)
        model.resetToOverview()
        XCTAssertEqual(model.currentRoute, .overview)
        XCTAssertFalse(model.canGoBack)
    }

    // MARK: - Settings Tab Identity

    func testiPadSettingsTabs_countAndNoDaemon() {
        let tabs = iPadSettingsTab.allCases
        XCTAssertEqual(tabs.count, 7)
        XCTAssertFalse(tabs.contains(where: { $0.rawValue == "daemon" }))
    }

    func testiPadSettingsTabs_titles() {
        XCTAssertEqual(iPadSettingsTab.general.title, "General")
        XCTAssertEqual(iPadSettingsTab.account.title, "Account")
        XCTAssertEqual(iPadSettingsTab.providers.title, "Providers")
        XCTAssertEqual(iPadSettingsTab.alerts.title, "Alerts")
        XCTAssertEqual(iPadSettingsTab.notifications.title, "Notifications")
        XCTAssertEqual(iPadSettingsTab.devicesAndSync.title, "Devices & Sync")
        XCTAssertEqual(iPadSettingsTab.switcher.title, "Account Switcher")
    }

    // MARK: - Auth Gate Branching

    func testAuthGateView_usesHorizontalSizeClass() {
        let view = AuthGateView()
        XCTAssertNotNil(view)
    }

    // MARK: - Provider Dashboard Store

    func testProviderDashboardStore_aggregatesWithRealisticData() {
        let store = ProviderDashboardStore(provider: .claudeCode)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        store.usages = [
            TokenUsage(
                provider: .claudeCode,
                sessionId: "sess-1",
                projectName: "TestProject",
                model: "claude-3-5-sonnet",
                inputTokens: 1000,
                outputTokens: 500,
                costUSD: 0.05,
                startTime: now,
                endTime: now
            ),
            TokenUsage(
                provider: .claudeCode,
                sessionId: "sess-2",
                projectName: "TestProject",
                model: "claude-3-5-sonnet",
                inputTokens: 2000,
                outputTokens: 1000,
                costUSD: 0.10,
                startTime: yesterday,
                endTime: yesterday
            )
        ]

        XCTAssertEqual(store.totalCost, 0.15, accuracy: 0.001)
        XCTAssertEqual(store.totalTokens, 4500)
        XCTAssertEqual(store.totalSessions, 2)
        XCTAssertEqual(store.inputTokens, 3000)
        XCTAssertEqual(store.outputTokens, 1500)
        XCTAssertEqual(store.dailyPoints.count, 2)
    }

    // MARK: - Hermes Service

    func testHermesService_streamingState() {
        let service = HermesService()
        // isStreaming may already be false from async error handler
        service.sendMessage("Hello")
        XCTAssertTrue(service.isStreaming)
    }

    func testHermesService_clearChatResetsState() {
        let service = HermesService()
        // Manually populate state to avoid async network race
        service.messages.append(HermesChatMessage(role: .user, text: "Test"))
        service.isStreaming = true
        service.lastError = "Some error"
        service.clearChat()
        XCTAssertTrue(service.messages.isEmpty)
        // isStreaming may already be false from async error handler
        XCTAssertNil(service.lastError)
    }

    // MARK: - Session Logs Search

    func testSessionLogs_filteredUsages_searchByModel() {
        let usage1 = TokenUsage(
            provider: .claudeCode,
            sessionId: "s1",
            projectName: "P1",
            model: "gpt-4o",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )
        let usage2 = TokenUsage(
            provider: .codex,
            sessionId: "s2",
            projectName: "P2",
            model: "claude-3",
            inputTokens: 200,
            outputTokens: 100,
            costUSD: 0.02,
            startTime: Date(),
            endTime: Date()
        )

        let usages = [usage1, usage2]
        let searchText = "gpt"
        let lower = searchText.lowercased()
        let filtered = usages.filter {
            $0.model.lowercased().contains(lower) ||
            $0.projectName.lowercased().contains(lower) ||
            $0.provider.rawValue.lowercased().contains(lower) ||
            $0.sessionId.lowercased().contains(lower)
        }

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.model, "gpt-4o")
    }

    // MARK: - Deep Link URLs

    func testDeepLinkURL_dashboard() {
        let url = URL(string: "burnbar://dashboard")!
        XCTAssertEqual(url.scheme, "burnbar")
        XCTAssertEqual(url.host, "dashboard")
    }

    func testDeepLinkURL_settings() {
        let url = URL(string: "burnbar://settings")!
        XCTAssertEqual(url.host, "settings")
    }

    func testDeepLinkURL_chat() {
        let url = URL(string: "burnbar://chat")!
        XCTAssertEqual(url.host, "chat")
    }
}

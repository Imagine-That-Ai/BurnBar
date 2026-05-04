import XCTest
@testable import OpenBurnBar

// MARK: - DashboardNavigationModelTests

@MainActor
final class DashboardNavigationModelTests: XCTestCase {

    func test_initialState() {
        let nav = DashboardNavigationModel()
        XCTAssertEqual(nav.mainRoute, .overview)
        XCTAssertTrue(nav.routeHistory.isEmpty)
        XCTAssertEqual(nav.viewMode, .agents)
        XCTAssertEqual(nav.selectedTimeRange, .today)
        XCTAssertFalse(nav.canGoBack)
    }

    func test_navigate_toOverview_doesNotPush() {
        let nav = DashboardNavigationModel()
        nav.navigate(to: .overview)
        XCTAssertEqual(nav.mainRoute, .overview)
        XCTAssertTrue(nav.routeHistory.isEmpty)
    }

    func test_navigate_pushesHistory() {
        let nav = DashboardNavigationModel()
        nav.navigate(to: .database)
        XCTAssertEqual(nav.mainRoute, .database)
        XCTAssertEqual(nav.routeHistory, [.overview])
        XCTAssertTrue(nav.canGoBack)
    }

    func test_navigate_sameRoute_noOp() {
        let nav = DashboardNavigationModel()
        nav.navigate(to: .database)
        nav.navigate(to: .database)
        XCTAssertEqual(nav.mainRoute, .database)
        XCTAssertEqual(nav.routeHistory, [.overview])
    }

    func test_goBack_popsHistory() {
        let nav = DashboardNavigationModel()
        nav.navigate(to: .database)
        nav.goBack()
        XCTAssertEqual(nav.mainRoute, .overview)
        XCTAssertTrue(nav.routeHistory.isEmpty)
        XCTAssertFalse(nav.canGoBack)
    }

    func test_goBack_atRoot_noOp() {
        let nav = DashboardNavigationModel()
        nav.goBack()
        XCTAssertEqual(nav.mainRoute, .overview)
        XCTAssertTrue(nav.routeHistory.isEmpty)
    }

    func test_routeTitle() {
        let nav = DashboardNavigationModel()
        XCTAssertEqual(nav.routeTitle(.overview), "Overview")
        XCTAssertEqual(nav.routeTitle(.database), "Database")
        XCTAssertEqual(nav.routeTitle(.projects), "Projects")
    }

    func test_backButtonHelpText() {
        let nav = DashboardNavigationModel()
        XCTAssertEqual(nav.backButtonHelpText, "Back to Overview")
        nav.navigate(to: .database)
        XCTAssertEqual(nav.backButtonHelpText, "Back to Overview")
        nav.navigate(to: .projects)
        XCTAssertEqual(nav.backButtonHelpText, "Back to Database")
    }

    func test_sidebarRouteOrder_agentsMode() {
        let nav = DashboardNavigationModel()
        let summaries = [
            ProviderSummary(provider: .cursor, totalCost: 1, totalTokens: 100, totalInputTokens: 50, totalOutputTokens: 50, sessionCount: 1, modelBreakdown: [], provenanceConfidence: .exact, provenanceMethod: .providerLog, hasEstimatedContributions: false, cacheEfficiency: .zero)
        ]
        let order = nav.sidebarRouteOrder(providerSummaries: summaries, modelSummaries: [])
        XCTAssertEqual(order, [.overview, .provider(.cursor)])
    }

    func test_sidebarRouteOrder_modelsMode() {
        let nav = DashboardNavigationModel()
        nav.viewMode = .models
        let summaries = [
            ModelSummary(modelName: "gpt-4", displayName: "GPT-4", totalCost: 1, totalTokens: 100, totalInputTokens: 50, totalOutputTokens: 50, sessionCount: 1, providerBreakdown: [], cacheEfficiency: .zero)
        ]
        let order = nav.sidebarRouteOrder(providerSummaries: [], modelSummaries: summaries)
        XCTAssertEqual(order, [.overview, .model("gpt-4")])
    }
}

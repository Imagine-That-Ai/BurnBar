import XCTest
@testable import OpenBurnBarCore

final class AgentInsightsScopeTests: XCTestCase {

    func testAggregateScopeMatchesEveryProvider() {
        let scope = AgentInsightsScope.aggregate
        for provider in AgentProvider.allCases {
            XCTAssertTrue(
                scope.matches(providerToken: provider.rawValue),
                "Aggregate scope should match \(provider.rawValue)"
            )
        }
        XCTAssertTrue(scope.isAggregate)
    }

    func testAgentScopeMatchesOnlyItsProvider() {
        let scope = AgentInsightsScope.agent(.codex)
        XCTAssertTrue(scope.matches(providerToken: "Codex"))
        XCTAssertFalse(scope.matches(providerToken: "Claude Code"))
        XCTAssertFalse(scope.isAggregate)
    }

    func testAsInsightFilterCarriesProviderAndWindow() {
        let scope = AgentInsightsScope.agent(.claudeCode, window: .last30d)
        let filter = scope.asInsightFilter
        XCTAssertEqual(filter.window, .last30d)
        XCTAssertEqual(filter.providers, ["Claude Code"])
    }

    func testAsInsightFilterMergesExtraFilters() {
        let extras = InsightFilter(
            window: .last7d,
            providers: ["ignored"],
            projects: ["BurnBar"]
        )
        let scope = AgentInsightsScope(
            provider: .codex,
            window: .last7d,
            extraFilters: extras
        )
        let filter = scope.asInsightFilter
        XCTAssertEqual(filter.providers, ["Codex"], "Scope provider must override extras")
        XCTAssertEqual(filter.projects, ["BurnBar"])
    }

    func testRouteSlugRoundTripForEveryProvider() {
        for provider in AgentProvider.allCases {
            let scope = AgentInsightsScope.agent(provider)
            let slug = scope.routeSlug
            XCTAssertEqual(slug, provider.persistedToken)
            let parsed = AgentInsightsScope.from(routeSlug: slug)
            XCTAssertEqual(parsed?.provider, provider, "Round-trip failed for \(provider.rawValue)")
        }
    }

    func testRouteSlugAllResolvesToAggregate() {
        let scope = AgentInsightsScope.from(routeSlug: "all")
        XCTAssertNotNil(scope)
        XCTAssertTrue(scope?.isAggregate ?? false)
    }

    func testRouteSlugEmptyResolvesToAggregate() {
        let scope = AgentInsightsScope.from(routeSlug: "")
        XCTAssertNotNil(scope)
        XCTAssertTrue(scope?.isAggregate ?? false)
    }

    func testRouteSlugUnknownReturnsNil() {
        XCTAssertNil(AgentInsightsScope.from(routeSlug: "definitely-not-an-agent"))
    }
}

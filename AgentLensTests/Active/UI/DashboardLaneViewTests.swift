import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardLaneViews

@MainActor
final class DashboardLaneViewTests: XCTestCase {

    // MARK: - Provider Lane

    func test_providerLane_rendersWithSummaries() throws {
        let summary = ProviderSummary(
            provider: .factory,
            totalCost: 2.50,
            totalTokens: 2000,
            totalInputTokens: 1200,
            totalOutputTokens: 800,
            sessionCount: 3,
            modelBreakdown: [],
            provenanceConfidence: .exact,
            provenanceMethod: .providerLog,
            hasEstimatedContributions: false,
            cacheEfficiency: .zero
        )
        let view = DashboardProviderLaneView(
            summaries: [summary],
            overviewAppeared: true,
            onNavigateToProvider: { _ in }
        )
        .environment(SettingsManager.shared)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_providerLane_rendersEmptyWhenNoSummaries() throws {
        let view = DashboardProviderLaneView(
            summaries: [],
            overviewAppeared: true,
            onNavigateToProvider: { _ in }
        )
        XCTAssertNoThrow(try view.inspect())
    }

    // MARK: - Model Lane

    func test_modelLane_rendersWithModels() throws {
        let model = ModelSummary(
            modelName: "gpt-4o",
            displayName: "GPT-4o",
            totalCost: 1.50,
            totalTokens: 1500,
            totalInputTokens: 900,
            totalOutputTokens: 600,
            sessionCount: 2,
            providerBreakdown: [],
            cacheEfficiency: .zero
        )
        let view = DashboardModelLaneView(
            models: [model],
            overviewAppeared: true,
            onNavigateToModel: { _ in }
        )
        .environment(SettingsManager.shared)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_modelLane_rendersEmptyWhenNoModels() throws {
        let view = DashboardModelLaneView(
            models: [],
            overviewAppeared: true,
            onNavigateToModel: { _ in }
        )
        XCTAssertNoThrow(try view.inspect())
    }

    // MARK: - Activity Lane

    func test_activityLane_rendersRecentSessions() throws {
        let view = DashboardActivityLaneView(
            usages: ViewTestFixtures.makeWeekOfUsages(),
            topModels: [(model: "gpt-4o", provider: .factory, cost: 1.0, tokens: 1000)],
            settingsManager: .shared,
            overviewAppeared: true
        )
        XCTAssertNoThrow(try view.inspect())
    }

    func test_activityLane_rendersEmptyWhenNoUsages() throws {
        let view = DashboardActivityLaneView(
            usages: [],
            topModels: [],
            settingsManager: .shared,
            overviewAppeared: true
        )
        XCTAssertNoThrow(try view.inspect())
    }
}

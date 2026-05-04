import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardSidebarTests

@MainActor
final class DashboardSidebarTests: XCTestCase {

    private func makeSidebar(
        viewMode: DashboardViewMode = .agents,
        mainRoute: DashboardMainRoute = .overview,
        providerSummaries: [ProviderSummary] = [],
        modelSummaries: [ModelSummary] = [],
        totalCost: Double = 0,
        totalTokens: Int = 0,
        filteredUsagesCount: Int = 0,
        activeProviderCount: Int = 0,
        selectedTimeRange: TimeRange = .today,
        sidebarAppeared: Bool = true,
        onNavigate: @escaping (DashboardMainRoute) -> Void = { _ in }
    ) -> DashboardSidebar {
        let store = try! DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false)
        return DashboardSidebar(
            viewMode: viewMode,
            mainRoute: mainRoute,
            providerSummaries: providerSummaries,
            modelSummaries: modelSummaries,
            totalCost: totalCost,
            totalTokens: totalTokens,
            filteredUsagesCount: filteredUsagesCount,
            activeProviderCount: activeProviderCount,
            selectedTimeRange: selectedTimeRange,
            accountManager: .shared,
            cloudSyncService: nil,
            settingsManager: .shared,
            dataStore: store,
            sidebarAppeared: sidebarAppeared,
            onNavigate: onNavigate,
            onBack: {},
            onOpenCursorExtension: {}
        )
    }

    func test_rendersWithoutCrashing() throws {
        let view = makeSidebar()
        XCTAssertNoThrow(try view.inspect())
    }

    func test_rendersWithProviderSummaries() throws {
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
        let view = makeSidebar(providerSummaries: [summary])
        let sut = try view.inspect()
        XCTAssertNoThrow(sut)
    }

    func test_rendersWithModelSummaries() throws {
        let summary = ModelSummary(
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
        let view = makeSidebar(viewMode: .models, modelSummaries: [summary])
        let sut = try view.inspect()
        XCTAssertNoThrow(sut)
    }

    func test_navigateCallbackFires() throws {
        var navigatedRoute: DashboardMainRoute?
        let summary = ProviderSummary(
            provider: .cursor,
            totalCost: 1.0,
            totalTokens: 100,
            totalInputTokens: 50,
            totalOutputTokens: 50,
            sessionCount: 1,
            modelBreakdown: [],
            provenanceConfidence: .exact,
            provenanceMethod: .providerLog,
            hasEstimatedContributions: false,
            cacheEfficiency: .zero
        )
        let view = makeSidebar(
            providerSummaries: [summary],
            onNavigate: { navigatedRoute = $0 }
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(sut)
    }
}

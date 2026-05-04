import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardOverviewView

@MainActor
final class DashboardOverviewViewTests: XCTestCase {

    func test_rendersWithData() throws {
        let view = makeOverviewView()
        XCTAssertNoThrow(try view.inspect())
    }

    private func makeOverviewView() -> some View {
        let store = try! DataStoreCoordinator(databaseQueue: DatabaseQueue(), refreshOnInit: false)
        let settingsManager = SettingsManager(defaults: UserDefaults(suiteName: #file)!)
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        let layer = OpenBurnBarOperatingLayer(dataStore: store, settingsManager: settingsManager)
        let context = DashboardContext(
            dataStore: store,
            settingsManager: settingsManager,
            operatingLayer: layer,
            chatController: controller,
            navigationCoordinator: NavigationCoordinator()
        )
        let providerSummary = ProviderSummary(
            provider: .factory,
            totalCost: 1.23,
            totalTokens: 1000,
            totalInputTokens: 600,
            totalOutputTokens: 400,
            sessionCount: 5,
            modelBreakdown: [],
            provenanceConfidence: .exact,
            provenanceMethod: .providerLog,
            hasEstimatedContributions: false,
            cacheEfficiency: .zero
        )
        let modelSummary = ModelSummary(
            modelName: "claude-3-opus",
            displayName: "Claude 3 Opus",
            totalCost: 1.23,
            totalTokens: 1000,
            totalInputTokens: 600,
            totalOutputTokens: 400,
            sessionCount: 5,
            providerBreakdown: [],
            cacheEfficiency: .zero
        )
        return DashboardOverviewView(
            providerSummaries: [providerSummary],
            modelSummaries: [modelSummary],
            topModels: [(model: "claude-3-opus", provider: .factory, cost: 1.23, tokens: 1000)],
            filteredUsages: ViewTestFixtures.makeWeekOfUsages(),
            context: context,
            overviewAppeared: true,
            onNavigate: { _ in },
            onOpenSettings: {}
        )
        .environment(settingsManager)
    }
}

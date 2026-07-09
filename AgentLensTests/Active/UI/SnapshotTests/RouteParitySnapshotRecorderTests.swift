import XCTest
import SwiftUI
import GRDB
@testable import OpenBurnBar

// MARK: - Route visual parity recorder
//
// Renders key macOS route surfaces into /tmp/openburnbar-ui-parity/macos/ so
// they can be compared with the Windows port. These are component-level
// captures; the real app shells add navigation chrome, but the visual
// vocabulary (glass, typography, logos, spacing) is preserved.

@MainActor
final class RouteParitySnapshotRecorderTests: XCTestCase {

    private let outputDir = "/tmp/openburnbar-ui-parity/macos"
    private let scale: CGFloat = 2.0

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(
            atPath: outputDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func shouldRecord() -> Bool {
        ProcessInfo.processInfo.environment["RECORD_ROUTE_PARITY"] == "1"
            || ProcessInfo.processInfo.environment["TEST_RUNNER_RECORD_ROUTE_PARITY"] == "1"
    }

    // MARK: - Helpers

    private func makeSettingsManager() -> SettingsManager {
        let defaults = UserDefaults(suiteName: "route-parity-\(UUID().uuidString)")!
        let settings = SettingsManager(defaults: defaults)
        settings.conversationIndexingConsentShown = true
        settings.sessionLogCloudBackupConsentShown = true
        settings.cliAssistantConsentShown = true
        settings.memoryConsentShown = true
        return settings
    }

    private func makeDashboardContext() throws -> DashboardContext {
        let store = try DataStoreCoordinator(databaseQueue: DatabaseQueue(), refreshOnInit: false)
        let settingsManager = makeSettingsManager()
        let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        let layer = OpenBurnBarOperatingLayer(dataStore: store, settingsManager: settingsManager)
        return DashboardContext(
            dataStore: store,
            settingsManager: settingsManager,
            operatingLayer: layer,
            chatController: controller,
            navigationCoordinator: NavigationCoordinator()
        )
    }

    private func makeProviderSummary(provider: AgentProvider = .factory) -> ProviderSummary {
        ProviderSummary(
            provider: provider,
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
    }

    private func makeModelSummary() -> ModelSummary {
        ModelSummary(
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
    }

    private func makeUsageWindow(context: DashboardContext) -> DashboardUsageWindowSummary {
        DashboardUsageWindowSummary(
            usages: ViewTestFixtures.makeWeekOfUsages(),
            totalCost: 1.23,
            totalTokens: 1000,
            sessionCount: 5,
            activeProviderCount: 1,
            providerSummaries: [makeProviderSummary()],
            modelSummaries: [makeModelSummary()],
            credentialSummaries: [],
            projectSpendSummaries: [],
            cacheEfficiency: .zero
        )
    }

    private func save(_ view: some View, named: String, size: CGSize, scheme: ColorScheme = .dark) {
        let image = renderViewSnapshot(view, size: size, colorScheme: scheme)
        let path = "\(outputDir)/\(named).png"
        guard let data = image.pngData(scale: scale) else {
            XCTFail("Failed to encode PNG for \(named)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("[RouteParity] wrote \(path)")
        } catch {
            XCTFail("Failed to write \(path): \(error)")
        }
    }

    // MARK: - Routes

    func test_recordDashboardHome() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        let providerSummary = makeProviderSummary()
        let modelSummary = makeModelSummary()
        let usageWindow = makeUsageWindow(context: context)
        let view = DashboardOverviewView(
            providerSummaries: [providerSummary],
            modelSummaries: [modelSummary],
            topModels: [(model: "claude-3-opus", provider: .factory, cost: 1.23, tokens: 1000)],
            usageWindow: usageWindow,
            context: context,
            overviewAppeared: true,
            onNavigate: { _ in },
            onOpenSettings: {}
        )
        .environment(context.settingsManager)
        .environment(context.navigationCoordinator)
        .background(DesignSystem.Colors.background)
        save(view, named: "macos-dashboard-home", size: CGSize(width: 900, height: 640))
    }

    func test_recordDashboardLayoutSwitcher() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        let view = DashboardLayoutSwitcher(
            selection: .constant(.aurora)
        )
        .padding(24)
        .background(DesignSystem.Colors.background)
        .environment(context.settingsManager)
        .environment(context.navigationCoordinator)
        save(view, named: "macos-dashboard-layout-switcher", size: CGSize(width: 520, height: 420))
    }

    func test_recordDashboardAurora() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        context.settingsManager.dashboardLayout = .aurora
        let view = DashboardView(context: context)
            .frame(width: 1200, height: 800)
            .environment(context.settingsManager)
            .environment(context.navigationCoordinator)
        save(view, named: "macos-dashboard-aurora", size: CGSize(width: 1200, height: 800))
    }

    func test_recordDashboardAtelier() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        context.settingsManager.dashboardLayout = .atelier
        UserDefaults.standard.set(true, forKey: "useKernelBackdrop")
        let view = DashboardView(context: context)
            .frame(width: 1200, height: 800)
            .environment(context.settingsManager)
            .environment(context.navigationCoordinator)
        save(view, named: "macos-dashboard-atelier", size: CGSize(width: 1200, height: 800))
    }

    func test_recordProviderQuota() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        let view = ProviderDashboardQuotaPanel(
            provider: .claudeCode,
            quotaService: ProviderQuotaService.shared,
            dataStore: context.dataStore
        )
        .padding(24)
        .background(DesignSystem.Colors.background)
        .environment(context.settingsManager)
        .environment(context.navigationCoordinator)
        save(view, named: "macos-provider-quota", size: CGSize(width: 520, height: 420))
    }

    func test_recordSettingsHome() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        let view = SettingsHomeView(
            settingsManager: context.settingsManager,
            accountManager: AccountManager.shared,
            dataStore: context.dataStore,
            daemonManager: OpenBurnBarDaemonManager(settingsManager: context.settingsManager),
            cloudSyncService: nil,
            runtimeContext: nil,
            router: nil
        )
        .background(DesignSystem.Colors.background)
        .environment(context.settingsManager)
        .environment(context.navigationCoordinator)
        save(view, named: "macos-settings-home", size: CGSize(width: 720, height: 640))
    }

    func test_recordSettingsAppearance() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let settings = makeSettingsManager()
        let view = AppearanceSettingsDetailView(settingsManager: settings)
            .background(DesignSystem.Colors.background)
            .environment(settings)
        save(view, named: "macos-settings-appearance", size: CGSize(width: 720, height: 640))
    }

    func test_recordSettingsDataSource() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let settings = makeSettingsManager()
        let view = DataRefreshSettingsDetailView(settingsManager: settings)
            .background(DesignSystem.Colors.background)
            .environment(settings)
        save(view, named: "macos-settings-data-source", size: CGSize(width: 720, height: 640))
    }

    func test_recordOnboardingProviders() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        let providers = Array(AgentProvider.allCases.prefix(6))
        let view = VStack(alignment: .leading, spacing: 12) {
            Text("Providers")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 12) {
                ForEach(providers, id: \.self) { provider in
                    OnboardingProviderPill(provider: provider, isSelected: true, isDetected: true, onTap: {})
                }
            }
        }
        .padding(24)
        .background(DesignSystem.Colors.background)
        .environment(context.settingsManager)
        .environment(context.navigationCoordinator)
        save(view, named: "macos-onboarding-providers", size: CGSize(width: 720, height: 520))
    }

    func test_recordChat() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        let controller = context.chatController
        controller.messages = [
            ViewTestFixtures.makeUserMessage(content: "What's my burn rate today?"),
            ViewTestFixtures.makeAssistantMessage(content: "You've spent $4.20 across 12 sessions so far today.")
        ]
        let view = ChatPanel(
            controller: controller,
            dataStore: context.dataStore,
            settingsManager: context.settingsManager,
            sharedFeaturesAvailable: true,
            containerSize: CGSize(width: 420, height: 520),
            edgePadding: 20,
            onMaximize: {},
            onPopOut: {},
            onClose: {}
        )
        .background(DesignSystem.Colors.background)
        .environment(context.settingsManager)
        .environment(context.navigationCoordinator)
        save(view, named: "macos-chat", size: CGSize(width: 420, height: 520))
    }

    func test_recordInsightsGallery() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        let view = MacAgentInsightsWorkspace(
            dataStore: context.dataStore,
            settingsManager: context.settingsManager,
            chatController: context.chatController
        )
        .frame(width: 1200, height: 760)
        .environment(context.settingsManager)
        .environment(context.navigationCoordinator)
        save(view, named: "macos-insights-gallery", size: CGSize(width: 1200, height: 760))
    }

    func test_recordMissionControl() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        let view = MissionsLaneView(
            operatingLayer: context.operatingLayer,
            onOpenSessionLogs: {}
        )
        .frame(width: 1200, height: 760)
        .environment(context.settingsManager)
        .environment(context.navigationCoordinator)
        save(view, named: "macos-mission-control", size: CGSize(width: 1200, height: 760))
    }

    func test_recordBudget() throws {
        try XCTSkipIf(!shouldRecord(), "Set RECORD_ROUTE_PARITY=1 to record")
        let context = try makeDashboardContext()
        let budgetRulesStore = BudgetRulesStore(dbQueue: context.dataStore.actor.dbQueue)
        let budgetSettings = BudgetSettings(
            store: budgetRulesStore,
            alertSettings: context.settingsManager.alerts,
            deviceID: "route-parity-device-id"
        )
        let view = BudgetSettingsView(budgetSettings: budgetSettings)
            .background(DesignSystem.Colors.background)
            .environment(context.settingsManager)
            .environment(context.navigationCoordinator)
        save(view, named: "macos-budget", size: CGSize(width: 720, height: 640))
    }
}

// MARK: - PNG export

extension NSImage {
    fileprivate func pngData(scale: CGFloat = 2.0) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        bitmap.size = NSSize(width: size.width, height: size.height)
        return bitmap.representation(using: .png, properties: [.compressionFactor: 1.0])
    }
}

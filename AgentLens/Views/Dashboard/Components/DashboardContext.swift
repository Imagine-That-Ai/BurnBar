import SwiftUI

/// Bundles the shared dependencies that flow through the dashboard view hierarchy.
///
/// Replaces the pattern of passing 8-10 individual parameters through every
/// dashboard view layer. Constructed once in the app entry point and passed
/// into `DashboardView` / `WindowManager.openDashboard`.
@Observable
@MainActor
final class DashboardContext {
    let dataStore: DataStoreCoordinator
    let settingsManager: SettingsManager
    let accountManager: AccountManager
    let operatingLayer: OpenBurnBarOperatingLayer
    let chatController: ChatSessionController
    let navigationCoordinator: NavigationCoordinator
    let aggregator: UsageAggregator?
    let cloudSyncService: CloudSyncService?
    let iCloudSessionMirrorService: ICloudSessionMirrorService?

    init(
        dataStore: DataStoreCoordinator,
        settingsManager: SettingsManager,
        accountManager: AccountManager = .shared,
        operatingLayer: OpenBurnBarOperatingLayer,
        chatController: ChatSessionController,
        navigationCoordinator: NavigationCoordinator,
        aggregator: UsageAggregator? = nil,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.accountManager = accountManager
        self.operatingLayer = operatingLayer
        self.chatController = chatController
        self.navigationCoordinator = navigationCoordinator
        self.aggregator = aggregator
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
    }
}

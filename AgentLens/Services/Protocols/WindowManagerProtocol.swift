import AppKit
import SwiftUI

// MARK: - WindowManagerProtocol

/// Protocol defining the window management interface.
/// This enables dependency injection and testing of window-related functionality.
///
/// ## Usage
/// ```swift
/// struct MyComponent {
///     var windowManager: any WindowManagerProtocol
/// }
/// ```
///
/// For production use, `WindowManager.shared` conforms to this protocol.
/// For testing, inject a mock implementation.
@MainActor
protocol WindowManagerProtocol: AnyObject {

    // MARK: - Dashboard Window

    /// Opens the main dashboard window.
    /// - Parameters:
    ///   - dataStore: The data store instance.
    ///   - aggregator: Optional usage aggregator.
    ///   - accountManager: The account manager.
    ///   - cloudSyncService: Optional cloud sync service.
    ///   - iCloudSessionMirrorService: Optional iCloud mirror service.
    ///   - chatController: The chat session controller.
    ///   - operatingLayer: The operating layer.
    ///   - navigationCoordinator: The navigation coordinator.
    ///   - settingsManager: The settings manager injected into dashboard descendants.
    func openDashboard(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        accountManager: AccountManager,
        cloudSyncService: CloudSyncService?,
        iCloudSessionMirrorService: ICloudSessionMirrorService?,
        chatController: ChatSessionController,
        operatingLayer: OpenBurnBarOperatingLayer,
        navigationCoordinator: NavigationCoordinator,
        settingsManager: SettingsManager
    )

    // MARK: - Settings Window

    /// Opens the settings window.
    /// - Parameters:
    ///   - settingsManager: The settings manager.
    ///   - accountManager: The account manager.
    ///   - cloudSyncService: Optional cloud sync service.
    ///   - iCloudSessionMirrorService: Optional iCloud mirror service.
    ///   - dataStore: The data store instance.
    func openSettings(
        settingsManager: SettingsManager,
        accountManager: AccountManager,
        cloudSyncService: CloudSyncService?,
        iCloudSessionMirrorService: ICloudSessionMirrorService?,
        dataStore: DataStore
    )

    // MARK: - Onboarding Wizard

    /// Opens the onboarding wizard window.
    /// - Parameters:
    ///   - dataStore: The data store instance.
    ///   - aggregator: Optional usage aggregator.
    ///   - settingsManager: The settings manager.
    ///   - chatController: Optional chat session controller.
    ///   - onOpenDashboard: Closure called when user wants to open dashboard.
    func openOnboardingWizard(
        dataStore: DataStore,
        aggregator: UsageAggregator?,
        settingsManager: SettingsManager,
        chatController: ChatSessionController?,
        onOpenDashboard: @escaping () -> Void
    )

    // MARK: - Switcher Onboarding Wizard

    /// Opens the account switcher onboarding wizard window.
    /// - Parameters:
    ///   - dataStore: The data store instance.
    ///   - settingsManager: The settings manager.
    ///   - onOpenSettings: Closure called when user wants to open settings.
    func openSwitcherOnboardingWizard(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        onOpenSettings: @escaping () -> Void
    )
}

// MARK: - WindowManager Extension

extension WindowManager: WindowManagerProtocol {}

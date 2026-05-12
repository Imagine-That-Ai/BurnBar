import AppKit
import AuthenticationServices
import OpenBurnBarCore
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    var dataStore: DataStore
    var runtimeContext: OpenBurnBarRuntimeContext?
    @Environment(\.dismiss) private var dismiss
    @State private var router = SettingsRouter()
    @State private var presentationWindow: NSWindow?

    init(
        settingsManager: SettingsManager,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil,
        dataStore: DataStore,
        runtimeContext: OpenBurnBarRuntimeContext? = nil
    ) {
        self._settingsManager = Bindable(settingsManager)
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self.dataStore = dataStore
        self.runtimeContext = runtimeContext
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.top, DesignSystem.Spacing.sm)
                    .padding(.bottom, DesignSystem.Spacing.xs)

                List(SettingsTab.allCases, selection: $router.selectedTab) { tab in
                    NavigationLink(value: tab) {
                        sidebarRow(for: tab)
                    }
                    .tag(tab)
                }
                .listStyle(.sidebar)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            NavigationStack(path: $router.path) {
                Group {
                    if router.isSearching {
                        SettingsSearchResultsView(router: router)
                    } else {
                        detailContent
                    }
                }
                .navigationDestination(for: SettingsPageRoute.self) { route in
                    destination(for: route)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .id(router.selectedTab)
            .environment(router)
        }
        .frame(
            minWidth: 820,
            idealWidth: 980,
            minHeight: 600,
            idealHeight: 720
        )
        .preferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
        .environment(settingsManager)
        .background(SettingsWindowReader(window: $presentationWindow))
    }

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            TextField("Search settings", text: $router.query)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .accessibilityLabel("Search settings")
            if router.isSearching {
                Button {
                    router.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    private func sidebarRow(for tab: SettingsTab) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tab.accentColor)
                    .frame(width: 28, height: 28)
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(tab.subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// Build the deep-link destination for a programmatic push from the
    /// search router. Each branch instantiates the same detail view that the
    /// natural drill-down would.
    @ViewBuilder
    private func destination(for route: SettingsPageRoute) -> some View {
        switch route {
        case .operatorModel:
            OperatorModelDetailView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                setupGuide: setupGuideSnapshot
            )
        case .appearance:
            AppearanceSettingsDetailView(settingsManager: settingsManager)
        case .defaultView:
            DefaultViewSettingsDetailView(settingsManager: settingsManager)
        case .dataRefresh:
            DataRefreshSettingsDetailView(settingsManager: settingsManager)
        case .indexing:
            IndexingOverviewDetailView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                sharedFeaturesAvailable: accountManager.isSignedIn
            )
        case .sessionSummaries:
            SessionSummariesDetailView(settingsManager: settingsManager)
        case .daemonLifecycle:
            DaemonLifecycleDetailView(daemonManager: .shared)
        case .httpGateway:
            HTTPGatewayDetailView(settingsManager: settingsManager)
        case .controllerRuntime:
            ControllerRuntimeDetailView(settingsManager: settingsManager)
        case .generalRoot, .daemonRoot, .accountRoot, .providersRoot,
             .alertsRoot, .notificationsRoot, .devicesAndSyncRoot,
             .switcherRoot, .hermesRoot:
            // Roots are reachable via the sidebar tab selection — the path
            // stays empty for these.
            detailContent
        }
    }

    private var setupGuideSnapshot: OpenBurnBarSetupGuideSnapshot {
        OpenBurnBarSetupGuideBuilder.build(
            detection: settingsManager.detectAvailableProviders(),
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            isSignedIn: accountManager.isSignedIn,
            conversationCloudEnabled: settingsManager.conversationCloudBackupEnabled,
            iCloudMirrorEnabled: settingsManager.iCloudSessionMirrorEnabled
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        switch router.selectedTab ?? .general {
        case .general:
            GeneralSettingsView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                sharedFeaturesAvailable: accountManager.isSignedIn,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService
            )
                .navigationTitle("General")
        case .daemon:
            DaemonSettingsView(settingsManager: settingsManager, dataStore: dataStore)
                .navigationTitle("Daemon")
        case .account:
            AccountSettingsView(
                currentUser: accountManager.currentUser,
                isAnonymous: accountManager.isAnonymousUser,
                isFirebaseAvailable: accountManager.isFirebaseAvailable,
                onLinkGoogle: {
                    try await accountManager.signInWithGoogle(presentingWindow: authPresentationWindow())
                },
                onEmailSignIn: { email, password in
                    try await accountManager.signInWithEmail(email: email, password: password)
                },
                onEmailSignUp: { email, password in
                    try await accountManager.signUpWithEmail(email: email, password: password)
                },
                onLinkApple: {
                    try await accountManager.signInWithApple(presentingWindow: authPresentationWindow())
                },
                onUpgradeToPremium: {
                    if let url = URL(string: "https://apps.apple.com/app/id6766366964") {
                        NSWorkspace.shared.open(url)
                    }
                },
                onDeleteAccount: {
                    Task { @MainActor in
                        try? await accountManager.deleteCurrentUser()
                    }
                },
                onSignOut: {
                    try? accountManager.signOut()
                }
            )
            .navigationTitle("Account")
        case .providers:
            ProvidersSettingsView(
                settingsManager: settingsManager,
                daemonManager: .shared,
                dataStore: dataStore,
                accountManager: accountManager
            )
                .navigationTitle("Providers")
        case .alerts:
            AlertsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Alerts")
        case .notifications:
            NotificationsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Notifications")
        case .devicesAndSync:
            DevicesAndSyncSettingsView(
                settingsManager: settingsManager,
                runtimeContext: runtimeContext
            )
                .navigationTitle(MacCopy.devicesAndSyncTitle)
        case .switcher:
            AccountSwitcherSettingsView(
                dataStore: dataStore,
                settingsManager: settingsManager
            )
                .navigationTitle("Account Switcher")
        case .hermes:
            ChatGatewaySettingsView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService
            )
                .navigationTitle("Hermes")
        }
    }

    private func authPresentationWindow() throws -> NSWindow {
        let candidates = [presentationWindow, NSApp.keyWindow, NSApp.mainWindow]
            + NSApp.windows.filter { $0.title == "Settings" || $0.isVisible }
        guard let window = candidates.compactMap({ $0 }).first(where: { $0.isVisible && !$0.isMiniaturized }) else {
            throw AccountActionError.missingPresentationWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}


private struct SettingsWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if window !== view.window {
                window = view.window
            }
        }
    }
}
private enum AccountActionError: LocalizedError {
    case missingPresentationWindow

    var errorDescription: String? {
        switch self {
        case .missingPresentationWindow:
            return "OpenBurnBar could not find a window to present the sign-in flow."
        }
    }
}

#Preview {
    let store = (try? DataStore()) ?? {
        preconditionFailure("Preview requires a valid DataStore - ensure app support directory is writable")
    }()
    SettingsView(settingsManager: SettingsManager(), dataStore: store)
}

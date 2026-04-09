import AppKit
import AuthenticationServices
import OpenBurnBarCore
@preconcurrency import FirebaseAuth
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab? = .general

    init(
        settingsManager: SettingsManager,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil,
        dataStore: DataStore
    ) {
        self._settingsManager = Bindable(settingsManager)
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self.dataStore = dataStore
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab.accentColor)
                            .frame(width: 26, height: 26)
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detailContent
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(
            minWidth: 780,
            idealWidth: 920,
            minHeight: 560,
            idealHeight: 660
        )
        .preferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab ?? .general {
        case .general:
            GeneralSettingsView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                sharedFeaturesAvailable: accountManager.isSignedIn
            )
                .navigationTitle("General")
        case .daemon:
            DaemonSettingsView(settingsManager: settingsManager, dataStore: dataStore)
                .navigationTitle("Daemon")
        case .account:
            AccountSettingsView(
                currentUser: Auth.auth().currentUser,
                isAnonymous: Auth.auth().currentUser?.isAnonymous ?? true,
                onLinkGoogle: {
                    Task { @MainActor in
                        guard let window = NSApp.keyWindow else { return }
                        try? await accountManager.signInWithGoogle(presentingWindow: window)
                    }
                },
                onLinkEmail: { email, password in
                    Task { @MainActor in
                        try? await Auth.auth().signIn(withEmail: email, password: password)
                    }
                },
                onLinkApple: {
                    Task { @MainActor in
                        guard let window = NSApp.keyWindow else { return }
                        try? await accountManager.signInWithApple(presentingWindow: window)
                    }
                },
                onUpgradeToPremium: {},
                onDeleteAccount: {
                    Task { @MainActor in
                        guard let user = Auth.auth().currentUser else { return }
                        try? await user.delete()
                    }
                },
                onSignOut: {
                    try? accountManager.signOut()
                }
            )
            .navigationTitle("Account")
        case .providers:
            ProvidersSettingsView(settingsManager: settingsManager, daemonManager: .shared)
                .navigationTitle("Providers")
        case .alerts:
            AlertsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Alerts")
        case .notifications:
            NotificationsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Notifications")
        case .switcher:
            AccountSwitcherSettingsView(dataStore: dataStore)
                .navigationTitle("Account Switcher")
        }
    }
}

#Preview {
    let store = (try? DataStore()) ?? {
        preconditionFailure("Preview requires a valid DataStore - ensure app support directory is writable")
    }()
    return SettingsView(settingsManager: SettingsManager.shared, dataStore: store)
}

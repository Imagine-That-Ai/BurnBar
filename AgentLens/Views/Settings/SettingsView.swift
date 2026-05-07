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
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab? = .general
    @State private var presentationWindow: NSWindow?

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
        .environment(settingsManager)
        .background(SettingsWindowReader(window: $presentationWindow))
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab ?? .general {
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
                    if let url = URL(string: "macappstore://apps.apple.com/app/idYOUR_APP_ID") {
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
            ProvidersSettingsView(settingsManager: settingsManager, daemonManager: .shared, dataStore: dataStore)
                .navigationTitle("Providers")
        case .alerts:
            AlertsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Alerts")
        case .notifications:
            NotificationsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Notifications")
        case .devicesAndSync:
            DevicesAndSyncSettingsView()
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

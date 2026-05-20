import SwiftUI
import OpenBurnBarCore
#if canImport(UIKit)
import UIKit
#endif
#if DEBUG
import FirebaseAuth
import OSLog
#endif

/// Top-level routing based on auth state.
/// Branches between iPhone (`RootTabView`) and iPad (`RootNavigationView`) layouts.
struct AuthGateView: View {
    #if DEBUG
    private static let hermesE2ELogger = Logger(subsystem: "com.openburnbar.mobile", category: "HermesE2E")
    #endif

    @State private var authStore = AuthStore()
    @State private var syncHealthStore = CloudSyncHealthStore()
    @State private var providerSummaryStore = ProviderSummaryStore()
    @State private var devicesStore = DevicesStore()
    @State private var transferStore = CredentialTransferStore()

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("uiMode") private var uiMode: String = UIMode.standard.rawValue

    var body: some View {
        Group {
            if AppStoreScreenshotMode.isEnabled {
                mainSignedInView
            } else {
                #if DEBUG
                if MobileE2ERoute.isCloudStoreRoute {
                    MobileE2ECloudStoreRouteView()
                } else {
                    authStateView
                }
                #else
                authStateView
                #endif
            }
        }
        .animation(.snappy(duration: 0.25), value: authStore.state)
        .environment(\.uiMode, UIMode(rawValue: uiMode) ?? .standard)
        #if DEBUG
        .onAppear {
            logHermesE2EAuthState("auth-gate-appeared")
        }
        .onChange(of: authStore.state) { _, _ in
            logHermesE2EAuthState("auth-state-changed")
        }
        #endif
    }

    @ViewBuilder
    private var authStateView: some View {
        switch authStore.state {
        case .firebaseUnavailable:
            FirebaseUnavailableScene()
        case .signedOut, .signingIn, .firestoreUnavailable:
            SignInScene(authStore: authStore)
        case .signedIn, .deletingAccount:
            signedInView
        }
    }

    // MARK: - Device-Specific Root

    @ViewBuilder
    private var signedInView: some View {
        #if DEBUG
        if MobileE2ERoute.isCloudStoreRoute {
            NavigationStack {
                CloudStoreView()
            }
        } else {
            signedInRootWithOnboarding
        }
        #else
        signedInRootWithOnboarding
        #endif
    }

    private var signedInRootWithOnboarding: some View {
        mainSignedInView
            .fullScreenCover(isPresented: Binding(
                get: { !hasCompletedOnboarding },
                set: { hasCompletedOnboarding = !$0 }
            )) {
                // Both iPhone and iPad use the same provider-connection
                // wizard — `OnboardingWizardView` adapts its gutter
                // padding via `horizontalSizeClass`.
                OnboardingWizardView(isPresented: Binding(
                    get: { !hasCompletedOnboarding },
                    set: { hasCompletedOnboarding = !$0 }
                ))
            }
    }

    @ViewBuilder
    private var mainSignedInView: some View {
        // Keep iPhone on the tab root across rotation. Some large iPhones report
        // a regular horizontal size class in landscape, and swapping root views
        // tears down live full-screen Mercury sessions.
        if shouldUseSidebarRoot {
            RootNavigationView(
                authStore: authStore,
                syncHealthStore: syncHealthStore,
                providerSummaryStore: providerSummaryStore,
                devicesStore: devicesStore,
                transferStore: transferStore
            )
        } else {
            RootTabView(
                authStore: authStore,
                syncHealthStore: syncHealthStore,
                providerSummaryStore: providerSummaryStore,
                devicesStore: devicesStore,
                transferStore: transferStore
            )
        }
    }

    private var shouldUseSidebarRoot: Bool {
        #if canImport(UIKit)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        #endif
        return horizontalSizeClass == .regular
    }

    #if DEBUG
    private func logHermesE2EAuthState(_ context: String) {
        guard hasHermesE2EPrompt else { return }
        print("OpenBurnBarMobile Hermes E2E auth \(context) state=\(authStateLabel(authStore.state)) onboardingComplete=\(hasCompletedOnboarding) horizontalSizeClass=\(horizontalSizeClassLabel)")
        Self.hermesE2ELogger.info("Hermes E2E \(context, privacy: .public) authState=\(authStateLabel(authStore.state), privacy: .public) onboardingComplete=\(hasCompletedOnboarding, privacy: .public) horizontalSizeClass=\(horizontalSizeClassLabel, privacy: .public)")
    }

    private var hasHermesE2EPrompt: Bool {
        let prompt = ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_HERMES_PROMPT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt?.isEmpty == false
    }

    private var horizontalSizeClassLabel: String {
        switch horizontalSizeClass {
        case .compact:
            return "compact"
        case .regular:
            return "regular"
        case nil:
            return "nil"
        @unknown default:
            return "unknown"
        }
    }

    private func authStateLabel(_ state: AuthState) -> String {
        switch state {
        case .signedOut:
            return "signedOut"
        case .signingIn:
            return "signingIn"
        case .signedIn:
            return "signedIn"
        case .deletingAccount:
            return "deletingAccount"
        case .firebaseUnavailable:
            return "firebaseUnavailable"
        case .firestoreUnavailable:
            return "firestoreUnavailable"
        }
    }
    #endif
}

#if DEBUG
private struct MobileE2ECloudStoreRouteView: View {
    @State private var isSignedIn = Auth.auth().currentUser != nil
    @State private var authHandle: AuthStateDidChangeListenerHandle?
    @State private var subscriptionStore = HostedQuotaSubscriptionStore(
        isSignedIn: { Auth.auth().currentUser != nil }
    )

    var body: some View {
        Group {
            if isSignedIn {
                NavigationStack {
                    CloudStoreView()
                }
                .environment(\.cloudSubscriptionStore, subscriptionStore)
            } else {
                ProgressView()
                    .accessibilityIdentifier("cloudStore.e2e.waitingForAuth")
            }
        }
        .onAppear {
            guard authHandle == nil else { return }
            authHandle = Auth.auth().addStateDidChangeListener { _, user in
                Task { @MainActor in
                    isSignedIn = user != nil
                }
            }
        }
        .task(id: isSignedIn) {
            if isSignedIn {
                await subscriptionStore.load()
            }
        }
        .onDisappear {
            if let authHandle {
                Auth.auth().removeStateDidChangeListener(authHandle)
                self.authHandle = nil
            }
        }
    }
}
#endif

import SwiftUI
import OpenBurnBarCore
#if DEBUG
import FirebaseAuth
#endif

/// Top-level routing based on auth state.
/// Branches between iPhone (`RootTabView`) and iPad (`RootNavigationView`) layouts.
struct AuthGateView: View {
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
        // Use horizontalSizeClass for runtime adaptivity on iPad in Split View / Stage Manager
        if horizontalSizeClass == .regular {
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

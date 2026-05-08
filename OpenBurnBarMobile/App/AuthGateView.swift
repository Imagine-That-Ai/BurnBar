import SwiftUI
import OpenBurnBarCore

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
                switch authStore.state {
                case .firebaseUnavailable:
                    FirebaseUnavailableScene()
                case .signedOut, .signingIn, .firestoreUnavailable:
                    SignInScene(authStore: authStore)
                case .signedIn:
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
            }
        }
        .animation(.snappy(duration: 0.25), value: authStore.state)
        .environment(\.uiMode, UIMode(rawValue: uiMode) ?? .standard)
    }

    // MARK: - Device-Specific Root

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

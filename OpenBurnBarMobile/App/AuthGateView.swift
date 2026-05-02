import SwiftUI
import OpenBurnBarCore

/// Top-level routing based on auth state.
struct AuthGateView: View {
    @State private var authStore = AuthStore()
    @State private var syncHealthStore = CloudSyncHealthStore()
    @State private var providerSummaryStore = ProviderSummaryStore()
    @State private var devicesStore = DevicesStore()
    @State private var transferStore = CredentialTransferStore()

    var body: some View {
        Group {
            switch authStore.state {
            case .firebaseUnavailable:
                FirebaseUnavailableScene()
            case .signedOut, .signingIn, .firestoreUnavailable:
                SignInScene(authStore: authStore)
            case .signedIn:
                RootTabView(
                    authStore: authStore,
                    syncHealthStore: syncHealthStore,
                    providerSummaryStore: providerSummaryStore,
                    devicesStore: devicesStore,
                    transferStore: transferStore
                )
            }
        }
        .animation(.snappy(duration: 0.25), value: authStore.state)
    }
}

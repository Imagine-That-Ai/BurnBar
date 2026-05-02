import SwiftUI

/// Root tab navigation shown when signed in.
/// Wraps existing views. Gateway stores available for future view wiring.
struct RootTabView: View {
    let authStore: AuthStore
    let syncHealthStore: CloudSyncHealthStore
    let providerSummaryStore: ProviderSummaryStore
    let devicesStore: DevicesStore
    let transferStore: CredentialTransferStore

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar.fill") }

            QuotaView()
                .tabItem { Label("Quota", systemImage: "gauge.with.dots.needle.67percent") }

            ActivityView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }

            AccountView()
                .tabItem { Label("Account", systemImage: "person.fill") }
        }
    }
}

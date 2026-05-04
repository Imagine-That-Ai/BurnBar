import SwiftUI
import OpenBurnBarCore

/// Root tab navigation shown when signed in.
/// iOS 18+: uses value-based `Tab` API with `Tab(role: .search)`.
/// iOS 17: falls back to `.tabItem`.
struct RootTabView: View {
    let authStore: AuthStore
    let syncHealthStore: CloudSyncHealthStore
    let providerSummaryStore: ProviderSummaryStore
    let devicesStore: DevicesStore
    let transferStore: CredentialTransferStore

    @State private var selectedTab: TabSelection = .dashboard

    enum TabSelection: Hashable {
        case dashboard, quota, activity, account, search
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            modernTabView
        } else {
            legacyTabView
        }
    }

    // MARK: - iOS 18+ Modern Tabs

    @available(iOS 18.0, *)
    @ViewBuilder
    private var modernTabView: some View {
        if #available(iOS 26.0, *) {
            modernTabContent
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            modernTabContent
        }
    }

    @available(iOS 18.0, *)
    private var modernTabContent: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "chart.bar.fill", value: .dashboard) {
                DashboardView()
            }

            Tab("Quota", systemImage: "gauge.with.dots.needle.67percent", value: .quota) {
                QuotaView()
            }

            Tab("Activity", systemImage: "list.bullet.rectangle", value: .activity) {
                ActivityView()
            }

            Tab("Account", systemImage: "person.fill", value: .account) {
                AccountView()
            }

            Tab(value: .search, role: .search) {
                SessionLogsView()
            }
        }
    }

    // MARK: - iOS 17 Legacy Tabs

    private var legacyTabView: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar.fill") }
                .tag(TabSelection.dashboard)

            QuotaView()
                .tabItem { Label("Quota", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(TabSelection.quota)

            ActivityView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(TabSelection.activity)

            AccountView()
                .tabItem { Label("Account", systemImage: "person.fill") }
                .tag(TabSelection.account)
        }
    }
}

#Preview {
    RootTabView(
        authStore: AuthStore(),
        syncHealthStore: CloudSyncHealthStore(),
        providerSummaryStore: ProviderSummaryStore(),
        devicesStore: DevicesStore(),
        transferStore: CredentialTransferStore()
    )
}

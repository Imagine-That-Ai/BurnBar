import SwiftUI
import OpenBurnBarInboxModels
import OpenBurnBarKernel
import OpenBurnBarQuota
import OpenBurnBarUI

/// You decision rail: grouped settings, not the full-bleed iPhone You page.
struct IPadYouRail: View {
    let authStore: AuthStore
    @Binding var selectedGroup: IPadAwayDeskNavigation.YouGroup
    var searchQuery: String = ""

    private var groups: [IPadAwayDeskNavigation.YouGroup] {
        IPadAwayDeskNavigation.filteredYouGroups(searchQuery)
    }

    var body: some View {
        List {
                Section {
                    ForEach(groups) { group in
                        Button {
                            selectedGroup = group
                            HapticBus.tabChange()
                        } label: {
                            IPadYouGroupRow(
                                group: group,
                                isSelected: selectedGroup == group
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("ipad.you.group.\(group.rawValue)")
                    }
                }

                Section {
                    if authStore.state.isSignedIn {
                        Button("Sign out", role: .destructive) {
                            Task { await authStore.signOut() }
                        }
                        .accessibilityIdentifier("ipad.you.signOut")
                    } else {
                        Text("Sign in from Cloud to sync this iPad.")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("ipad.you.rail")
    }
}

struct IPadYouCanvas: View {
    let authStore: AuthStore
    let syncStore: CloudSyncHealthStore
    let devicesStore: DevicesStore
    let hermesService: HermesService
    let selectedGroup: IPadAwayDeskNavigation.YouGroup
    let settingsRouter: SettingsRouter

    var body: some View {
        NavigationStack {
            Group {
                switch selectedGroup {
                case .pairing:
                    HermesSettingsView(service: hermesService, authStore: authStore)
                case .keepAwake:
                    IPadYouKeepAwakeCanvas()
                case .devices:
                    iPadDevicesSettingsView(store: devicesStore, hermesService: hermesService)
                case .cloud:
                    CloudStoreView()
                case .appearance:
                    ThemeSettingsView()
                        .navigationTitle("Appearance")
                        .navigationBarTitleDisplayMode(.inline)
                case .dataVault:
                    DataVaultAdaptiveControlView()
                case .labs:
                    IPadYouLabsCanvas()
                }
            }
            .navigationDestination(for: YouRoute.self) { route in
                youRoute(route)
            }
            .navigationDestination(for: SettingsPageRoute.self) { route in
                SettingsHubView.destination(for: route, authStore: authStore)
                    .environment(settingsRouter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("ipad.you.canvas")
        }
        .environment(settingsRouter)
    }

    @ViewBuilder
    private func youRoute(_ route: YouRoute) -> some View {
        youRouteView(
            route,
            authStore: authStore,
            syncStore: syncStore,
            devicesStore: devicesStore,
            hermesService: hermesService,
            settingsRouter: settingsRouter
        )
    }
}

private struct IPadYouGroupRow: View {
    let group: IPadAwayDeskNavigation.YouGroup
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: group.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textMuted)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(group.subtitle)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Spacer()
            if isSelected {
                Circle()
                    .fill(MobileTheme.Colors.textPrimary)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .iPadDeskRowBackground(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

}

private struct IPadYouKeepAwakeCanvas: View {
    @ObservedObject private var hostReachability = HostReachabilityClient.shared

    var body: some View {
        List {
            Section {
                KeepAwakeHostCard(client: hostReachability)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } footer: {
                Text("Live Watch, Mirror, or iroh sessions auto-arm the Mac. This switch is sticky until you turn it off. It never overrides lock, loginwindow, or panic-on-sleep.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Keep Mac awake")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ipad.you.keepAwake")
    }
}

/// Reachable destinations that left the sidebar. No Grokd.
private struct IPadYouLabsCanvas: View {
    var body: some View {
        List {
            Section {
                labRow(
                    title: "Insights",
                    subtitle: "Agent patterns, budgets, monthly recap",
                    icon: "sparkles.tv.fill",
                    identifier: "ipad.you.labs.insights"
                ) {
                    InsightsDeepLink.open()
                }
                labRow(
                    title: "Pulse",
                    subtitle: "Live spend and forecast",
                    icon: "waveform.path.ecg",
                    identifier: "ipad.you.labs.pulse"
                ) {
                    NotificationCenter.default.post(name: .init("NavigateToDashboard"), object: nil)
                }
                labRow(
                    title: "Streams",
                    subtitle: "Sessions, projects, activity",
                    icon: "list.bullet.rectangle.portrait.fill",
                    identifier: "ipad.you.labs.streams"
                ) {
                    NotificationCenter.default.post(name: .init("ShowStreamsTab"), object: nil)
                }
                labRow(
                    title: "Recap",
                    subtitle: "Your last completed month",
                    icon: "calendar.badge.clock",
                    identifier: "ipad.you.labs.recap"
                ) {
                    NotificationCenter.default.post(name: .init("ShowRecap"), object: nil)
                }
            } header: {
                Text("Reachable from You")
            } footer: {
                Text("Watch stays in the inspector. Keep Mac awake is its own You group.")
            }
        }
        .navigationTitle("Labs")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ipad.you.labs")
    }

    private func labRow(
        title: String,
        subtitle: String,
        icon: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MobileTheme.whimsy)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier(identifier)
    }
}

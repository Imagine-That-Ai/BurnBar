import SwiftUI

// MARK: - Settings Search Results View

/// Detail-pane view shown whenever the sidebar search field is non-empty.
/// Renders ranked matches from `SettingsSearchEngine` as tappable
/// `SettingsDrillRow`s. Tapping a row asks `SettingsRouter` to navigate to
/// the underlying control.
struct SettingsSearchResultsView: View {
    @Bindable var router: SettingsRouter
    let items: [SettingsItem]

    init(router: SettingsRouter, items: [SettingsItem] = SettingsManifest.all) {
        self._router = Bindable(router)
        self.items = items
    }

    var body: some View {
        let results = SettingsSearchEngine.search(router.query, in: items)

        Group {
            if results.isEmpty {
                emptyState
            } else {
                resultsList(results)
            }
        }
        .background(DesignSystem.Colors.background)
        .navigationTitle("Search")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Showing \(results.count) settings results")
    }

    @ViewBuilder
    private func resultsList(_ results: [SettingsItem]) -> some View {
        List {
            Section {
                ForEach(results) { item in
                    Button {
                        router.navigate(to: item)
                    } label: {
                        SettingsDrillRow(
                            icon: item.tab.icon,
                            iconTint: item.tab.accentColor,
                            title: item.title,
                            subtitle: item.subtitle,
                            value: breadcrumb(for: item)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens \(breadcrumb(for: item))")
                }
            } header: {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            VStack(spacing: DesignSystem.Spacing.xs) {
                Text("No settings match \u{201C}\(router.query)\u{201D}")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Try a broader term, or browse the sidebar.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Button("Browse all") {
                router.reset()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(DesignSystem.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Breadcrumb of the form "Tab › Page" for display in the result row.
    private func breadcrumb(for item: SettingsItem) -> String {
        let pageLabel = pageDisplayName(item.pageRoute)
        if pageLabel.isEmpty { return item.tab.title }
        return "\(item.tab.title) › \(pageLabel)"
    }

    private func pageDisplayName(_ route: SettingsPageRoute) -> String {
        switch route {
        case .generalRoot, .daemonRoot, .accountRoot, .providersRoot,
             .alertsRoot, .notificationsRoot, .devicesAndSyncRoot,
             .switcherRoot, .hermesRoot:
            return ""
        case .operatorModel: return "Operator Model"
        case .appearance: return "Appearance"
        case .defaultView: return "Dashboard Defaults"
        case .dataRefresh: return "Data Refresh"
        case .indexing: return "Indexing & Search"
        case .sessionSummaries: return "Session Summaries"
        case .daemonLifecycle: return "Lifecycle"
        case .httpGateway: return "HTTP Gateway"
        case .controllerRuntime: return "Controller Runtime"
        }
    }
}

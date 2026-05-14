import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Search Results View (iOS)

/// Replaces the Settings hub Form whenever the `.searchable` field is
/// active. Renders ranked matches as Aurora-styled rows; tapping a row
/// asks `SettingsRouter` to drive navigation.
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
                        resultRow(for: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens \(breadcrumb(for: item))")
                }
            } header: {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func resultRow(for item: SettingsItem) -> some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            if !item.logoProviders.isEmpty {
                SettingsProviderLogoStack(providers: item.logoProviders, size: 28, maxVisible: 4)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(2)
                }
                Text(breadcrumb(for: item))
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            Spacer(minLength: MobileTheme.Spacing.sm)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .contentShape(Rectangle())
        .padding(.vertical, MobileTheme.Spacing.xs)
    }

    private var emptyState: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(MobileTheme.Colors.textMuted)

            VStack(spacing: MobileTheme.Spacing.xs) {
                Text("No settings match \u{201C}\(router.query)\u{201D}")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("Try a broader term, or browse the list.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }

            Button("Browse all") {
                router.reset()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(MobileTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func breadcrumb(for item: SettingsItem) -> String {
        let page = pageDisplayName(item.pageRoute)
        if page.isEmpty { return item.section.title }
        return "\(item.section.title) › \(page)"
    }

    private func pageDisplayName(_ route: SettingsPageRoute) -> String {
        switch route {
        case .hubRoot: return ""
        case .cloud: return "Cloud"
        case .providerConnections: return "Providers"
        case .hermes: return "Hermes"
        case .pi: return "Pi"
        case .chatTiles: return "Chat tiles"
        }
    }
}

// MARK: - Provider Logo Stack

struct SettingsProviderLogoStack: View {
    let providers: [AgentProvider]
    var size: CGFloat = 28
    var maxVisible: Int = 4

    private var visibleProviders: [AgentProvider] {
        Array(providers.prefix(maxVisible))
    }

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(visibleProviders) { provider in
                ProviderAvatar(provider: provider, mode: .plain, size: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                            .fill(MobileTheme.Colors.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                            .stroke(MobileTheme.Colors.border.opacity(0.70), lineWidth: 0.8)
                    )
            }
        }
        .frame(width: stackWidth, height: size, alignment: .leading)
    }

    private var stackWidth: CGFloat {
        guard visibleProviders.count > 1 else { return size }
        return size + CGFloat(visibleProviders.count - 1) * size * 0.72
    }
}

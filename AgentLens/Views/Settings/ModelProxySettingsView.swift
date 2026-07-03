import SwiftUI
import OpenBurnBarCore

// MARK: - Model Proxy Settings View

/// Status-first unified page that elevates the local gateway from a buried
/// sub-page of the Daemon tab to a first-class surface. Shows:
/// 1. A giant on/off hero with the copyable endpoint and model/client counts
/// 2. The routing strategy (exact-model failover vs provider-family)
/// 3. Connected client wiring status
/// 4. The live model catalog
/// 5. Plumbing (host/port/token) behind an Advanced disclosure
struct ModelProxySettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager
    let dataStore: DataStore
    let accountManager: AccountManager

    @State private var viewModel = ConnectionsViewModel()
    @State private var showAdvanced = false
    @State private var copiedEndpoint = false
    @State private var quotaService = ProviderQuotaService.shared

    private var endpoint: String {
        "\(settingsManager.gatewayHost):\(settingsManager.gatewayPort)"
    }

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .modelProxyRoot) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    // Hero: on/off + endpoint
                    proxyHero

                    // Model catalog summary
                    modelCatalogSummary

                    // Routing strategy
                    ConnectionsSettingsView(
                        settingsManager: settingsManager,
                        daemonManager: daemonManager,
                        dataStore: dataStore,
                        accountManager: accountManager,
                        section: .advancedOnly
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsAnchor(SettingsAnchor.modelProxyRouting)

                    // Advanced: host/port/token
                    advancedSection
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle("Model Proxy")
        .task { await refresh() }
    }

    // MARK: - Hero

    private var proxyHero: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                // Toggle row
                HStack(spacing: DesignSystem.Spacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(settingsManager.gatewayEnabled
                                  ? DesignSystem.Colors.purple
                                  : DesignSystem.Colors.textMuted)
                            .frame(width: 40, height: 40)
                        Image(systemName: "network")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Gateway")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(settingsManager.gatewayEnabled
                             ? "OpenAI-compatible API is live and serving models."
                             : "Turn on to expose your models to Cursor, VS Code, and any OpenAI-compatible client.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $settingsManager.gatewayEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: DesignSystem.Colors.purple))
                        .labelsHidden()
                }
                .settingsAnchor(SettingsAnchor.modelProxyOverview)

                if settingsManager.gatewayEnabled {
                    Divider().background(DesignSystem.Colors.border)

                    // Endpoint pill
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Endpoint")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Text("http://\(endpoint)/v1")
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            #if canImport(AppKit)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("http://\(endpoint)/v1", forType: .string)
                            #endif
                            withAnimation(DesignSystem.Animation.snappy) { copiedEndpoint = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation(DesignSystem.Animation.snappy) { copiedEndpoint = false }
                            }
                        } label: {
                            Label(copiedEndpoint ? "Copied" : "Copy", systemImage: copiedEndpoint ? "checkmark" : "doc.on.doc")
                                .font(DesignSystem.Typography.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .settingsAnchor(SettingsAnchor.modelProxyEndpoint)

                    // Quick stats
                    HStack(spacing: DesignSystem.Spacing.lg) {
                        statBadge(
                            label: "Models",
                            value: "\(viewModel.proxyModels.count)",
                            tint: DesignSystem.Colors.purple
                        )
                        statBadge(
                            label: "Route ready",
                            value: "\(viewModel.proxyModels.filter(\.routeEligible).count)",
                            tint: DesignSystem.Colors.success
                        )
                        statBadge(
                            label: "Providers",
                            value: "\(Set(viewModel.proxyModels.map(\.providerID)).count)",
                            tint: DesignSystem.Colors.teal
                        )
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private func statBadge(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(DesignSystem.Typography.title)
                .fontWeight(.bold)
                .foregroundStyle(tint)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    // MARK: - Model catalog summary

    @ViewBuilder
    private var modelCatalogSummary: some View {
        ProxyModelCatalogPanel(
            models: viewModel.proxyModels,
            state: viewModel.proxyModelCatalogState,
            endpoint: endpoint,
            onRefresh: { Task { await viewModel.refreshProxyModelCatalog(settings: settingsManager) } },
            onStartGateway: { Task { await viewModel.refreshProxyModelCatalog(settings: settingsManager) } },
            droidSyncState: nil,
            onSyncDroid: nil,
            onToggleModelAdvertisement: nil
        )
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Button {
                withAnimation(DesignSystem.Animation.gentle) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("Advanced: host, port, auth token")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if showAdvanced {
                HTTPGatewayDetailView(settingsManager: settingsManager)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Refresh

    private func refresh() async {
        await daemonManager.refreshHealth()
        await quotaService.refreshIfNeeded(dataStore: dataStore)
        await viewModel.refreshProxyModelCatalog(settings: settingsManager)
    }
}

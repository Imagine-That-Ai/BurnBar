import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Settings → Agents → Models
//
// Top-level browse surface for every model the local OpenBurnBar gateway can
// advertise or keep hidden. Renders the internal proxy catalog grouped by
// provider, with route-readiness, quota state, account label, source kind, and
// the per-model public `/v1/models` advertisement toggle. Keeps the fetch +
// state machine on `ConnectionsViewModel` so the same data backs the embedded
// CLIs catalog and this dedicated page.

struct AgentsModelsView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var daemonManager: OpenBurnBarDaemonManager

    @State private var viewModel = ConnectionsViewModel()

    init(
        settingsManager: SettingsManager,
        daemonManager: OpenBurnBarDaemonManager
    ) {
        self._settingsManager = Bindable(settingsManager)
        self._daemonManager = Bindable(daemonManager)
    }

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .agentsModels) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    header
                    ProxyModelCatalogPanel(
                        models: viewModel.proxyModels,
                        state: viewModel.proxyModelCatalogState,
                        endpoint: gatewayModelsEndpoint,
                        onRefresh: { refresh() },
                        onStartGateway: { startGateway() },
                        droidSyncState: viewModel.state(for: .droid),
                        onSyncDroid: { syncDroidProxyModels() },
                        onToggleModelAdvertisement: { model, isEnabled in
                            setModelAdvertisement(model, isEnabled: isEnabled)
                        },
                        onUpsertThinkingVariant: { model, level in
                            upsertThinkingVariant(model, level: level)
                        },
                        onRemoveThinkingVariant: { variantModel in
                            removeThinkingVariant(variantModel)
                        }
                    )
                    .settingsAnchor(SettingsAnchor.agentsModels)
                    legend
                }
                .padding(DesignSystem.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle("Models")
        .task { await initialLoad() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.refreshProxyModelCatalog(settings: settingsManager) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Every model BurnBar can advertise through the local OpenAI-compatible gateway. Each row maps to one provider account; advertised route-ready rows are the ones any wired CLI can call right now.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("This page reads the live Settings catalog and controls what appears at \(gatewayModelsEndpoint). Hidden rows stay here so they can be re-enabled without re-adding the account.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var legend: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Legend")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            legendRow(
                title: "route ready",
                tint: DesignSystem.Colors.success,
                detail: "Provider account has quota and an eligible credential — any wired CLI can call this model."
            )
            legendRow(
                title: "blocked",
                tint: DesignSystem.Colors.warning,
                detail: "Listed but not routable. Hover the row to see the exact reason (quota exhausted, cooling down, missing credential, auth failed, or disabled)."
            )
            legendRow(
                title: "advertised",
                tint: DesignSystem.Colors.success,
                detail: "Visible in the public /v1/models list and eligible for Droid sync when route ready."
            )
            legendRow(
                title: "hidden",
                tint: DesignSystem.Colors.textSecondary,
                detail: "Kept in Settings but removed from the public /v1/models list, direct routing, and Droid sync."
            )
            legendRow(
                title: "source kind",
                tint: DesignSystem.Colors.textSecondary,
                detail: "How BurnBar found this model: upstream models endpoint (live discovery) or daemon provider config (configured aliases)."
            )
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.35), lineWidth: 0.5)
        )
    }

    private func legendRow(title: String, tint: Color, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            Text(title)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tint.opacity(0.12))
                .clipShape(Capsule())
            Text(detail)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gatewayModelsEndpoint: String {
        let configuredHost = settingsManager.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        switch configuredHost {
        case "", "0.0.0.0", "::":
            host = "127.0.0.1"
        default:
            host = configuredHost
        }
        let port = settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317
        return "http://\(host):\(port)/v1/models"
    }

    private func initialLoad() async {
        await daemonManager.refreshHealth()
        await viewModel.refreshProxyModelCatalog(settings: settingsManager)
        await viewModel.refreshWiringState(settings: settingsManager)
    }

    private func refresh() {
        Task {
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
        }
    }

    private func startGateway() {
        Task {
            viewModel.enableLocalGateway(settings: settingsManager)
            await restartLocalGateway()
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func syncDroidProxyModels() {
        Task {
            await viewModel.syncModels(
                target: .droid,
                settings: settingsManager,
                restartGateway: restartLocalGateway
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func setModelAdvertisement(_ model: ProxyAdvertisedModel, isEnabled: Bool) {
        Task {
            await daemonManager.setProviderModelAdvertisement(
                providerID: model.providerID,
                modelID: model.modelID,
                isEnabled: isEnabled
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func upsertThinkingVariant(_ model: ProxyAdvertisedModel, level: BurnBarThinkingLevel) {
        let now = Date()
        let variant = BurnBarModelVariant(
            variantID: BurnBarModelVariant.defaultVariantID(baseModelID: model.modelID, level: level),
            label: BurnBarModelVariant.defaultLabel(for: level),
            baseModelID: model.modelID,
            thinkingLevel: level,
            maxOutputTokens: nil,
            createdAt: now,
            updatedAt: now
        )
        Task {
            await daemonManager.setProviderModelVariant(
                providerID: model.providerID,
                variant: variant
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func removeThinkingVariant(_ variantModel: ProxyAdvertisedModel) {
        Task {
            await daemonManager.removeProviderModelVariant(
                providerID: variantModel.providerID,
                variantID: variantModel.modelID
            )
            await viewModel.refreshProxyModelCatalog(settings: settingsManager)
            await viewModel.refreshWiringState(settings: settingsManager)
        }
    }

    private func restartLocalGateway() async {
        await daemonManager.installAndStart()
        await daemonManager.refreshHealth()
    }
}

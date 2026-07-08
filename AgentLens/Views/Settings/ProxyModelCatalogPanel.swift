import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Proxy Model Catalog Panel
//
// Shared between Settings → Agents → CLIs (embedded inside the wiring page so
// the user can sanity-check what Droid/Codex/Claude Code will actually
// receive) and Settings → Agents → Models (the dedicated full-page catalog).
//
// Renders the internal proxy model catalog for the local OpenBurnBar gateway,
// grouped by provider, with route-readiness, quota state, advertisement state,
// and failover-pool attribution. The public `/v1/models` endpoint only receives
// one row per provider/model whose advertisement toggle is enabled and whose
// route is live. The view is purely presentational — the fetch + state machine live on
// `ConnectionsViewModel` so both call sites stay in sync.

struct ProxyModelCatalogPanel: View {
    let models: [ProxyAdvertisedModel]
    let state: ProxyModelCatalogState
    let endpoint: String
    let onRefresh: () -> Void
    let onStartGateway: () -> Void
    var routeLogEntries: [BurnBarProxyRouteLogEntry] = []
    var routeLogState: ProxyRouteLogState = .idle
    var onRefreshRouteLog: (() -> Void)?
    var onClearRouteLog: (() -> Void)?
    let droidSyncState: AppConnectState?
    let onSyncDroid: (() -> Void)?
    let onToggleModelAdvertisement: ((ProxyAdvertisedModel, Bool) -> Void)?
    var onUpsertThinkingVariant: ((ProxyAdvertisedModel, BurnBarThinkingLevel) -> Void)?
    var onRemoveThinkingVariant: ((ProxyAdvertisedModel) -> Void)?
    var onUpsertModelAlias: ((ProxyAdvertisedModel, BurnBarModelAlias) async -> String?)?
    var onRemoveModelAlias: ((ProxyAdvertisedModel) -> Void)?
    var onSetDisplayName: ((ProxyAdvertisedModel, String) async -> String?)?
    var onClearDisplayName: ((ProxyAdvertisedModel) -> Void)?
    /// Bulk advertise toggle for a whole provider: (providerID, modelIDs, isEnabled).
    var onSetProviderAdvertisement: ((String, [String], Bool) -> Void)?
    /// Provider id → the user's custom (catalog-unknown) models, for the manage sheet.
    var customModelsByProvider: [String: [BurnBarCustomModel]] = [:]
    /// Add (or replace) a user-declared custom model: (providerID, modelID, displayName).
    var onAddCustomModel: ((String, String, String) -> Void)?
    /// Remove a user-declared custom model: (providerID, modelID).
    var onRemoveCustomModel: ((String, String) -> Void)?

    @State private var copiedEndpoint = false
    @State private var expandedProviderIDs: Set<String> = []
    @State private var isRouteLogPresented = false
    @State private var isAddModelPresented = false

    private var groups: [ProxyModelProviderGroup] {
        Dictionary(grouping: models, by: \.providerID)
            .map { providerID, rows in
                let sortedRows = rows.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                return ProxyModelProviderGroup(
                    providerID: providerID,
                    providerName: sortedRows.first?.providerName ?? providerID,
                    models: sortedRows
                )
            }
            .sorted {
                $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending
            }
    }

    private var routeReadyCount: Int {
        models.filter(\.routeEligible).count
    }

    private var advertisedCount: Int {
        models.filter(\.advertised).count
    }

    private var hiddenCount: Int {
        models.filter { !$0.advertisementEnabled }.count
    }

    private var isDroidSyncing: Bool {
        droidSyncState?.isBusy == true
    }

    private var canSyncDroid: Bool {
        onSyncDroid != nil
            && !state.isLoading
            && !isDroidSyncing
    }

    private var droidSyncButtonTitle: String {
        isDroidSyncing ? "Syncing" : "Sync to Droid"
    }

    private var status: (label: String, systemImage: String, tint: Color) {
        switch state {
        case .idle:
            return ("Not checked", "circle.dashed", DesignSystem.Colors.textMuted)
        case .startingGateway:
            return ("Starting", "play.circle.fill", DesignSystem.Colors.textSecondary)
        case .loading:
            return ("Refreshing", "arrow.triangle.2.circlepath", DesignSystem.Colors.textSecondary)
        case .loaded:
            if models.isEmpty {
                return ("No routes", "exclamationmark.circle.fill", DesignSystem.Colors.warning)
            }
            if advertisedCount == 0 {
                return ("0 advertised", "exclamationmark.circle.fill", DesignSystem.Colors.warning)
            }
            if advertisedCount == models.count {
                return ("\(models.count) advertised", "checkmark.seal.fill", DesignSystem.Colors.success)
            }
            return ("\(advertisedCount)/\(models.count) advertised", "exclamationmark.triangle.fill", DesignSystem.Colors.warning)
        case .error:
            return ("Gateway offline", "bolt.slash.fill", DesignSystem.Colors.error)
        }
    }

    private var statusDetail: String {
        switch state {
        case .idle:
            return "Not checked yet"
        case .startingGateway:
            return "Starting gateway"
        case .loading:
            return "Refreshing now"
        case .loaded(let lastRefresh):
            return "Last refreshed \(lastRefresh.formatted(date: .omitted, time: .shortened))"
        case .error(_, let lastAttempt):
            return "Last attempt \(lastAttempt.formatted(date: .omitted, time: .shortened))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(DesignSystem.Colors.border.opacity(0.7))
            content
        }
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(status.tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: status.tint.opacity(0.08), radius: 18, x: 0, y: 10)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(status.tint.opacity(0.14))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text("BurnBar proxy models")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    statusPill
                }
                Text(endpoint)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(statusDetail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .layoutPriority(1)

            Spacer(minLength: DesignSystem.Spacing.md)

            // Progressive degradation so the action row never crushes the
            // identity column: full labels → icon-only → overflow menu + Refresh.
            // (Replaces a `.fixedSize()` row that pinned all five buttons at
            // full width and squeezed the endpoint/status text into a stack.)
            ViewThatFits(in: .horizontal) {
                headerActionButtons.labelStyle(.titleAndIcon)
                headerActionButtons.labelStyle(.iconOnly)
                headerActionsCompact
            }
        }
        .padding(DesignSystem.Spacing.md)
        .sheet(isPresented: $isRouteLogPresented) {
            ProxyRouteLogSheet(
                entries: routeLogEntries,
                state: routeLogState,
                onRefresh: onRefreshRouteLog,
                onClear: onClearRouteLog
            )
        }
        .sheet(isPresented: $isAddModelPresented) {
            AddCustomModelSheet(
                providers: addableProviders,
                customModelsByProvider: customModelsByProvider,
                onAdd: { providerID, modelID, displayName in
                    onAddCustomModel?(providerID, modelID, displayName)
                },
                onRemove: { providerID, modelID in
                    onRemoveCustomModel?(providerID, modelID)
                }
            )
        }
    }

    /// The five trailing actions as one reusable row (no `.fixedSize()`, no
    /// label style) so the `ViewThatFits` tiers share a single source of truth
    /// and only differ by `.labelStyle`.
    @ViewBuilder
    private var headerActionButtons: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            if let onRefreshRouteLog {
                Button {
                    isRouteLogPresented = true
                    onRefreshRouteLog()
                } label: {
                    Label("Route log", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show recent OpenBurnBar proxy routes with requested and proxy-sent model slugs.")
            }

            if let onSyncDroid {
                Button(action: onSyncDroid) {
                    Label(droidSyncButtonTitle, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canSyncDroid)
                .help("Writes every advertised route-ready BurnBar proxy model into Droid's Factory config files.")
                .accessibilityHint("Writes advertised route-ready BurnBar proxy models into Droid.")
            }

            if onAddCustomModel != nil {
                Button {
                    isAddModelPresented = true
                } label: {
                    Label("Add model", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(addableProviders.isEmpty)
                .help("Advertise a provider model the bundled catalog doesn't know about (e.g. a brand-new model id).")
                .accessibilityHint("Add a custom model id to the proxy's advertised list.")
            }

            Button(action: copyEndpoint) {
                Label(copiedEndpoint ? "Copied" : "Copy URL", systemImage: copiedEndpoint ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(state.isLoading)
        }
    }

    /// Narrowest tier: secondary actions fold into an overflow menu and only the
    /// primary Refresh stays visible, so the row fits any pane width.
    private var headerActionsCompact: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Menu {
                if let onRefreshRouteLog {
                    Button {
                        isRouteLogPresented = true
                        onRefreshRouteLog()
                    } label: {
                        Label("Route log", systemImage: "list.bullet.rectangle")
                    }
                }
                if let onSyncDroid {
                    Button(action: onSyncDroid) {
                        Label(droidSyncButtonTitle, systemImage: "arrow.down.circle")
                    }
                    .disabled(!canSyncDroid)
                }
                if onAddCustomModel != nil {
                    Button {
                        isAddModelPresented = true
                    } label: {
                        Label("Add model", systemImage: "plus.circle")
                    }
                    .disabled(addableProviders.isEmpty)
                }
                Button(action: copyEndpoint) {
                    Label(copiedEndpoint ? "Copied" : "Copy URL", systemImage: copiedEndpoint ? "checkmark" : "doc.on.doc")
                }
            } label: {
                Label("More actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .help("Route log, Sync to Droid, Add model, Copy URL")

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .labelStyle(.iconOnly)
            .disabled(state.isLoading)
            .help("Refresh the advertised model catalog")
        }
    }

    /// Providers a custom model can be attached to — every provider the catalog
    /// currently surfaces, plus any that already carry custom models.
    private var addableProviders: [AddCustomModelSheet.ProviderOption] {
        var byID: [String: String] = [:]
        for group in groups {
            byID[group.providerID] = group.providerName
        }
        for providerID in customModelsByProvider.keys where byID[providerID] == nil {
            byID[providerID] = providerID
        }
        return byID
            .map { AddCustomModelSheet.ProviderOption(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            if state.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: status.systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(status.label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.12))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            catalogMessage(
                title: "Check the live proxy catalog",
                message: "Refresh to read the exact models BurnBar can advertise through the local OpenAI-compatible gateway.",
                systemImage: "point.3.connected.trianglepath.dotted",
                tint: DesignSystem.Colors.textSecondary,
                actionTitle: "Refresh",
                action: onRefresh
            )
        case .startingGateway:
            catalogMessage(
                title: "Starting local gateway",
                message: "Installing or restarting OpenBurnBarDaemon so /v1/models can answer.",
                systemImage: "play.circle.fill",
                tint: DesignSystem.Colors.textSecondary,
                actionTitle: nil,
                action: nil
            )
        case .loading where models.isEmpty:
            catalogMessage(
                title: "Reading live catalog",
                message: "Checking the local gateway for proxy models.",
                systemImage: "waveform.path.ecg",
                tint: DesignSystem.Colors.textSecondary,
                actionTitle: nil,
                action: nil
            )
        case .error(let message, _):
            catalogMessage(
                title: "Gateway is not advertising models",
                message: message,
                systemImage: "network.slash",
                tint: DesignSystem.Colors.error,
                actionTitle: "Start gateway",
                action: onStartGateway
            )
        case .loaded where models.isEmpty:
            catalogMessage(
                title: "No models are available",
                message: "Add or enable a provider account with quota, then refresh this catalog.",
                systemImage: "tray",
                tint: DesignSystem.Colors.warning,
                actionTitle: "Refresh",
                action: onRefresh
            )
        default:
            VStack(alignment: .leading, spacing: 0) {
                catalogStats
                ForEach(groups) { group in
                    ProxyModelProviderSection(
                        group: group,
                        isExpanded: expandedProviderIDs.contains(group.id),
                        onToggleExpanded: { toggleProvider(group.id) },
                        onToggleModelAdvertisement: onToggleModelAdvertisement,
                        onUpsertThinkingVariant: onUpsertThinkingVariant,
                        onRemoveThinkingVariant: onRemoveThinkingVariant,
                        onUpsertModelAlias: onUpsertModelAlias,
                        onRemoveModelAlias: onRemoveModelAlias,
                        onSetDisplayName: onSetDisplayName,
                        onClearDisplayName: onClearDisplayName,
                        onSetProviderAdvertisement: onSetProviderAdvertisement
                    )
                    if group.id != groups.last?.id {
                        Divider().background(DesignSystem.Colors.border.opacity(0.45))
                    }
                }
            }
        }
    }

    private func toggleProvider(_ id: String) {
        if expandedProviderIDs.contains(id) {
            expandedProviderIDs.remove(id)
        } else {
            expandedProviderIDs.insert(id)
        }
    }

    private var catalogStats: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            metricPill("\(models.count)", "models", tint: DesignSystem.Colors.success)
            metricPill("\(advertisedCount)", "advertised", tint: advertisedCount == models.count ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
            metricPill("\(routeReadyCount)", "ready", tint: routeReadyCount == models.count ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
            if hiddenCount > 0 {
                metricPill("\(hiddenCount)", "hidden", tint: DesignSystem.Colors.warning)
            }
            metricPill("\(groups.count)", "providers", tint: DesignSystem.Colors.ember)
            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.background.opacity(0.32))
    }

    private func metricPill(_ value: String, _ label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(DesignSystem.Typography.monoTiny)
                .fontWeight(.bold)
            Text(label)
                .font(DesignSystem.Typography.tiny)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10))
        .clipShape(Capsule())
    }

    private func catalogMessage(
        title: String,
        message: String,
        systemImage: String,
        tint: Color,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignSystem.Spacing.sm)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(
                        actionTitle,
                        systemImage: actionTitle == "Refresh" ? "arrow.clockwise" : "play.circle.fill"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    private func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint, forType: .string)
        copiedEndpoint = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copiedEndpoint = false
        }
    }
}

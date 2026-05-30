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
    let droidSyncState: AppConnectState?
    let onSyncDroid: (() -> Void)?
    let onToggleModelAdvertisement: ((ProxyAdvertisedModel, Bool) -> Void)?
    var onUpsertThinkingVariant: ((ProxyAdvertisedModel, BurnBarThinkingLevel) -> Void)? = nil
    var onRemoveThinkingVariant: ((ProxyAdvertisedModel) -> Void)? = nil
    var onUpsertModelAlias: ((ProxyAdvertisedModel, BurnBarModelAlias) async -> String?)? = nil
    var onRemoveModelAlias: ((ProxyAdvertisedModel) -> Void)? = nil
    var onSetDisplayName: ((ProxyAdvertisedModel, String) async -> String?)? = nil
    var onClearDisplayName: ((ProxyAdvertisedModel) -> Void)? = nil
    /// Bulk advertise toggle for a whole provider: (providerID, modelIDs, isEnabled).
    var onSetProviderAdvertisement: ((String, [String], Bool) -> Void)? = nil

    @State private var copiedEndpoint = false
    @State private var expandedProviderIDs: Set<String> = []

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

            HStack(spacing: DesignSystem.Spacing.xs) {
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
            .fixedSize()
        }
        .padding(DesignSystem.Spacing.md)
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

struct ProxyModelProviderGroup: Identifiable {
    let providerID: String
    let providerName: String
    let models: [ProxyAdvertisedModel]

    var id: String { providerID }
}

/// Logo resolver for the proxy catalog. The advertised provider IDs come
/// straight from `BurnBarCatalogProvider.id` (e.g. `deepseek`, `xai`,
/// `mistral`, `meta`, `alibaba`, `mlx`, `cohere`, `amazon`) — most of which
/// have no `AgentProvider` case but DO ship asset-catalog logos. We resolve
/// in this order:
///   1. Bundled asset whose name matches `BurnBarCatalogProvider`'s registry
///      (`DeepSeekProviderLogo`, `GrokLogo`, etc.) or the unsuffixed variant
///      (`DeepSeekLogo`).
///   2. The `AgentProvider`-mapped `ProviderLogoView` for canonical cases
///      (`anthropic` → `.claudeCode`, `openai` → `.openAI`, etc.).
///   3. A monogram badge tinted with `DesignSystem.Colors.primary(for:)` when
///      we can derive a provider, otherwise the textMuted fallback.
struct ProxyProviderLogoView: View {
    let catalogProviderID: String
    let providerName: String
    let size: CGFloat

    private var assetImage: Image? {
        for candidate in Self.assetCandidates(for: catalogProviderID) {
            if NSImage(named: candidate) != nil {
                return Image(candidate)
            }
        }
        return nil
    }

    private var agentProvider: AgentProvider? {
        AgentProvider.fromCatalogProviderID(catalogProviderID)
    }

    var body: some View {
        Group {
            if let assetImage {
                assetImage
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            } else if let provider = agentProvider {
                ProviderLogoView(provider: provider, size: size)
            } else {
                monogram
            }
        }
    }

    private var monogram: some View {
        let initials = Self.monogramText(for: providerName, fallbackID: catalogProviderID)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(DesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                )
            Text(initials)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(width: size, height: size)
    }

    /// Asset names worth probing for a given catalog provider ID. The real
    /// brand-mark PNGs that ship with the repo (`DeepSeekLogo`, `MistralLogo`,
    /// `MetaLogo`, `GrokLogo`, etc.) are preferred over the synthetic
    /// `*ProviderLogo` SVG placeholders that older builds used. The catalog's
    /// own registry is consulted as a tertiary fallback, and a conventional
    /// `{ID}Logo` lookup catches any future provider that ships an asset by
    /// name without needing a code change here.
    static func assetCandidates(for catalogProviderID: String) -> [String] {
        ProviderBrand.logoAssetCandidates(for: catalogProviderID)
    }

    static func monogramText(for providerName: String, fallbackID: String) -> String {
        let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = fallbackID.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedName.isEmpty ? trimmedID : trimmedName
        guard !source.isEmpty else { return "?" }
        let parts = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        if let first = parts.first, parts.count == 1, let initial = first.first {
            return String(initial).uppercased()
        }
        let initials = parts.prefix(2).compactMap { $0.first }
        guard !initials.isEmpty else { return String(source.prefix(1)).uppercased() }
        return initials.map { String($0).uppercased() }.joined()
    }
}

struct ProxyModelProviderSection: View {
    let group: ProxyModelProviderGroup
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onToggleModelAdvertisement: ((ProxyAdvertisedModel, Bool) -> Void)?
    var onUpsertThinkingVariant: ((ProxyAdvertisedModel, BurnBarThinkingLevel) -> Void)? = nil
    var onRemoveThinkingVariant: ((ProxyAdvertisedModel) -> Void)? = nil
    var onUpsertModelAlias: ((ProxyAdvertisedModel, BurnBarModelAlias) async -> String?)? = nil
    var onRemoveModelAlias: ((ProxyAdvertisedModel) -> Void)? = nil
    var onSetDisplayName: ((ProxyAdvertisedModel, String) async -> String?)? = nil
    var onClearDisplayName: ((ProxyAdvertisedModel) -> Void)? = nil
    var onSetProviderAdvertisement: ((String, [String], Bool) -> Void)? = nil

    private let collapsedLimit = 5

    private var anyAdvertised: Bool {
        group.models.contains { $0.advertisementEnabled }
    }

    private var providerAdvertiseHelp: String {
        anyAdvertised
            ? "Hide all \(group.providerName) models from /v1/models. You can switch individual models back on afterward."
            : "Advertise all \(group.providerName) models through /v1/models."
    }

    private var provider: AgentProvider? {
        AgentProvider.fromCatalogProviderID(group.providerID)
    }

    private var visibleModels: [ProxyAdvertisedModel] {
        isExpanded ? group.models : Array(group.models.prefix(collapsedLimit))
    }

    private var hiddenCount: Int {
        max(0, group.models.count - visibleModels.count)
    }

    private func existingVariantLevels(forBaseModelID baseModelID: String, providerID: String) -> Set<BurnBarThinkingLevel> {
        var levels: Set<BurnBarThinkingLevel> = []
        let trimmedBase = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedBase.isEmpty, !trimmedProvider.isEmpty else { return levels }
        for sibling in group.models where sibling.providerID.lowercased() == trimmedProvider {
            guard sibling.isThinkingLevelVariant,
                  let siblingBase = sibling.baseModelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  siblingBase == trimmedBase,
                  let raw = sibling.thinkingLevel,
                  let level = BurnBarThinkingLevel(rawValue: raw) else { continue }
            levels.insert(level)
        }
        return levels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProxyProviderLogoView(
                    catalogProviderID: group.providerID,
                    providerName: group.providerName,
                    size: 20
                )
                Text(group.providerName)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("\(group.models.count)")
                    .font(DesignSystem.Typography.monoTiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesignSystem.Colors.background.opacity(0.55))
                    .clipShape(Capsule())
                Spacer()
                if let onSetProviderAdvertisement {
                    Toggle("", isOn: Binding(
                        get: { anyAdvertised },
                        set: { onSetProviderAdvertisement(group.providerID, group.models.map(\.modelID), $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(providerAdvertiseHelp)
                    .accessibilityLabel("Advertise all \(group.providerName) models")
                    .accessibilityValue(anyAdvertised ? "on" : "off")
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.xs)

            ForEach(visibleModels) { model in
                ProxyModelCatalogRow(
                    model: model,
                    onToggleAdvertisement: onToggleModelAdvertisement,
                    existingVariantLevels: existingVariantLevels(forBaseModelID: model.modelID, providerID: model.providerID),
                    onUpsertThinkingVariant: onUpsertThinkingVariant,
                    onRemoveThinkingVariant: onRemoveThinkingVariant,
                    onUpsertModelAlias: onUpsertModelAlias,
                    onRemoveModelAlias: onRemoveModelAlias,
                    onSetDisplayName: onSetDisplayName,
                    onClearDisplayName: onClearDisplayName
                )
            }

            if hiddenCount > 0 || isExpanded {
                Button(action: onToggleExpanded) {
                    Label(
                        isExpanded ? "Show fewer" : "Show \(hiddenCount) more",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.ember)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.top, 5)
                .padding(.bottom, DesignSystem.Spacing.sm)
            }
        }
    }
}

struct ProxyModelCatalogRow: View {
    let model: ProxyAdvertisedModel
    let onToggleAdvertisement: ((ProxyAdvertisedModel, Bool) -> Void)?
    var existingVariantLevels: Set<BurnBarThinkingLevel> = []
    var onUpsertThinkingVariant: ((ProxyAdvertisedModel, BurnBarThinkingLevel) -> Void)? = nil
    var onRemoveThinkingVariant: ((ProxyAdvertisedModel) -> Void)? = nil
    var onUpsertModelAlias: ((ProxyAdvertisedModel, BurnBarModelAlias) async -> String?)? = nil
    var onRemoveModelAlias: ((ProxyAdvertisedModel) -> Void)? = nil
    var onSetDisplayName: ((ProxyAdvertisedModel, String) async -> String?)? = nil
    var onClearDisplayName: ((ProxyAdvertisedModel) -> Void)? = nil

    @State private var showsAliasEditor = false
    @State private var aliasDraft = ModelAliasEditorDraft.empty
    @State private var showsRenameSheet = false

    private var routeTint: Color {
        if model.routeEligible { return DesignSystem.Colors.success }
        return model.lastError == nil ? DesignSystem.Colors.warning : DesignSystem.Colors.error
    }

    private var quotaTint: Color {
        switch model.quotaState.lowercased() {
        case "healthy", "available", "ok":
            return DesignSystem.Colors.success
        case "exhausted", "auth_failed", "missing_credential", "disabled":
            return DesignSystem.Colors.error
        case "cooling_down", "limited", "unknown":
            return DesignSystem.Colors.warning
        default:
            return DesignSystem.Colors.textSecondary
        }
    }

    private var resolvedThinkingLevel: BurnBarThinkingLevel? {
        guard let raw = model.thinkingLevel else { return nil }
        return BurnBarThinkingLevel(rawValue: raw)
    }

    private var supportsThinkingVariants: Bool {
        guard model.isBaseCatalogRow else { return false }
        let id = model.modelID.lowercased()
        let provider = model.providerID.lowercased()
        if provider == "anthropic" {
            let isOpus4Plus = id.contains("opus") && id.contains("-4")
            let isSonnet4Plus = id.contains("sonnet") && id.contains("-4")
            return isOpus4Plus || isSonnet4Plus
        }
        if provider == "openai" {
            return id.hasPrefix("gpt-5") || id.contains("codex") || id.hasPrefix("o1") || id.hasPrefix("o3")
        }
        return false
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(routeTint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                if model.isUserModelAlias {
                    Text(model.modelID)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(model.displayName)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if model.isUserModelAlias {
                        if model.displayName != model.modelID {
                            Text(model.displayName)
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("•")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                        }
                        if let baseModelID = model.baseModelID {
                            Text("→ \(baseModelID)")
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text(model.modelID)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Text("•")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                    Text(model.accountLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("•")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                    Text(model.sourceKind.replacingOccurrences(of: "_", with: " "))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: DesignSystem.Spacing.sm)
            if model.isUserModelAlias {
                tag("custom alias", tint: DesignSystem.Colors.ember)
            }
            if model.isBaseCatalogRow && model.displayNameIsCustom {
                tag("renamed", tint: DesignSystem.Colors.purple)
            }
            if let level = resolvedThinkingLevel {
                tag("think · \(level.displayLabel.lowercased())", tint: DesignSystem.Colors.purple)
            }
            tag(model.quotaState.replacingOccurrences(of: "_", with: " "), tint: quotaTint)
            tag(model.routeEligible ? "route ready" : "blocked", tint: routeTint)
            tag(advertisementLabel, tint: advertisementTint)
            if model.isUserModelAlias, let onRemoveModelAlias {
                Button {
                    onRemoveModelAlias(model)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .help("Remove the custom alias \(model.modelID).")
            } else if model.isUserModelAlias, let onUpsertModelAlias {
                Button {
                    aliasDraft = ModelAliasEditorDraft(model: model)
                    showsAliasEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.ember)
                .help("Edit alias \(model.modelID).")
            } else if model.isThinkingLevelVariant, let onRemoveThinkingVariant {
                Button {
                    onRemoveThinkingVariant(model)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .help("Remove the \(resolvedThinkingLevel?.displayLabel ?? "") thinking variant.")
            } else if supportsThinkingVariants, let onUpsertThinkingVariant {
                Menu {
                    ForEach(BurnBarThinkingLevel.allCases, id: \.self) { level in
                        Button("Add \(level.displayLabel) variant") {
                            onUpsertThinkingVariant(model, level)
                        }
                        .disabled(existingVariantLevels.contains(level))
                    }
                } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(DesignSystem.Colors.purple)
                .help("Add a thinking-level variant for \(model.modelID).")
            } else if model.isBaseCatalogRow, onSetDisplayName != nil || onUpsertModelAlias != nil {
                Button {
                    showsRenameSheet = true
                } label: {
                    Label("Rename…", systemImage: "character.cursor.ibeam")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.ember)
                .help("Rename \(model.modelID) — change the name shown in Hermes, PI, Droid, and other clients.")
            }
            if let onToggleAdvertisement {
                Toggle(
                    "Advertise \(model.displayName)",
                    isOn: Binding(
                        get: { model.advertisementEnabled },
                        set: { onToggleAdvertisement(model, $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(advertisementHelp)
                .accessibilityHint(advertisementHelp)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(model.lastError ?? "\(model.modelID) via \(model.providerName) source \(model.sourceID)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .sheet(isPresented: $showsAliasEditor) {
            ModelAliasEditorSheet(
                draft: $aliasDraft,
                onSave: { alias in
                    guard let onUpsertModelAlias else { return nil }
                    return await onUpsertModelAlias(model, alias)
                },
                onCancel: {
                    showsAliasEditor = false
                },
                onSaved: {
                    showsAliasEditor = false
                }
            )
        }
        .sheet(isPresented: $showsRenameSheet) {
            ModelRenameSheet(
                model: model,
                currentDisplayName: model.displayNameIsCustom ? model.displayName : "",
                canSetDisplayName: onSetDisplayName != nil,
                canCreateAlias: onUpsertModelAlias != nil,
                onSaveDisplayName: { name in
                    guard let onSetDisplayName else { return nil }
                    return await onSetDisplayName(model, name)
                },
                onResetDisplayName: {
                    onClearDisplayName?(model)
                    showsRenameSheet = false
                },
                onCreateAlias: { alias in
                    guard let onUpsertModelAlias else { return nil }
                    return await onUpsertModelAlias(model, alias)
                },
                onCancel: {
                    showsRenameSheet = false
                },
                onSaved: {
                    showsRenameSheet = false
                }
            )
        }
    }

    private func tag(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }

    private var advertisementLabel: String {
        if model.advertised { return "advertised" }
        if model.advertisementEnabled { return "not live" }
        return "hidden"
    }

    private var advertisementTint: Color {
        if model.advertised { return DesignSystem.Colors.success }
        if model.advertisementEnabled { return DesignSystem.Colors.warning }
        return DesignSystem.Colors.textMuted
    }

    private var advertisementHelp: String {
        if model.advertisementEnabled {
            return "Hide \(model.modelID) from /v1/models and future Droid syncs for this provider."
        }
        return "Advertise \(model.modelID) through /v1/models and future Droid syncs for this provider."
    }

    private var accessibilitySummary: String {
        let route = model.routeEligible ? "route ready" : "blocked"
        let quota = model.quotaState.replacingOccurrences(of: "_", with: " ")
        return "\(model.displayName), \(model.providerName), \(model.accountLabel), \(quota), \(route), \(advertisementLabel)"
    }
}

private struct ModelAliasEditorDraft: Equatable {
    var baseModelID: String
    var aliasID: String
    var displayName: String
    var hidesBaseModel: Bool
    var createdAt: Date

    static var empty: ModelAliasEditorDraft {
        ModelAliasEditorDraft(baseModelID: "", aliasID: "", displayName: "", hidesBaseModel: false, createdAt: Date())
    }

    init(baseModel: ProxyAdvertisedModel) {
        self.baseModelID = baseModel.modelID
        self.aliasID = ""
        self.displayName = ""
        self.hidesBaseModel = false
        self.createdAt = Date()
    }

    init(model: ProxyAdvertisedModel) {
        self.baseModelID = model.baseModelID ?? model.modelID
        self.aliasID = model.modelID
        self.displayName = model.displayName == model.modelID ? "" : model.displayName
        self.hidesBaseModel = model.hidesBaseModel
        self.createdAt = Date()
    }

    init(
        baseModelID: String,
        aliasID: String,
        displayName: String,
        hidesBaseModel: Bool,
        createdAt: Date
    ) {
        self.baseModelID = baseModelID
        self.aliasID = aliasID
        self.displayName = displayName
        self.hidesBaseModel = hidesBaseModel
        self.createdAt = createdAt
    }

    var isValid: Bool {
        BurnBarModelAlias.isValidAliasID(aliasID)
            && !baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && aliasID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                != baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func makeAlias() -> BurnBarModelAlias {
        let trimmedID = aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
        return BurnBarModelAlias(
            aliasID: trimmedID,
            baseModelID: baseModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            hidesBaseModel: hidesBaseModel,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }
}

private struct ModelAliasEditorSheet: View {
    @Binding var draft: ModelAliasEditorDraft
    let onSave: (BurnBarModelAlias) async -> String?
    let onCancel: () -> Void
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @State private var isSaving = false

    private var validationMessage: String? {
        let trimmedID = draft.aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedID.isEmpty { return "Enter a custom model id." }
        if !BurnBarModelAlias.isValidAliasID(trimmedID) {
            return "Use letters, numbers, and . _ - : / only (no spaces)."
        }
        if trimmedID.lowercased() == draft.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return "The alias id must differ from the canonical model id."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Custom model alias")
                .font(DesignSystem.Typography.headline)
                .fontWeight(.semibold)
            Text("Clients call the alias id in /v1/models and chat requests. BurnBar routes to \(draft.baseModelID).")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Custom model id", text: $draft.aliasID)
                .textFieldStyle(.roundedBorder)
                .font(DesignSystem.Typography.monoSmall)

            TextField("Display name (optional)", text: $draft.displayName)
                .textFieldStyle(.roundedBorder)

            Toggle("Hide original model in /v1/models", isOn: $draft.hidesBaseModel)
                .font(DesignSystem.Typography.caption)

            if let validationMessage {
                Text(validationMessage)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
            }
            if let saveError {
                Text(saveError)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Spacer()
                Button("Save alias") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        saveError = await onSave(draft.makeAlias())
                        if saveError == nil {
                            onSaved()
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid || isSaving)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 420)
    }
}


// MARK: - Model Rename Sheet
//
// The display-name-first "Rename" experience for a base catalog model.
//
//   • The headline field sets a verbatim *display-name override*: the model
//     keeps its wire id and routing, but presents under the chosen name in
//     `/v1/models`, every wired CLI picker, and the BurnBar / Hermes / PI
//     apps. Free text — spaces and punctuation allowed. Empty + Save (or
//     "Reset to default") clears the override.
//
//   • The Advanced disclosure is the power-user escape hatch for clients that
//     display the raw model id rather than a display name (e.g. Forge, generic
//     OpenAI tools): it mints a custom wire id (an alias) those clients call
//     and show directly, while BurnBar still routes to the canonical model.
private struct ModelRenameSheet: View {
    let model: ProxyAdvertisedModel
    let currentDisplayName: String
    let canSetDisplayName: Bool
    let canCreateAlias: Bool
    let onSaveDisplayName: (String) async -> String?
    let onResetDisplayName: () -> Void
    let onCreateAlias: (BurnBarModelAlias) async -> String?
    let onCancel: () -> Void
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var showsAdvanced = false
    @State private var aliasID = ""
    @State private var hidesBaseModel = false
    @State private var saveError: String?
    @State private var isSaving = false

    init(
        model: ProxyAdvertisedModel,
        currentDisplayName: String,
        canSetDisplayName: Bool,
        canCreateAlias: Bool,
        onSaveDisplayName: @escaping (String) async -> String?,
        onResetDisplayName: @escaping () -> Void,
        onCreateAlias: @escaping (BurnBarModelAlias) async -> String?,
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.currentDisplayName = currentDisplayName
        self.canSetDisplayName = canSetDisplayName
        self.canCreateAlias = canCreateAlias
        self.onSaveDisplayName = onSaveDisplayName
        self.onResetDisplayName = onResetDisplayName
        self.onCreateAlias = onCreateAlias
        self.onCancel = onCancel
        self.onSaved = onSaved
        _displayName = State(initialValue: currentDisplayName)
    }

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAliasID: String {
        aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasExistingOverride: Bool {
        !currentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usingAliasPath: Bool {
        showsAdvanced && !trimmedAliasID.isEmpty
    }

    private var aliasValidationMessage: String? {
        guard usingAliasPath else { return nil }
        if !BurnBarModelAlias.isValidAliasID(trimmedAliasID) {
            return "Use letters, numbers, and . _ - : / only (no spaces)."
        }
        if trimmedAliasID.lowercased() == model.modelID.lowercased() {
            return "The custom id must differ from \(model.modelID)."
        }
        return nil
    }

    private var canSave: Bool {
        if usingAliasPath {
            return aliasValidationMessage == nil
        }
        return canSetDisplayName && (!trimmedDisplayName.isEmpty || hasExistingOverride)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Rename model")
                .font(DesignSystem.Typography.headline)
                .fontWeight(.semibold)
            Text("Give “\(model.modelID)” a friendlier name. Routing is unchanged — only the label clients show changes.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .disabled(!canSetDisplayName)

            Text("Shown in Hermes, PI, and Droid. Clients that display the raw model id (e.g. Forge) keep showing “\(model.modelID)” — use Advanced to give those a custom id too.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if canCreateAlias {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        TextField("Custom wire id (e.g. my-fast-coder)", text: $aliasID)
                            .textFieldStyle(.roundedBorder)
                            .font(DesignSystem.Typography.monoSmall)
                        Toggle("Hide the original \(model.modelID)", isOn: $hidesBaseModel)
                            .font(DesignSystem.Typography.caption)
                        Text("Mints a new model id that id-only clients (Forge, generic OpenAI tools) call and display directly. BurnBar still routes it to \(model.modelID).")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Advanced — custom wire id (for Forge & id-only clients)")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.medium)
                }
            }

            if let aliasValidationMessage {
                Text(aliasValidationMessage)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
            }
            if let saveError {
                Text(saveError)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                if hasExistingOverride {
                    Button("Reset to default") {
                        onResetDisplayName()
                        dismiss()
                    }
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer()
                Button(usingAliasPath ? "Create alias" : "Save") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        if usingAliasPath {
                            let alias = BurnBarModelAlias(
                                aliasID: trimmedAliasID,
                                baseModelID: model.baseModelID ?? model.modelID,
                                displayName: trimmedDisplayName,
                                hidesBaseModel: hidesBaseModel
                            )
                            saveError = await onCreateAlias(alias)
                        } else {
                            saveError = await onSaveDisplayName(trimmedDisplayName)
                        }
                        if saveError == nil {
                            onSaved()
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 440)
    }
}

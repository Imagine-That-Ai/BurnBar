import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Proxy Model Catalog Panel
//
// Shared between Settings → Agents → CLIs (embedded inside the wiring page so
// the user can sanity-check what Droid/Codex/Claude Code will actually
// receive) and Settings → Agents → Models (the dedicated full-page catalog).
//
// Renders the exact `/v1/models` envelope the local OpenBurnBar gateway
// advertises right now, grouped by provider, with route-readiness, quota
// state, and per-account attribution. The view is purely presentational —
// the fetch + state machine live on `ConnectionsViewModel` so both call
// sites stay in sync.

struct ProxyModelCatalogPanel: View {
    let models: [ProxyAdvertisedModel]
    let state: ProxyModelCatalogState
    let endpoint: String
    let onRefresh: () -> Void
    let onStartGateway: () -> Void

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
            if routeReadyCount == 0 {
                return ("0 ready", "exclamationmark.circle.fill", DesignSystem.Colors.warning)
            }
            if routeReadyCount == models.count {
                return ("\(models.count) ready", "checkmark.seal.fill", DesignSystem.Colors.success)
            }
            return ("\(routeReadyCount)/\(models.count) ready", "exclamationmark.triangle.fill", DesignSystem.Colors.warning)
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
                message: "Refresh to read the exact models BurnBar is advertising through the local OpenAI-compatible gateway.",
                systemImage: "point.3.connected.trianglepath.dotted",
                tint: DesignSystem.Colors.textSecondary,
                actionTitle: "Refresh",
                action: onRefresh
            )
        case .loading where models.isEmpty:
            catalogMessage(
                title: "Reading live catalog",
                message: "Checking the local gateway for advertised models.",
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
                        onToggleExpanded: { toggleProvider(group.id) }
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
            metricPill("\(routeReadyCount)", "ready", tint: routeReadyCount == models.count ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
            metricPill("\(groups.count)", "providers", tint: DesignSystem.Colors.ember)
            metricPill("\(Set(models.map(\.accountID)).count)", "accounts", tint: DesignSystem.Colors.textSecondary)
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
        let normalized = catalogProviderID
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        switch normalized {
        case "anthropic", "claude", "claude-code":
            candidates.append(contentsOf: ["AnthropicLogo", "ClaudeCodeLogo"])
        case "openai", "open-ai", "codex":
            candidates.append(contentsOf: ["OpenAILogo", "CodexLogo"])
        case "opencode", "open-code":
            candidates.append("OpenCodeLogo")
        case "google", "gemini", "gemini-cli":
            candidates.append(contentsOf: ["GoogleLogo", "GeminiCLILogo"])
        case "xai", "grok", "x-ai":
            candidates.append("GrokLogo")
        case "deepseek", "deep-seek":
            candidates.append(contentsOf: ["DeepSeekLogo", "DeepSeekProviderLogo"])
        case "mistral":
            candidates.append(contentsOf: ["MistralLogo", "MistralProviderLogo"])
        case "meta", "llama":
            candidates.append(contentsOf: ["MetaLogo", "MetaProviderLogo"])
        case "cohere":
            candidates.append(contentsOf: ["CohereLogo", "CohereProviderLogo"])
        case "amazon", "aws", "bedrock":
            candidates.append(contentsOf: ["AmazonLogo", "AmazonProviderLogo"])
        case "alibaba", "qwen", "dashscope":
            candidates.append(contentsOf: ["QwenLogo", "AlibabaLogo", "AlibabaProviderLogo"])
        case "zai", "z-ai", "z.ai", "glm":
            candidates.append(contentsOf: ["ZaiLogo", "ZaiProviderLogo"])
        case "minimax", "mini-max":
            candidates.append("MiniMaxLogo")
        case "moonshot", "kimi":
            candidates.append(contentsOf: ["KimiLogo", "MoonshotLogo", "KimiProviderLogo"])
        case "mlx":
            candidates.append("MLXLogo")
        case "ollama":
            candidates.append("OllamaLogo")
        case "perplexity":
            candidates.append("PerplexityLogo")
        case "apple":
            candidates.append("AppleLogo")
        default:
            break
        }

        if let registered = BurnBarCatalogProvider.bundledLogoName(forProviderID: normalized) {
            candidates.append(registered)
        }

        candidates.append("\(normalized.capitalized)Logo")

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
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

    private let collapsedLimit = 5

    private var provider: AgentProvider? {
        AgentProvider.fromCatalogProviderID(group.providerID)
    }

    private var visibleModels: [ProxyAdvertisedModel] {
        isExpanded ? group.models : Array(group.models.prefix(collapsedLimit))
    }

    private var hiddenCount: Int {
        max(0, group.models.count - visibleModels.count)
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
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.xs)

            ForEach(visibleModels) { model in
                ProxyModelCatalogRow(model: model)
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

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(routeTint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(model.modelID)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
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
            tag(model.quotaState.replacingOccurrences(of: "_", with: " "), tint: quotaTint)
            tag(model.routeEligible ? "route ready" : "blocked", tint: routeTint)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(model.lastError ?? "\(model.modelID) via \(model.providerName) source \(model.sourceID)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
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

    private var accessibilitySummary: String {
        let route = model.routeEligible ? "route ready" : "blocked"
        let quota = model.quotaState.replacingOccurrences(of: "_", with: " ")
        return "\(model.displayName), \(model.providerName), \(model.accountLabel), \(quota), \(route)"
    }
}

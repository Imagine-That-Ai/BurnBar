import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Popover Quota Bar

/// Always-visible compact quota summary for the popover.
/// Shows every supported provider's 5h + weekly bars inline — no horizontal scroll.
/// Clicking an unavailable/unconfigured row expands an inline setup panel.
struct QuotaPopoverBar: View {
    @Bindable var quotaService: ProviderQuotaService
    @Bindable var settingsManager: SettingsManager
    let dataStore: DataStore
    @State private var expandedProvider: AgentProvider?
    @State private var isWorking = false
    // Local state for inline setup fields
    @State private var localMiniMaxKey = ""
    @State private var localMiniMaxMode: MiniMaxQuotaMode = .tokenPlan
    @State private var localFactoryTier: FactoryQuotaPlanTier = .unknown
    @State private var localZaiKey = ""
    @State private var localCursorCookie = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Header
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("QUOTAS")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Spacer()

                if quotaService.isFetching {
                    ProgressView()
                        .controlSize(.mini)
                }

                Button {
                    Task { await quotaService.refreshAll(dataStore: dataStore) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(quotaService.isFetching)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)

            // Provider rows — each shows logo + dual-window bars + expandable setup
            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(ProviderQuotaService.supportedProviders, id: \.self) { provider in
                    quotaProviderRow(provider: provider)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
        }
        .padding(.top, DesignSystem.Spacing.sm)
        .padding(.bottom, DesignSystem.Spacing.xs)
        .background(
            HStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [DesignSystem.Colors.blaze, DesignSystem.Colors.amber.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                Spacer()
            }
            .background(DesignSystem.Colors.surface.opacity(0.45))
        )
        .task { await quotaService.refreshAll(dataStore: dataStore) }
    }

    @ViewBuilder
    private func quotaProviderRow(provider: AgentProvider) -> some View {
        let snapshot = quotaService.snapshot(for: provider)
        let theme = ProviderTheme.theme(for: provider)
        let isActive = quotaService.isRefreshing(provider)
        let isExpanded = expandedProvider == provider
        let needsSetup = snapshot?.buckets.isEmpty == true && !isActive

        VStack(spacing: 0) {
            // Main row — always visible
            Button {
                if needsSetup || isExpanded {
                    withAnimation(DesignSystem.Animation.gentle) {
                        expandedProvider = isExpanded ? nil : provider
                        if !isExpanded { loadLocalState(for: provider) }
                    }
                }
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    // Provider logo
                    ZStack {
                        Circle()
                            .fill(theme.primaryColor.opacity(needsSetup ? 0.28 : 0.18))
                            .frame(width: 28, height: 28)
                        ProviderLogoView(provider: provider, size: 16, useFallbackColor: false)
                    }

                    // Dual-window bars
                    QuotaDualWindowStrip(
                        hourlyBucket: snapshot?.hourlyBucket,
                        weeklyBucket: snapshot?.weeklyBucket,
                        fallbackBucket: snapshot?.primaryBucket,
                        provider: provider,
                        isActive: isActive
                    )

                    // Setup / action indicator for unconfigured providers
                    if needsSetup {
                        HStack(spacing: DesignSystem.Spacing.xxs) {
                            Text(provider == .claudeCode ? "Unavailable" : "Set up")
                                .font(DesignSystem.Typography.tiny)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(provider == .claudeCode ? DesignSystem.Colors.coral : DesignSystem.Colors.blaze))
                    } else if isExpanded {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    // Activity indicator
                    if isActive {
                        ProviderQuotaActivityBadge(provider: provider, compact: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded inline setup
            if isExpanded {
                providerSetupPanel(provider: provider)
                    .padding(.top, DesignSystem.Spacing.xs)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(DesignSystem.Animation.gentle, value: expandedProvider)
    }

    // MARK: - Provider Setup Panels

    @ViewBuilder
    private func providerSetupPanel(provider: AgentProvider) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Divider().background(DesignSystem.Colors.border)

            switch provider {
            case .claudeCode: claudeSetupPanel
            case .minimax: minimaxSetupPanel
            case .zai: zaiSetupPanel
            case .factory: factorySetupPanel
            case .cursor: cursorSetupPanel
            case .codex: codexSetupPanel
            default:
                Text("No setup available for this provider.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(.leading, DesignSystem.Spacing.xl)
        .padding(.trailing, DesignSystem.Spacing.sm)
        .padding(.bottom, DesignSystem.Spacing.xs)
    }

    @ViewBuilder
    private var claudeSetupPanel: some View {
        let bridgeStatus = quotaService.claudeBridgeStatus

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Bridge status indicator
            HStack(spacing: DesignSystem.Spacing.xs) {
                Circle()
                    .fill(bridgeStatus.isInstalled ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                    .frame(width: 7, height: 7)
                Text(bridgeStatus.state.description)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            Text(bridgeStatus.detailText)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            // Action buttons
            HStack(spacing: DesignSystem.Spacing.sm) {
                switch bridgeStatus.state {
                case .notInstalled:
                    Button("Enable Bridge") {
                        Task { await performClaudeAction(.enable) }
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(isWorking)
                case .ready, .awaitingFirstPayload, .disabledByHooks:
                    Button("Repair") {
                        Task { await performClaudeAction(.repair) }
                    }
                    .buttonStyle(GlassButtonStyle(prominent: false))
                    .disabled(isWorking)

                    Button("Remove") {
                        Task { await performClaudeAction(.remove) }
                    }
                    .buttonStyle(GlassButtonStyle(prominent: false))
                    .disabled(isWorking)
                case .invalidConfiguration:
                    Button("Reconfigure") {
                        Task { await performClaudeAction(.repair) }
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(isWorking)
                }
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var minimaxSetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("API Key")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            SecureField("sk-...", text: $localMiniMaxKey)
                .font(DesignSystem.Typography.monoSmall)
                .textFieldStyle(.plain)
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                )

            Text("Billing mode")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Picker("", selection: $localMiniMaxMode) {
                ForEach(MiniMaxQuotaMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Save") { Task { await saveAndRefresh(for: .minimax) } }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(isWorking)
                Button("Cancel") { expandedProvider = nil }
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var zaiSetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("API Key")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            SecureField("sk-...", text: $localZaiKey)
                .font(DesignSystem.Typography.monoSmall)
                .textFieldStyle(.plain)
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                )

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Save") { Task { await saveAndRefresh(for: .zai) } }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(isWorking)
                Button("Cancel") { expandedProvider = nil }
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var factorySetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Plan tier")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Picker("", selection: $localFactoryTier) {
                ForEach(FactoryQuotaPlanTier.allCases) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Save") { Task { await saveAndRefresh(for: .factory) } }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(isWorking)
                Button("Cancel") { expandedProvider = nil }
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var cursorSetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Session Cookie")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            SecureField("Paste cookie value...", text: $localCursorCookie)
                .font(DesignSystem.Typography.monoSmall)
                .textFieldStyle(.plain)
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                )

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Save") { Task { await saveAndRefresh(for: .cursor) } }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(isWorking)
                Button("Cancel") { expandedProvider = nil }
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var codexSetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Codex quota is read automatically from your local Codex session logs.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func loadLocalState(for provider: AgentProvider) {
        let ks = ProviderAPIKeyStore.shared
        switch provider {
        case .minimax:
            localMiniMaxKey = ks.apiKey(for: "minimax") ?? ""
            localMiniMaxMode = settingsManager.miniMaxQuotaMode
        case .zai:
            localZaiKey = ks.apiKey(for: "zai") ?? ""
        case .cursor:
            localCursorCookie = ks.apiKey(for: "cursor_cookie") ?? ""
        case .factory:
            localFactoryTier = settingsManager.factoryQuotaPlanTier
        default:
            break
        }
    }

    private func saveAndRefresh(for provider: AgentProvider) async {
        isWorking = true
        defer { isWorking = false }

        let ks = ProviderAPIKeyStore.shared
        switch provider {
        case .minimax:
            do {
                let trimmed = localMiniMaxKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { try ks.removeAPIKey(for: "minimax") }
                else { try ks.setAPIKey(trimmed, for: "minimax") }
                settingsManager.miniMaxQuotaMode = localMiniMaxMode
            } catch {
                AppLogger.dataStore.silentFailure("saveAPIKey(minimax)", error: error)
            }
        case .zai:
            do {
                let trimmed = localZaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { try ks.removeAPIKey(for: "zai") }
                else { try ks.setAPIKey(trimmed, for: "zai") }
            } catch {
                AppLogger.dataStore.silentFailure("saveAPIKey(zai)", error: error)
            }
        case .cursor:
            do {
                let trimmed = localCursorCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { try ks.removeAPIKey(for: "cursor_cookie") }
                else { try ks.setAPIKey(trimmed, for: "cursor_cookie") }
            } catch {
                AppLogger.dataStore.silentFailure("saveAPIKey(cursor_cookie)", error: error)
            }
        case .factory:
            settingsManager.factoryQuotaPlanTier = localFactoryTier
        default:
            break
        }

        await quotaService.refresh(provider: provider, dataStore: dataStore)
        expandedProvider = nil
    }

    private func performClaudeAction(_ action: QuotaRowAction) async {
        isWorking = true
        defer { isWorking = false }

        switch action {
        case .enable:
            try? quotaService.installClaudeQuotaBridge()
            await quotaService.refresh(provider: .claudeCode, dataStore: dataStore)
        case .repair:
            try? quotaService.removeClaudeQuotaBridge()
            try? quotaService.installClaudeQuotaBridge()
            await quotaService.refresh(provider: .claudeCode, dataStore: dataStore)
        case .remove:
            try? quotaService.removeClaudeQuotaBridge()
            await quotaService.refresh(provider: .claudeCode, dataStore: dataStore)
        }

        // Collapse if quota is now working
        if quotaService.snapshot(for: .claudeCode)?.buckets.isEmpty == false {
            expandedProvider = nil
        }
    }
}

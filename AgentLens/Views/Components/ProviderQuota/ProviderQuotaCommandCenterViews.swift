import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Menu bar popover strip

/// Compact quota glance at the top of the menu bar tray.
struct ProviderQuotaPopoverStrip: View {
    @Bindable private var quotaService = ProviderQuotaService.shared
    let dataStore: DataStore

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Provider quotas")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, DesignSystem.Spacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(ProviderQuotaService.supportedProviders, id: \.self) { provider in
                        popoverQuotaChip(provider: provider)
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.bottom, DesignSystem.Spacing.xs)
            }
        }
        .padding(.top, DesignSystem.Spacing.sm)
        .padding(.bottom, DesignSystem.Spacing.xs)
        .background(DesignSystem.Colors.surface.opacity(0.45))
        .task {
            await quotaService.refreshAll(dataStore: dataStore)
        }
    }

    private func popoverQuotaChip(provider: AgentProvider) -> some View {
        let snapshot = quotaService.snapshot(for: provider)
        let theme = ProviderTheme.theme(for: provider)
        let isActive = quotaService.isRefreshing(provider)
        let line = snapshot?.summaryText
            ?? snapshot?.statusMessage
            ?? (isActive ? "Refreshing…" : "No signal yet")

        return VStack(spacing: DesignSystem.Spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(theme.primaryColor.opacity(0.14))
                    .frame(width: 40, height: 40)
                ProviderLogoView(provider: provider, size: 22, useFallbackColor: false)
            }

            Text(line)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(width: 92, alignment: .top)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
        )
    }
}

// MARK: - Quota Command Center

/// Full-width quota glance + inline setup at the top of the menu bar popover.
struct QuotaCommandCenter: View {
    @Bindable var quotaService: ProviderQuotaService
    @Bindable var settingsManager: SettingsManager
    let dataStore: DataStore
    @State private var expandedProvider: AgentProvider?
    @State private var localMiniMaxKey = ""
    @State private var localMiniMaxMode: MiniMaxQuotaMode = .tokenPlan
    @State private var localFactoryTier: FactoryQuotaPlanTier = .unknown
    @State private var localZaiKey = ""
    @State private var localCursorCookie = ""
    @State private var isWorking = false

    private var providers: [AgentProvider] {
        ProviderQuotaService.supportedProviders
    }

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
                        .padding(.trailing, DesignSystem.Spacing.xs)
                }

                Button {
                    Task {
                        await quotaService.refreshAll(dataStore: dataStore)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(quotaService.isFetching)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)

            // Horizontal scrolling rows
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(providers, id: \.self) { provider in
                        QuotaCommandRow(
                            provider: provider,
                            quotaService: quotaService,
                            settingsManager: settingsManager,
                            dataStore: dataStore,
                            isExpanded: expandedProvider == provider,
                            localMiniMaxKey: $localMiniMaxKey,
                            localMiniMaxMode: $localMiniMaxMode,
                            localFactoryTier: $localFactoryTier,
                            localZaiKey: $localZaiKey,
                            localCursorCookie: $localCursorCookie,
                            isWorking: isWorking,
                            onToggle: {
                                if expandedProvider == provider {
                                    expandedProvider = nil
                                } else {
                                    expandedProvider = provider
                                    loadLocalState(for: provider)
                                }
                            },
                            onSave: {
                                Task { await saveAndRefresh(for: provider) }
                            },
                            onAction: { action in
                                Task { await performAction(action, for: provider) }
                            }
                        )
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
            }
        }
        .padding(.top, DesignSystem.Spacing.sm)
        .padding(.bottom, DesignSystem.Spacing.xs)
        .background(
            // Blaze left accent bar
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
        .task {
            await quotaService.refreshAll(dataStore: dataStore)
        }
    }

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
                if trimmed.isEmpty {
                    try ks.removeAPIKey(for: "minimax")
                } else {
                    try ks.setAPIKey(trimmed, for: "minimax")
                }
                settingsManager.miniMaxQuotaMode = localMiniMaxMode
            } catch {
                // silently fail
            }
        case .zai:
            do {
                let trimmed = localZaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    try ks.removeAPIKey(for: "zai")
                } else {
                    try ks.setAPIKey(trimmed, for: "zai")
                }
            } catch {
                // silently fail
            }
        case .cursor:
            do {
                let trimmed = localCursorCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    try ks.removeAPIKey(for: "cursor_cookie")
                } else {
                    try ks.setAPIKey(trimmed, for: "cursor_cookie")
                }
            } catch {
                // silently fail
            }
        case .factory:
            settingsManager.factoryQuotaPlanTier = localFactoryTier
        default:
            break
        }

        await quotaService.refresh(provider: provider, dataStore: dataStore)
        expandedProvider = nil
    }

    private func performAction(_ action: QuotaRowAction, for provider: AgentProvider) async {
        isWorking = true
        defer { isWorking = false }

        switch (provider, action) {
        case (.claudeCode, .enable):
            try? quotaService.installClaudeQuotaBridge()
            await quotaService.refresh(provider: provider, dataStore: dataStore)
        case (.claudeCode, .repair):
            try? quotaService.removeClaudeQuotaBridge()
            try? quotaService.installClaudeQuotaBridge()
            await quotaService.refresh(provider: provider, dataStore: dataStore)
        case (.claudeCode, .remove):
            try? quotaService.removeClaudeQuotaBridge()
            await quotaService.refresh(provider: provider, dataStore: dataStore)
        default:
            break
        }
    }
}

// MARK: - Row Actions

enum QuotaRowAction {
    case enable
    case repair
    case remove
}

// MARK: - Quota Command Row

struct QuotaCommandRow: View {
    let provider: AgentProvider
    @Bindable var quotaService: ProviderQuotaService
    @Bindable var settingsManager: SettingsManager
    let dataStore: DataStore
    let isExpanded: Bool
    @Binding var localMiniMaxKey: String
    @Binding var localMiniMaxMode: MiniMaxQuotaMode
    @Binding var localFactoryTier: FactoryQuotaPlanTier
    @Binding var localZaiKey: String
    @Binding var localCursorCookie: String
    let isWorking: Bool
    let onToggle: () -> Void
    let onSave: () -> Void
    let onAction: (QuotaRowAction) -> Void

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var snapshot: ProviderQuotaSnapshot? { quotaService.snapshot(for: provider) }
    private var isRefreshing: Bool { quotaService.isRefreshing(provider) }
    private var isUnconfigured: Bool { snapshot?.buckets.isEmpty == true }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Collapsed row
            Button(action: onToggle) {
                collapsedRowContent
            }
            .buttonStyle(.plain)
            .frame(width: 180)

            // Expanded inline setup
            if isExpanded {
                expandedSetupContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            theme.primaryColor.opacity(isUnconfigured ? 0.3 : 0.2),
                            theme.primaryColor.opacity(isUnconfigured ? 0.1 : 0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .animation(DesignSystem.Animation.standard, value: isExpanded)
    }

    @ViewBuilder
    private var collapsedRowContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                // Provider logo
                ZStack {
                    Circle()
                        .fill(theme.primaryColor.opacity(0.18))
                        .frame(width: 36, height: 36)
                    ProviderLogoView(provider: provider, size: 20, useFallbackColor: false)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(providerTitle)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    if let primaryBucket = snapshot?.primaryBucket {
                        Text(primaryBucket.remainingText + " left")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(theme.primaryColor)
                            .lineLimit(1)
                    } else {
                        Text(statusLine)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            QuotaDualWindowStrip(
                hourlyBucket: snapshot?.hourlyBucket,
                weeklyBucket: snapshot?.weeklyBucket,
                fallbackBucket: snapshot?.primaryBucket,
                provider: provider,
                isActive: isRefreshing
            )

            if isUnconfigured {
                setupBadge
            }
        }
    }

    @ViewBuilder
    private var setupBadge: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Text("Set up")
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.blaze)
        )
    }

    @ViewBuilder
    private var expandedSetupContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Divider().background(DesignSystem.Colors.border)

            switch provider {
            case .minimax:
                minimaxSetup
            case .zai:
                zaiSetup
            case .factory:
                factorySetup
            case .cursor:
                cursorSetup
            case .claudeCode:
                claudeSetup
            case .codex:
                codexSetup
            default:
                Text("No inline setup available.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    @ViewBuilder
    private var minimaxSetup: some View {
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
                Button("Save") {
                    onSave()
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .disabled(isWorking)

                Button("Cancel") {
                    onToggle()
                }
                .buttonStyle(GlassButtonStyle(prominent: false))
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var zaiSetup: some View {
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
                Button("Save") {
                    onSave()
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .disabled(isWorking)

                Button("Cancel") {
                    onToggle()
                }
                .buttonStyle(GlassButtonStyle(prominent: false))
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var cursorSetup: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Cookie header")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            SecureField("session=…; access-token=…", text: $localCursorCookie)
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

            Text("Paste a `Cookie:` header from a signed-in `cursor.com` request to fetch billing-cycle quota.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text("OpenBurnBar stores this header in the local macOS Keychain and only uses it for explicit Cursor quota requests.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Save") {
                    onSave()
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .disabled(isWorking)

                Button("Cancel") {
                    onToggle()
                }
                .buttonStyle(GlassButtonStyle(prominent: false))
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var factorySetup: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Plan tier")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Picker("", selection: $localFactoryTier) {
                ForEach(FactoryQuotaPlanTier.allCases) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Save") {
                    onSave()
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .disabled(isWorking)

                Button("Cancel") {
                    onToggle()
                }
                .buttonStyle(GlassButtonStyle(prominent: false))
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var claudeSetup: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            let bridgeStatus = quotaService.claudeBridgeStatus

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

            HStack(spacing: DesignSystem.Spacing.sm) {
                switch bridgeStatus.state {
                case .notInstalled:
                    Button("Enable Bridge") {
                        onAction(.enable)
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(isWorking)
                case .ready, .awaitingFirstPayload, .disabledByHooks:
                    Button("Repair") {
                        onAction(.repair)
                    }
                    .buttonStyle(GlassButtonStyle(prominent: false))
                    .disabled(isWorking)

                    Button("Remove") {
                        onAction(.remove)
                    }
                    .buttonStyle(GlassButtonStyle(prominent: false))
                    .disabled(isWorking)
                case .invalidConfiguration:
                    Button("Reconfigure") {
                        onAction(.repair)
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(isWorking)
                }
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    @ViewBuilder
    private var codexSetup: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Codex quota is read automatically from your local Codex session logs.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let msg = snapshot?.statusMessage {
                Text(msg)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerTitle: String {
        switch provider {
        case .factory: return "Factory / Droid"
        case .zai: return "Z.ai"
        default: return provider.displayName
        }
    }

    private var statusLine: String {
        if isRefreshing { return "Refreshing..." }
        return snapshot?.statusMessage ?? "No signal yet"
    }
}

// MARK: - Claude Bridge State Description

extension ClaudeQuotaBridgeStatus.State {
    var description: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .awaitingFirstPayload: return "Waiting for first response"
        case .ready: return "Bridge active"
        case .disabledByHooks: return "Hooks disabled"
        case .invalidConfiguration: return "Needs reconfiguration"
        }
    }
}

// MARK: - Glass Button Style for rows

struct GlassButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(prominent ? DesignSystem.Colors.blaze : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                if prominent {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.blaze.opacity(0.15))
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.blaze.opacity(0.3), lineWidth: 0.5)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.surface.opacity(0.5))
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
                    }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(DesignSystem.Animation.snappy, value: configuration.isPressed)
    }
}

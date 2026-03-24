import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

struct ProviderQuotaSettingsSection: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("Quota reporting stays separate from spend history. BurnBar uses official APIs where they exist and otherwise shows the best verifiable local signal it can: Codex rollout snapshots, Claude statusline JSON, and Factory / Droid monthly token estimates. Review provider-level quota here or in each provider dashboard.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            ForEach(ProviderQuotaService.supportedProviders, id: \.self) { provider in
                ProviderQuotaSettingsCard(
                    provider: provider,
                    settingsManager: settingsManager,
                    quotaService: quotaService,
                    dataStore: dataStore
                )
            }
        }
        .task {
            await quotaService.refreshIfNeeded(dataStore: dataStore)
        }
    }
}

struct ProviderQuotaOverviewPanel: View {
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore
    let onSelectProvider: (AgentProvider) -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Quota Watch")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("Review remaining quota across supported providers. Select a provider row for bucket-level detail.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }

                    Spacer()
                }

                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(ProviderQuotaService.supportedProviders, id: \.self) { provider in
                        quotaRow(for: provider)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .task {
            await quotaService.refreshIfNeeded(dataStore: dataStore)
        }
    }

    private func quotaRow(for provider: AgentProvider) -> some View {
        let snapshot = quotaService.snapshot(for: provider)
        let theme = ProviderTheme.theme(for: provider)

        return Button {
            onSelectProvider(provider)
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.primaryColor.opacity(0.14))
                        .frame(width: 34, height: 34)
                    ProviderLogoView(provider: provider, size: 22, useFallbackColor: false)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(provider == .factory ? "Factory / Droid" : provider.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(snapshot?.summaryText ?? snapshot?.statusMessage ?? "No quota snapshot yet.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if let snapshot {
                    QuotaSourceBadge(source: snapshot.source, confidence: snapshot.confidence)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(theme.primaryColor.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }
}

struct ProviderDashboardQuotaPanel: View {
    let provider: AgentProvider
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore

    private var snapshot: ProviderQuotaSnapshot? {
        quotaService.snapshot(for: provider)
    }

    var body: some View {
        if ProviderQuotaService.supportedProviders.contains(provider) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("Quota")
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)

                            Text(snapshot?.summaryText ?? "Checking current quota…")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }

                        Spacer()

                        if let snapshot {
                            QuotaSourceBadge(source: snapshot.source, confidence: snapshot.confidence)
                        }
                    }

                    if let snapshot, !snapshot.buckets.isEmpty {
                        VStack(spacing: DesignSystem.Spacing.sm) {
                            ForEach(snapshot.buckets) { bucket in
                                ProviderQuotaBucketRow(bucket: bucket, provider: provider)
                            }
                        }
                    } else if let error = quotaService.errors[provider] {
                        Text(error)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.warning)
                    } else {
                        Text(snapshot?.statusMessage ?? "No quota snapshot yet.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }

                    HStack(spacing: DesignSystem.Spacing.md) {
                        Text(snapshotFreshness)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(
                                (snapshot?.isStale() ?? false)
                                    ? DesignSystem.Colors.warning
                                    : DesignSystem.Colors.textMuted
                            )

                        Spacer()

                        if let url = snapshot?.managementLink {
                            Button("Manage in provider") {
                                open(url: url)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .task {
                await quotaService.refreshIfNeeded(dataStore: dataStore)
            }
        }
    }

    private var snapshotFreshness: String {
        guard let snapshot else { return "No snapshot yet" }
        let prefix = snapshot.isStale() ? "Stale" : "Updated"
        return "\(prefix) \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func open(url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

private struct ProviderQuotaSettingsCard: View {
    let provider: AgentProvider
    @Bindable var settingsManager: SettingsManager
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore

    @State private var isWorking = false

    private var snapshot: ProviderQuotaSnapshot? {
        quotaService.snapshot(for: provider)
    }

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.primaryColor.opacity(0.14))
                                .frame(width: 34, height: 34)
                            ProviderLogoView(provider: provider, size: 22, useFallbackColor: false)
                        }

                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text(providerTitle)
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)

                            Text(snapshot?.summaryText ?? statusLine)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()

                    if let snapshot {
                        QuotaSourceBadge(source: snapshot.source, confidence: snapshot.confidence)
                    }
                }

                if let snapshot, !snapshot.buckets.isEmpty {
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        ForEach(snapshot.buckets) { bucket in
                            ProviderQuotaBucketRow(bucket: bucket, provider: provider)
                        }
                    }
                } else {
                    Text(statusLine)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(provider == .claudeCode ? DesignSystem.Colors.warning : DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = quotaService.errors[provider] {
                    Text(error)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let snapshot {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        Text(snapshotMetadata(snapshot))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(
                                snapshot.isStale()
                                    ? DesignSystem.Colors.warning
                                    : DesignSystem.Colors.textMuted
                            )
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()

                        if let url = snapshot.managementLink {
                            Button("Manage") {
                                open(url: url)
                            }
                            .buttonStyle(.link)
                        }
                    }
                } else if provider == .claudeCode {
                    Text(quotaService.claudeBridgeStatus.detailText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                controls
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch provider {
        case .claudeCode:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    GlassButton(
                        title: quotaService.claudeBridgeStatus.isInstalled ? "Repair Bridge" : "Enable Bridge",
                        icon: quotaService.claudeBridgeStatus.isInstalled ? "wrench.and.screwdriver" : "bolt.horizontal.circle",
                        style: .prominent
                    ) {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            try? quotaService.installClaudeQuotaBridge()
                            await quotaService.refresh(provider: .claudeCode, dataStore: dataStore)
                        }
                    }

                    if quotaService.claudeBridgeStatus.isInstalled {
                        GlassButton(title: "Remove", icon: "trash", style: .regular) {
                            Task {
                                isWorking = true
                                defer { isWorking = false }
                                try? quotaService.removeClaudeQuotaBridge()
                                await quotaService.refresh(provider: .claudeCode, dataStore: dataStore)
                            }
                        }
                    }
                }
                .disabled(isWorking)
            }

        case .minimax:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Billing mode")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Picker("MiniMax billing mode", selection: $settingsManager.miniMaxQuotaMode) {
                    ForEach(MiniMaxQuotaMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settingsManager.miniMaxQuotaMode) { _, _ in
                    Task {
                        await quotaService.refresh(provider: .minimax, dataStore: dataStore)
                    }
                }
            }

        case .factory:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Plan tier")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Picker("Factory plan tier", selection: $settingsManager.factoryQuotaPlanTier) {
                    ForEach(FactoryQuotaPlanTier.allCases) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: settingsManager.factoryQuotaPlanTier) { _, _ in
                    Task {
                        await quotaService.refresh(provider: .factory, dataStore: dataStore)
                    }
                }
            }

        default:
            EmptyView()
        }
    }

    private var providerTitle: String {
        if provider == .factory {
            return "Factory / Droid"
        }
        if provider == .zai {
            return "Z.ai"
        }
        return provider.displayName
    }

    private var statusLine: String {
        if provider == .claudeCode {
            return quotaService.claudeBridgeStatus.detailText
        }
        return snapshot?.statusMessage ?? "No quota snapshot yet."
    }

    private func snapshotMetadata(_ snapshot: ProviderQuotaSnapshot) -> String {
        let freshnessPrefix = snapshot.isStale() ? "Stale" : "Updated"
        return "\(freshnessPrefix) \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.statusMessage)"
    }

    private func open(url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

private struct ProviderQuotaBucketRow: View {
    let bucket: ProviderQuotaBucket
    let provider: AgentProvider

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(bucket.label)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Spacer()

                Text(bucket.remainingText)
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(theme.gradient)
            }

            ProgressView(value: bucket.progressFraction)
                .tint(theme.primaryColor)

            HStack(spacing: DesignSystem.Spacing.md) {
                Text(bucket.usageText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                if let resetsAt = bucket.resetsAt {
                    Text("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                if bucket.isEstimated {
                    Text("Estimated")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                }

                Spacer()
            }
        }
    }
}

private struct QuotaSourceBadge: View {
    let source: ProviderQuotaSourceKind
    let confidence: ProviderQuotaConfidence

    private var foreground: Color {
        switch confidence {
        case .exact: return DesignSystem.Colors.success
        case .estimated: return DesignSystem.Colors.warning
        case .unavailable: return DesignSystem.Colors.textMuted
        }
    }

    var body: some View {
        Text(source.label)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(foreground)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 6)
            .background(foreground.opacity(0.08))
            .clipShape(.capsule)
    }
}

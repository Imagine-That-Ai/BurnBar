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
        let isActive = quotaService.isRefreshing(provider)
        let summaryText = snapshot?.summaryText
            ?? snapshot?.statusMessage
            ?? (isActive ? "Refreshing quota signal…" : "No quota snapshot yet.")

        return Button {
            onSelectProvider(provider)
        } label: {
            HStack(spacing: DesignSystem.Spacing.lg) {
                ProviderQuotaIdentityOrb(provider: provider, isActive: isActive)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(provider == .factory ? "Factory / Droid" : provider.displayName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(summaryText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }

                Spacer()

                Group {
                    if let primaryBucket = snapshot?.primaryBucket {
                        QuotaSignalView(bucket: primaryBucket, provider: provider, compact: true)
                            .frame(width: 126, height: 68)
                    } else {
                        QuotaSignalPlaceholder(provider: provider, isActive: isActive, compact: true)
                            .frame(width: 126, height: 68)
                    }
                }
                .padding(.trailing, DesignSystem.Spacing.xs)

                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                    if isActive {
                        ProviderQuotaActivityBadge(provider: provider, compact: true)
                    }

                    if let snapshot {
                        QuotaSourceBadge(source: snapshot.source, confidence: snapshot.confidence)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.md)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.56))

                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.primaryColor.opacity(isActive ? 0.18 : 0.10),
                                    theme.accentColor.opacity(0.08),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .stroke(theme.primaryColor.opacity(isActive ? 0.26 : 0.12), lineWidth: 1)
            )
            .shadow(color: theme.primaryColor.opacity(isActive ? 0.16 : 0.06), radius: isActive ? 18 : 8, y: 6)
        }
        .buttonStyle(.plain)
        .animation(DesignSystem.Animation.gentle, value: isActive)
    }
}

struct ProviderDashboardQuotaPanel: View {
    let provider: AgentProvider
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore

    private var snapshot: ProviderQuotaSnapshot? {
        quotaService.snapshot(for: provider)
    }

    private var isRefreshing: Bool {
        quotaService.isRefreshing(provider)
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

                        VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                            if isRefreshing {
                                ProviderQuotaActivityBadge(provider: provider)
                            }

                            if let snapshot {
                                QuotaSourceBadge(source: snapshot.source, confidence: snapshot.confidence)
                            }
                        }
                    }

                    if let snapshot, !snapshot.buckets.isEmpty {
                        VStack(spacing: DesignSystem.Spacing.md) {
                            ForEach(snapshot.buckets) { bucket in
                                ProviderQuotaBucketRow(bucket: bucket, provider: provider)
                            }
                        }
                    } else {
                        QuotaStatusCallout(
                            provider: provider,
                            title: isRefreshing
                                ? "Gathering live quota"
                                : (quotaService.errors[provider] != nil ? "Could not refresh quota" : "Quota signal not ready"),
                            message: quotaService.errors[provider]
                                ?? snapshot?.statusMessage
                                ?? "No quota snapshot yet.",
                            isActive: isRefreshing,
                            isWarning: quotaService.errors[provider] != nil
                        )
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

    private var isRefreshing: Bool {
        quotaService.isRefreshing(provider)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        ProviderQuotaIdentityOrb(provider: provider, isActive: isRefreshing)

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

                    VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                        if isRefreshing {
                            ProviderQuotaActivityBadge(provider: provider)
                        }

                        if let snapshot {
                            QuotaSourceBadge(source: snapshot.source, confidence: snapshot.confidence)
                        }
                    }
                }

                if let snapshot, !snapshot.buckets.isEmpty {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(snapshot.buckets) { bucket in
                            ProviderQuotaBucketRow(bucket: bucket, provider: provider)
                        }
                    }
                } else {
                    QuotaStatusCallout(
                        provider: provider,
                        title: quotaStatusCalloutTitle,
                        message: quotaService.errors[provider] ?? statusLine,
                        isActive: isRefreshing,
                        isWarning: quotaStatusCalloutWarning
                    )
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

    private var quotaStatusCalloutTitle: String {
        if isRefreshing {
            return "Refreshing provider signal"
        }
        if quotaService.errors[provider] != nil {
            return "Refresh needs attention"
        }
        if provider == .claudeCode {
            switch quotaService.claudeBridgeStatus.state {
            case .awaitingFirstPayload:
                return "Waiting for first Claude response"
            case .disabledByHooks:
                return "Claude hooks are disabled"
            case .invalidConfiguration:
                return "Claude bridge needs reconfiguration"
            case .ready:
                return "Claude bridge connected"
            case .notInstalled:
                return "Readable quota not available yet"
            }
        }
        return "Readable quota not available yet"
    }

    private var quotaStatusCalloutWarning: Bool {
        if quotaService.errors[provider] != nil {
            return true
        }
        guard provider == .claudeCode else {
            return false
        }
        switch quotaService.claudeBridgeStatus.state {
        case .disabledByHooks, .invalidConfiguration:
            return true
        case .notInstalled, .awaitingFirstPayload, .ready:
            return false
        }
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
    private var signalStatus: QuotaSignalStatus {
        QuotaSignalStatus.resolve(bucket: bucket, theme: theme)
    }
    private var windowBadgeText: String? {
        switch bucket.windowKind {
        case .rollingHours: return "Rolling hours"
        case .rollingDays: return "Rolling days"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .custom: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text(bucket.label)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        QuotaMicroBadge(text: signalStatus.label, tint: signalStatus.tint)

                        if let windowBadgeText {
                            QuotaMicroBadge(text: windowBadgeText, tint: theme.primaryColor)
                        }
                    }

                    Text(bucket.usageText)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                QuotaFigureTile(bucket: bucket, provider: provider)
            }

            QuotaSignalView(bucket: bucket, provider: provider)
                .frame(height: 104)

            HStack(spacing: DesignSystem.Spacing.sm) {
                if let resetsAt = bucket.resetsAt {
                    QuotaMicroBadge(
                        text: "Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))",
                        tint: DesignSystem.Colors.textMuted
                    )
                }

                if bucket.isEstimated {
                    QuotaMicroBadge(text: "Estimated", tint: DesignSystem.Colors.warning)
                }

                Spacer()
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.48))

                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryColor.opacity(0.10),
                                theme.accentColor.opacity(0.05),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct QuotaFigureTile: View {
    let bucket: ProviderQuotaBucket
    let provider: AgentProvider

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var descriptor: String {
        switch bucket.unit {
        case .percent:
            return "window left"
        case .requests:
            return "requests left"
        case .tokens:
            return "tokens left"
        case .count:
            return "remaining"
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(descriptor.uppercased())
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(bucket.remainingText)
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.gradient)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(bucket.usageText)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.78))
                .lineLimit(1)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct QuotaStatusCallout: View {
    let provider: AgentProvider
    let title: String
    let message: String
    let isActive: Bool
    let isWarning: Bool

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var tint: Color { isWarning ? DesignSystem.Colors.warning : theme.primaryColor }
    private var iconName: String { isWarning ? "exclamationmark.triangle.fill" : "sparkles" }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .frame(width: 42, height: 42)

                if isActive {
                    AnimatedMiningPickView()
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            QuotaSignalPlaceholder(provider: provider, isActive: isActive, compact: true)
                .frame(width: 138, height: 76)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(tint.opacity(isWarning ? 0.24 : 0.14), lineWidth: 1)
        )
    }
}

private struct ProviderQuotaIdentityOrb: View {
    let provider: AgentProvider
    let isActive: Bool

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.primaryColor.opacity(0.22),
                            theme.accentColor.opacity(0.12),
                            DesignSystem.Colors.surfaceElevated.opacity(0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(theme.accentColor.opacity(isActive ? 0.22 : 0.12))
                .frame(width: 18, height: 18)
                .blur(radius: isActive ? 10 : 6)
                .offset(x: 10, y: -10)

            Circle()
                .stroke(theme.primaryColor.opacity(isActive ? 0.36 : 0.18), lineWidth: 1)

            ProviderLogoView(provider: provider, size: 22, useFallbackColor: false)
        }
        .frame(width: 42, height: 42)
        .shadow(color: theme.primaryColor.opacity(isActive ? 0.20 : 0.08), radius: isActive ? 18 : 8, y: 5)
        .overlay(alignment: .bottomTrailing) {
            if isActive {
                Circle()
                    .fill(DesignSystem.Colors.amber)
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle()
                            .stroke(DesignSystem.Colors.surface, lineWidth: 1.5)
                    )
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(DesignSystem.Animation.gentle, value: isActive)
    }
}

private struct ProviderQuotaActivityBadge: View {
    let provider: AgentProvider
    var compact = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    var body: some View {
        HStack(spacing: compact ? 6 : DesignSystem.Spacing.sm) {
            AnimatedMiningPickView()
                .frame(width: compact ? 20 : 26, height: compact ? 20 : 26)
                .clipShape(.circle)

            if !compact {
                Text("At work")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(theme.gradient)
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 6)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.primaryColor.opacity(0.16),
                            theme.accentColor.opacity(0.10)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
        .overlay(
            Capsule()
                .stroke(theme.primaryColor.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) quota refresh in progress")
    }
}

private struct QuotaSignalStatus {
    let label: String
    let detail: String
    let tint: Color

    static func resolve(bucket: ProviderQuotaBucket, theme: ProviderTheme) -> QuotaSignalStatus {
        let pressure = min(max(bucket.progressFraction, 0), 1)

        switch pressure {
        case ..<0.20:
            return QuotaSignalStatus(
                label: "Wide Open",
                detail: "Plenty of headroom in this window.",
                tint: theme.primaryColor
            )
        case ..<0.46:
            return QuotaSignalStatus(
                label: "Comfortable",
                detail: "Healthy reserve remains.",
                tint: theme.accentColor
            )
        case ..<0.74:
            return QuotaSignalStatus(
                label: "Narrowing",
                detail: "Reserve is thinning.",
                tint: DesignSystem.Colors.amber
            )
        default:
            return QuotaSignalStatus(
                label: "Near Edge",
                detail: "Close to the active cap.",
                tint: DesignSystem.Colors.warning
            )
        }
    }
}

private struct QuotaSignalView: View {
    let bucket: ProviderQuotaBucket
    let provider: AgentProvider
    var compact = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var remainingFraction: Double {
        if let remainingPercent = bucket.remainingPercent {
            return min(max(remainingPercent / 100, 0), 1)
        }
        return min(max(1 - bucket.progressFraction, 0), 1)
    }
    private var signalStatus: QuotaSignalStatus {
        QuotaSignalStatus.resolve(bucket: bucket, theme: theme)
    }

    private var fillColor: Color {
        switch remainingFraction {
        case 0.75...: return theme.primaryColor
        case 0.50..<0.75: return theme.primaryColor.opacity(0.72)
        case 0.25..<0.50: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.warning
        }
    }

    private var fillGradient: LinearGradient {
        switch remainingFraction {
        case 0.75...:
            return LinearGradient(
                colors: [theme.primaryColor, theme.accentColor],
                startPoint: .leading,
                endPoint: .trailing
            )
        case 0.50..<0.75:
            return LinearGradient(
                colors: [theme.primaryColor.opacity(0.72), theme.accentColor.opacity(0.56)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case 0.25..<0.50:
            return LinearGradient(
                colors: [theme.primaryColor.opacity(0.48), DesignSystem.Colors.amber],
                startPoint: .leading,
                endPoint: .trailing
            )
        default:
            return LinearGradient(
                colors: [DesignSystem.Colors.amber, DesignSystem.Colors.warning],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var batteryHeight: CGFloat { compact ? 28 : 36 }
    private var batteryRadius: CGFloat { compact ? 6 : 8 }
    private var terminalWidth: CGFloat { compact ? 4 : 5 }
    private var terminalHeight: CGFloat { batteryHeight * 0.38 }
    private var cornerRadius: CGFloat { compact ? 14 : 16 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.surface.opacity(0.96),
                            DesignSystem.Colors.surfaceElevated.opacity(0.92),
                            theme.primaryColor.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                    Text(signalStatus.label.uppercased())
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(signalStatus.tint.opacity(0.86))

                    if compact {
                        Spacer()
                        Text(bucket.remainingText)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(fillColor)
                    }
                }

                if !compact {
                    Text(signalStatus.detail)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary.opacity(0.82))
                }

                // Battery bar
                HStack(spacing: 0) {
                    // Battery body
                    ZStack(alignment: .leading) {
                        // Track (empty shell)
                        RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                                    .stroke(fillColor.opacity(0.22), lineWidth: 1.5)
                            )

                        // Fill bar
                        GeometryReader { geo in
                            let fillWidth = max(geo.size.width * remainingFraction, batteryRadius * 2)

                            RoundedRectangle(cornerRadius: batteryRadius - 1.5, style: .continuous)
                                .fill(fillGradient)
                                .frame(width: remainingFraction > 0.02 ? fillWidth : 0)
                                .padding(2)
                                .shadow(color: fillColor.opacity(0.35), radius: 6, y: 0)
                        }
                    }
                    .frame(height: batteryHeight)

                    // Terminal nub
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(fillColor.opacity(0.32))
                        .frame(width: terminalWidth, height: terminalHeight)
                        .padding(.leading, 2)
                }

                if !compact {
                    HStack {
                        Text(bucket.remainingText + " remaining")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(fillColor)

                        Spacer()

                        Text(bucket.usageText)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
            .padding(compact ? 10 : 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.primaryColor.opacity(compact ? 0.14 : 0.18), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) quota: \(bucket.remainingText) remaining")
    }
}

private struct QuotaSignalPlaceholder: View {
    let provider: AgentProvider
    let isActive: Bool
    var compact = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }
    private var cornerRadius: CGFloat { compact ? 14 : 16 }
    private var batteryHeight: CGFloat { compact ? 28 : 36 }
    private var batteryRadius: CGFloat { compact ? 6 : 8 }
    private var terminalWidth: CGFloat { compact ? 4 : 5 }
    private var terminalHeight: CGFloat { batteryHeight * 0.38 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.surface.opacity(0.95),
                            DesignSystem.Colors.surfaceElevated.opacity(0.90),
                            theme.primaryColor.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                Text(isActive ? "REFRESHING" : "NO SIGNAL YET")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                if !compact {
                    Text(isActive ? "Provider at work" : "Waiting for quota data")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                // Empty battery shell
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: batteryRadius, style: .continuous)
                                .stroke(
                                    theme.primaryColor.opacity(isActive ? 0.22 : 0.12),
                                    style: StrokeStyle(lineWidth: 1.5, dash: isActive ? [4, 4] : [])
                                )
                        )
                        .frame(height: batteryHeight)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.primaryColor.opacity(0.14))
                        .frame(width: terminalWidth, height: terminalHeight)
                        .padding(.leading, 2)
                }
            }
            .padding(compact ? 10 : 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.14), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct QuotaMicroBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(tint)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 5)
            .background(tint.opacity(0.08))
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.12), lineWidth: 1)
            )
            .clipShape(.capsule)
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
            .overlay(
                Capsule()
                    .stroke(foreground.opacity(0.14), lineWidth: 1)
            )
            .clipShape(.capsule)
    }
}

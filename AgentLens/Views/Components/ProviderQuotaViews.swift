import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

func providerQuotaManagementURL(
    for provider: AgentProvider,
    snapshot: ProviderQuotaSnapshot?
) -> URL? {
    if let link = snapshot?.managementLink {
        return link
    }

    let fallback: String? = switch provider {
    case .codex:
        "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan"
    case .claudeCode:
        "https://code.claude.com/docs/en/statusline"
    case .minimax:
        "https://platform.minimax.io/docs/token-plan/faq"
    case .zai:
        "https://bigmodel.cn/usercenter/glm-coding/usage"
    case .factory:
        "https://app.factory.ai"
    case .cursor:
        "https://cursor.com/pricing"
    default:
        nil
    }

    guard let fallback else { return nil }
    return URL(string: fallback)
}

struct ProviderQuotaSettingsSection: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("Quota reporting stays separate from spend history. OpenBurnBar uses official APIs where they exist and otherwise shows the best verifiable local signal it can: Codex rollout snapshots, Claude statusline JSON, and Factory / Droid monthly token estimates. Review provider-level quota here or in each provider dashboard.")
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
            await quotaService.refreshAll(dataStore: dataStore)
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
            await quotaService.refreshAll(dataStore: dataStore)
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

                QuotaDualWindowStrip(
                    hourlyBucket: snapshot?.hourlyBucket,
                    weeklyBucket: snapshot?.weeklyBucket,
                    fallbackBucket: snapshot?.primaryBucket,
                    provider: provider,
                    isActive: isActive
                )
                .frame(width: 180)

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

                        if let url = providerQuotaManagementURL(for: provider, snapshot: snapshot) {
                            Button("Open official quota") {
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

        case .cursor:
            CursorQuotaInlineSetup(quotaService: quotaService, dataStore: dataStore)

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

struct ProviderQuotaBucketRow: View {
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

struct QuotaFigureTile: View {
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

struct QuotaStatusCallout: View {
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

struct ProviderQuotaIdentityOrb: View {
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

struct ProviderQuotaActivityBadge: View {
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

struct QuotaSignalStatus {
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

struct QuotaSignalView: View {
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

struct QuotaSignalPlaceholder: View {
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

// MARK: - Popover Quota Bar

/// Always-visible compact quota summary for the popover.
/// Shows every supported provider's 5h + weekly bars inline — no horizontal scroll.
struct QuotaPopoverBar: View {
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore

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

            // Provider rows — each shows logo + dual-window bars
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

        HStack(spacing: DesignSystem.Spacing.sm) {
            // Provider logo
            ZStack {
                Circle()
                    .fill(theme.primaryColor.opacity(0.18))
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

            // Setup indicator for unconfigured providers
            if snapshot?.buckets.isEmpty == true && !isActive {
                Button {
                    // NOP — tapping the row expands setup in the scroll section below
                } label: {
                    Text("Set up")
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DesignSystem.Colors.blaze))
                }
                .buttonStyle(.plain)
            }

            // Activity indicator
            if isActive {
                ProviderQuotaActivityBadge(provider: provider, compact: true)
            }
        }
    }
}

// MARK: - Dual Window Strip

/// Compact inline component that always shows two quota windows as horizontal bar
/// strips within a single surface. Labels adapt to whatever time windows are available.
struct QuotaDualWindowStrip: View {
    let hourlyBucket: ProviderQuotaBucket?
    let weeklyBucket: ProviderQuotaBucket?
    let fallbackBucket: ProviderQuotaBucket?
    let provider: AgentProvider
    let isActive: Bool

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    /// The "short" slot prefers the hourly bucket; falls back to a daily fallback.
    private var shortSlotBucket: ProviderQuotaBucket? {
        if let hourlyBucket { return hourlyBucket }
        if let fallback = fallbackBucket, fallback.windowKind == .daily { return fallback }
        return nil
    }

    /// The "long" slot prefers the weekly bucket; falls back to the primary bucket.
    private var longSlotBucket: ProviderQuotaBucket? {
        if let weeklyBucket { return weeklyBucket }
        return fallbackBucket
    }

    private func rowConfig(for bucket: ProviderQuotaBucket, defaultLabel: String, defaultIcon: String) -> (label: String, icon: String) {
        switch bucket.windowKind {
        case .rollingHours: return ("5h", "clock.fill")
        case .daily:        return ("24h", "clock")
        case .weekly:       return ("7d", "calendar")
        case .rollingDays:  return ("7d", "calendar")
        case .monthly:      return ("30d", "calendar")
        case .custom:       return (defaultLabel, defaultIcon)
        }
    }

    var body: some View {
        dualLayout
    }

    // MARK: - Dual Layout

    private var dualLayout: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            // Short window row (5h / 24h)
            if let bucket = shortSlotBucket {
                let config = rowConfig(for: bucket, defaultLabel: "5h", defaultIcon: "clock.fill")
                windowBar(bucket: bucket, label: config.label, icon: config.icon)
            } else {
                windowBarPlaceholder(label: "5h", icon: "clock.fill")
            }

            // Long window row (7d / 30d)
            if let bucket = longSlotBucket {
                let config = rowConfig(for: bucket, defaultLabel: "7d", defaultIcon: "calendar")
                windowBar(bucket: bucket, label: config.label, icon: config.icon)
            } else {
                windowBarPlaceholder(label: "7d", icon: "calendar")
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.14), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    // MARK: - Window Bar

    @ViewBuilder
    private func windowBar(bucket: ProviderQuotaBucket, label: String, icon: String) -> some View {
        let fraction = remainingFraction(for: bucket)
        let fill = fillColor(for: fraction)
        let gradient = fillGradient(for: fraction)

        HStack(spacing: DesignSystem.Spacing.sm) {
            // Window label
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(fill)
                    .frame(width: 12)
                Text(label)
                    .font(DesignSystem.Typography.monoTiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .frame(width: 34, alignment: .leading)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(fill.opacity(0.18), lineWidth: 1)
                        )

                    // Fill
                    if fraction > 0.02 {
                        let fillWidth = max(geo.size.width * fraction, 6)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(gradient)
                            .frame(width: fillWidth)
                            .shadow(color: fill.opacity(0.3), radius: 4, y: 0)
                    }
                }
            }
            .frame(height: 10)

            // Remaining text
            Text(bucket.remainingText)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(fill)
                .lineLimit(1)
                .frame(width: 36, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func windowBarPlaceholder(label: String, icon: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 12)
                Text(label)
                    .font(DesignSystem.Typography.monoTiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .frame(width: 34, alignment: .leading)

            // Empty track
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(
                            theme.primaryColor.opacity(isActive ? 0.18 : 0.08),
                            style: StrokeStyle(lineWidth: 1, dash: isActive ? [3, 3] : [])
                        )
                )
                .frame(height: 10)

            Text("—")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Color Helpers

    private func remainingFraction(for bucket: ProviderQuotaBucket) -> Double {
        if let remainingPercent = bucket.remainingPercent {
            return min(max(remainingPercent / 100, 0), 1)
        }
        return min(max(1 - bucket.progressFraction, 0), 1)
    }

    private func fillColor(for fraction: Double) -> Color {
        switch fraction {
        case 0.75...: return theme.primaryColor
        case 0.50..<0.75: return theme.primaryColor.opacity(0.72)
        case 0.25..<0.50: return DesignSystem.Colors.amber
        default: return DesignSystem.Colors.warning
        }
    }

    private func fillGradient(for fraction: Double) -> LinearGradient {
        switch fraction {
        case 0.75...:
            return LinearGradient(
                colors: [theme.primaryColor, theme.accentColor],
                startPoint: .leading, endPoint: .trailing
            )
        case 0.50..<0.75:
            return LinearGradient(
                colors: [theme.primaryColor.opacity(0.72), theme.accentColor.opacity(0.56)],
                startPoint: .leading, endPoint: .trailing
            )
        case 0.25..<0.50:
            return LinearGradient(
                colors: [theme.primaryColor.opacity(0.48), DesignSystem.Colors.amber],
                startPoint: .leading, endPoint: .trailing
            )
        default:
            return LinearGradient(
                colors: [DesignSystem.Colors.amber, DesignSystem.Colors.warning],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }
}

struct QuotaMicroBadge: View {
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

struct QuotaSourceBadge: View {
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

// MARK: - Cursor Inline Setup

private struct CursorQuotaInlineSetup: View {
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore

    private var cursorManager: CursorConnectorManager { .shared }
    private var isConnected: Bool { cursorManager.config.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.md) {
                Circle()
                    .fill(isConnected ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                    .frame(width: 8, height: 8)

                Text(isConnected ? "Connector active" : "Connector offline")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Spacer()
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                if isConnected {
                    GlassButton(title: "Disconnect", icon: "stop.circle", style: .regular) {
                        Task { await cursorManager.disconnect() }
                    }
                } else {
                    GlassButton(title: "Connect", icon: "bolt.horizontal.circle", style: .prominent) {
                        Task {
                            await cursorManager.connect()
                            await quotaService.refresh(provider: .cursor, dataStore: dataStore)
                        }
                    }
                }

                GlassButton(title: "Refresh", icon: "arrow.clockwise", style: .regular) {
                    Task { await quotaService.refresh(provider: .cursor, dataStore: dataStore) }
                }
            }
            .disabled(cursorManager.isBusy)

            if let error = cursorManager.lastError {
                Text(error)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }

            Text("Cursor Connector routes requests through OpenBurnBar's local proxy to Z.ai and MiniMax. Configure providers and models in Dashboard → Settings.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
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

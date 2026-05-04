import SwiftUI
import Charts
import OpenBurnBarCore

struct SessionDetailView: View {
    let usage: TokenUsage

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(usage.provider.rawValue)
    }

    private var themeColor: Color {
        providerEnum.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.Colors.textSecondary
    }

    private var chartPalette: [Color] {
        providerEnum.map { MobileTheme.Colors.chartPalette(for: $0) } ?? [MobileTheme.Colors.textSecondary]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.xl) {
                heroHeader
                tokenBreakdown
                provenanceSection
                if usage.sourceDeviceName != nil || usage.sourceDeviceId != nil {
                    deviceSection
                }
            }
            .padding(.vertical, MobileTheme.Spacing.lg)
        }
        .background(emberBackground.ignoresSafeArea())
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emberBackground: some View {
        EmberSurfaceBackground()
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack(alignment: .top) {
            UnifiedGlassCard {
                VStack(spacing: MobileTheme.Spacing.md) {
                    if let providerEnum {
                        ProviderAvatar(provider: providerEnum, mode: .aurora, size: 64)
                    }

                    Text(usage.model)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)

                    Text(providerEnum?.displayName ?? usage.provider.rawValue)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)

                    // Metric row
                    HStack(spacing: MobileTheme.Spacing.md) {
                        MetricPill(title: "Cost", value: usage.cost.formatAsCost())
                        MetricPill(title: "Tokens", value: usage.totalTokens.formatAsTokens())
                        MetricPill(title: "Duration", value: usage.formattedDuration)
                        if usage.cacheReadTokens > 0 || usage.cacheCreationTokens > 0 {
                            MetricPill(
                                title: "Cache",
                                value: String(format: "%.0f%%", cacheHitRatio * 100)
                            )
                        }
                    }
                    .padding(.top, MobileTheme.Spacing.sm)
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var cacheHitRatio: Double {
        let cacheTotal = Double(usage.cacheReadTokens + usage.cacheCreationTokens)
        let total = Double(usage.totalTokens)
        guard total > 0 else { return 0 }
        return min(1, cacheTotal / total)
    }

    // MARK: - Token Breakdown

    private var tokenBreakdown: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("Tokens")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                // Animated horizontal token-mix bar
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        tokenMixSegment(value: usage.inputTokens, total: usage.totalTokens, color: chartPalette[0], width: geo.size.width)
                        tokenMixSegment(value: usage.outputTokens, total: usage.totalTokens, color: chartPalette[1], width: geo.size.width)
                        if usage.cacheReadTokens > 0 {
                            tokenMixSegment(value: usage.cacheReadTokens, total: usage.totalTokens, color: chartPalette[2], width: geo.size.width)
                        }
                        if usage.reasoningTokens > 0 {
                            tokenMixSegment(value: usage.reasoningTokens, total: usage.totalTokens, color: chartPalette[3], width: geo.size.width)
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                }
                .frame(height: 8)

                LazyVStack(spacing: MobileTheme.Spacing.sm) {
                    TokenPill(label: "Input", value: usage.inputTokens, color: chartPalette[0])
                    TokenPill(label: "Output", value: usage.outputTokens, color: chartPalette[1])
                    if usage.cacheCreationTokens > 0 {
                        TokenPill(label: "Cache Creation", value: usage.cacheCreationTokens, color: chartPalette[2])
                    }
                    if usage.cacheReadTokens > 0 {
                        TokenPill(label: "Cache Read", value: usage.cacheReadTokens, color: chartPalette[2])
                    }
                    if usage.reasoningTokens > 0 {
                        TokenPill(label: "Reasoning", value: usage.reasoningTokens, color: chartPalette[3])
                    }
                    Divider()
                    TokenPill(label: "Total", value: usage.totalTokens, isTotal: true)
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private func tokenMixSegment(value: Int, total: Int, color: Color, width: CGFloat) -> some View {
        let fraction = total > 0 ? CGFloat(value) / CGFloat(total) : 0
        return RoundedRectangle(cornerRadius: 0, style: .continuous)
            .fill(color)
            .frame(width: width * fraction)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: fraction)
    }

    // MARK: - Provenance

    private var provenanceSection: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("Provenance")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                ProvenanceChip(label: "Method", value: usage.provenanceMethod.rawValue)
                ProvenanceChip(label: "Confidence", value: usage.provenanceConfidence.rawValue)
                ProvenanceChip(label: "Source", value: usage.usageSource.rawValue)
                if !usage.estimatorVersion.isEmpty {
                    ProvenanceChip(label: "Estimator", value: usage.estimatorVersion)
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    // MARK: - Device

    private var deviceSection: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("Device")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                if let name = usage.sourceDeviceName {
                    ProvenanceChip(label: "Name", value: name)
                }
                if let id = usage.sourceDeviceId {
                    ProvenanceChip(label: "ID", value: id)
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }
}

// MARK: - Token Pill

private struct TokenPill: View {
    let label: String
    let value: Int
    var isTotal = false
    var color: Color? = nil

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Text(label)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            Spacer()
            Text(value.formatAsTokens())
                .font(isTotal ? MobileTheme.Typography.headline : MobileTheme.Typography.body)
                .foregroundStyle(isTotal ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
        }
    }
}

// MARK: - Metric Pill

private struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(title)
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.6))
        )
    }
}

// MARK: - Provenance Chip

private struct ProvenanceChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(MobileTheme.Colors.surfaceElevated)
                )
        }
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(usage: TokenUsage(
            provider: .claudeCode,
            sessionId: "sess-123",
            projectName: "Demo",
            model: "claude-3-5-sonnet-20241022",
            inputTokens: 120_000,
            outputTokens: 45_000,
            cacheCreationTokens: 5_000,
            cacheReadTokens: 8_000,
            reasoningTokens: 2_000,
            costUSD: 1.23,
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date(),
            usageSource: .providerLog,
            sourceDeviceId: "device-abc",
            sourceDeviceName: "MacBook Pro",
            isRemote: false,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        ))
    }
}

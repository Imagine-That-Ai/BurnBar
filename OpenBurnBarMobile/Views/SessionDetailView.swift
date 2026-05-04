import SwiftUI
import OpenBurnBarCore

struct SessionDetailView: View {
    let usage: TokenUsage

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(usage.provider.rawValue)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.xl) {
                headerSection
                tokenSection
                provenanceSection
                if usage.sourceDeviceName != nil || usage.sourceDeviceId != nil {
                    deviceSection
                }
            }
            .padding(.vertical, MobileTheme.Spacing.lg)
        }
        .background(MobileTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            if let providerEnum {
                ProviderBadge(provider: providerEnum, size: 56)
            }
            Text(usage.model)
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(providerEnum?.displayName ?? usage.provider.rawValue)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            HStack(spacing: MobileTheme.Spacing.md) {
                MetricPill(title: "Cost", value: usage.cost.formatAsCost())
                MetricPill(title: "Duration", value: usage.formattedDuration)
            }
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Tokens")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            LazyVStack(spacing: MobileTheme.Spacing.sm) {
                TokenPill(label: "Input", value: usage.inputTokens)
                TokenPill(label: "Output", value: usage.outputTokens)
                if usage.cacheCreationTokens > 0 {
                    TokenPill(label: "Cache Creation", value: usage.cacheCreationTokens)
                }
                if usage.cacheReadTokens > 0 {
                    TokenPill(label: "Cache Read", value: usage.cacheReadTokens)
                }
                if usage.reasoningTokens > 0 {
                    TokenPill(label: "Reasoning", value: usage.reasoningTokens)
                }
                Divider()
                TokenPill(label: "Total", value: usage.totalTokens, isTotal: true)
            }
        }
        .padding(MobileTheme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Provenance")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            ProvenanceRow(label: "Method", value: usage.provenanceMethod.rawValue)
            ProvenanceRow(label: "Confidence", value: usage.provenanceConfidence.rawValue)
            ProvenanceRow(label: "Source", value: usage.usageSource.rawValue)
            if !usage.estimatorVersion.isEmpty {
                ProvenanceRow(label: "Estimator", value: usage.estimatorVersion)
            }
        }
        .padding(MobileTheme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Device")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            if let name = usage.sourceDeviceName {
                ProvenanceRow(label: "Name", value: name)
            }
            if let id = usage.sourceDeviceId {
                ProvenanceRow(label: "ID", value: id)
            }
        }
        .padding(MobileTheme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }
}

// MARK: - Token Pill

private struct TokenPill: View {
    let label: String
    let value: Int
    var isTotal = false

    var body: some View {
        HStack {
            Text(label)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
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
                .fill(MobileTheme.Colors.surfaceElevated)
        )
    }
}

// MARK: - Provenance Row

private struct ProvenanceRow: View {
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

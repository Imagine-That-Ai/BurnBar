import SwiftUI
import OpenBurnBarCore

struct QuotaDetailSheet: View {
    let provider: String
    let snapshots: [ProviderQuotaSnapshot]
    @Environment(\.dismiss) private var dismiss

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(provider)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    headerSection
                    ForEach(snapshots) { snapshot in
                        snapshotCard(snapshot)
                    }
                }
                .padding(.vertical, MobileTheme.Spacing.lg)
            }
            .background(MobileTheme.Colors.background.ignoresSafeArea())
            .navigationTitle(providerEnum?.displayName ?? provider)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var headerSection: some View {
        HStack {
            if let providerEnum {
                ProviderBadge(provider: providerEnum, size: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(providerEnum?.displayName ?? provider)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("\(snapshots.count) source(s)")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private func snapshotCard(_ snapshot: ProviderQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack {
                Text(snapshot.source)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text(snapshot.confidence.rawValue)
                    .font(MobileTheme.Typography.footnote)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(confidenceColor(snapshot.confidence).opacity(0.15))
                    .foregroundStyle(confidenceColor(snapshot.confidence))
                    .clipShape(Capsule())
            }
            if let status = snapshot.statusMessage {
                Text(status)
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(snapshot.buckets, id: \.self) { bucket in
                    QuotaBucketView(bucket: bucket)
                }
            }
            Text("Fetched \(snapshot.fetchedAt, style: .relative) ago")
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private func confidenceColor(_ confidence: ProviderQuotaConfidence) -> Color {
        switch confidence {
        case .high: return MobileTheme.Colors.success
        case .medium: return MobileTheme.Colors.warning
        case .low, .stale: return MobileTheme.Colors.error
        }
    }
}

#Preview {
    QuotaDetailSheet(
        provider: "minimax",
        snapshots: [
            ProviderQuotaSnapshot(
                id: "minimax_default",
                provider: "minimax",
                sourceKind: .provider,
                sourceId: "default",
                fetchedAt: Date(),
                source: "desktopAPI",
                confidence: .high,
                buckets: [
                    ProviderQuotaBucket(name: "Tokens", used: 800_000, limit: 1_000_000, remaining: 200_000, window: "daily"),
                    ProviderQuotaBucket(name: "Requests", used: 4_200, limit: 5_000, remaining: 800, window: "daily")
                ],
                schemaVersion: 1,
                updatedAt: Date()
            )
        ]
    )
}

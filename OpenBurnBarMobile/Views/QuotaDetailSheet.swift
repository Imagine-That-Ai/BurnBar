import SwiftUI
import OpenBurnBarCore

struct QuotaDetailSheet: View {
    let provider: String
    let snapshots: [ProviderQuotaSnapshot]
    var routingState: ProviderRoutingStateSnapshot?
    @Environment(\.dismiss) private var dismiss

    var providerEnum: AgentProvider? {
        AgentProvider.fromProviderID(ProviderID(rawValue: provider))
    }

    private var sortedSnapshots: [ProviderQuotaSnapshot] {
        // Pressured accounts surface first; ties break by label so the order is
        // stable as quota shifts.
        snapshots.sorted { lhs, rhs in
            let lhsP = pressure(for: lhs)
            let rhsP = pressure(for: rhs)
            if lhsP != rhsP { return lhsP < rhsP }
            let lhsLabel = lhs.accountLabel ?? lhs.accountID ?? lhs.sourceID
            let rhsLabel = rhs.accountLabel ?? rhs.accountID ?? rhs.sourceID
            return lhsLabel.localizedCaseInsensitiveCompare(rhsLabel) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    headerSection
                    if let providerEnum,
                       let routingState,
                       routingState.hasMeaningfulRoutingDetail {
                        ProviderRoutingCockpit(provider: providerEnum, state: routingState)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                    }
                    if sortedSnapshots.isEmpty {
                        EmptyStateView(
                            icon: "gauge.with.dots.needle.bottom.50percent",
                            title: "No Quota Snapshots",
                            message: "There's no quota data for this provider yet. Pull to refresh, or open OpenBurnBar on Mac."
                        )
                        .padding(.top, MobileTheme.Spacing.xl)
                    } else {
                        ForEach(sortedSnapshots, id: \.id) { snapshot in
                            snapshotCard(snapshot)
                        }
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
        HStack(alignment: .center, spacing: MobileTheme.Spacing.md) {
            if let providerEnum {
                ProviderBadge(provider: providerEnum, size: 48)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(providerEnum?.displayName ?? provider)
                    .font(MobileTheme.Typography.title)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(accountSummary)
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .accessibilityLabel("\(snapshots.count) quota snapshots — \(accountSummary)")
            }
            Spacer()
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private func snapshotCard(_ snapshot: ProviderQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.accountLabel ?? snapshot.accountID ?? "Unattributed")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if let scope = snapshot.accountStorageScope {
                            ProviderAccountStorageChip(scope: scope, compact: true)
                        }
                        Text("Source: \(snapshot.source)")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
                Spacer()
                ConfidenceChip(confidence: snapshot.confidence)
            }

            if let status = snapshot.statusMessage, !status.isEmpty {
                Text(status)
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if snapshot.buckets.isEmpty {
                QuotaBucketEmptyRow()
            } else {
                LazyVStack(spacing: MobileTheme.Spacing.md) {
                    ForEach(snapshot.buckets, id: \.self) { bucket in
                        QuotaBucketView(bucket: bucket)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Text("Fetched \(snapshot.fetchedAt, style: .relative) ago")
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
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

    private var accountSummary: String {
        let ids = Set(snapshots.compactMap(\.accountID))
        let count = max(ids.count, snapshots.isEmpty ? 0 : 1)
        let accountText = count == 1 ? "1 account" : "\(count) accounts"
        let scopes = Set(snapshots.compactMap(\.accountStorageScope))
        if scopes.count == 1, let only = scopes.first {
            return "\(accountText) · \(ProviderAccountStorageVisual.label(only))"
        }
        if scopes.count > 1 {
            return "\(accountText) · mixed storage"
        }
        return accountText
    }

    private func pressure(for snapshot: ProviderQuotaSnapshot) -> Double {
        let bucketPressures = snapshot.buckets.compactMap { bucket -> Double? in
            guard bucket.limit > 0 else { return nil }
            return max(0, bucket.remaining) / bucket.limit
        }
        return bucketPressures.min() ?? .infinity
    }
}

// MARK: - Confidence chip

private struct ConfidenceChip: View {
    let confidence: ProviderQuotaConfidence

    private var label: String {
        switch confidence {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low confidence"
        case .stale: return "Stale"
        }
    }

    private var icon: String {
        switch confidence {
        case .high: return "checkmark.seal.fill"
        case .medium: return "checkmark.seal"
        case .low: return "questionmark.circle"
        case .stale: return "clock.badge.exclamationmark"
        }
    }

    private var tint: Color {
        switch confidence {
        case .high: return MobileTheme.Colors.success
        case .medium: return MobileTheme.Colors.warning
        case .low, .stale: return MobileTheme.Colors.error
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.medium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

private struct QuotaBucketEmptyRow: View {
    var body: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "tray")
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text("No bucket detail in this snapshot.")
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer()
        }
        .padding(.vertical, 6)
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
        ],
        routingState: nil
    )
}

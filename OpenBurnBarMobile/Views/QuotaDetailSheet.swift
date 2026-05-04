import SwiftUI
import OpenBurnBarCore

struct QuotaDetailSheet: View {
    let provider: String
    let snapshots: [ProviderQuotaSnapshot]
    let routingState: ProviderRoutingStateSnapshot?

    var providerEnum: AgentProvider? {
        AgentProvider.fromProviderID(ProviderID(rawValue: provider))
    }

    private var themeColor: Color {
        providerEnum.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.Colors.textSecondary
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.xl) {
                heroSection
                accountCarousel
                statsRow
                bucketsSection
                if let providerEnum,
                   let routingState,
                   routingState.hasMeaningfulRoutingDetail {
                    ProviderRoutingCockpit(provider: providerEnum, state: routingState, compact: false)
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                }
            }
            .padding(.vertical, MobileTheme.Spacing.lg)
        }
        .background(emberBackground.ignoresSafeArea())
        .navigationTitle(providerEnum?.displayName ?? provider)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emberBackground: some View {
        EmberSurfaceBackground()
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .top) {
            // Brand-tinted backdrop
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            themeColor.opacity(0.12),
                            themeColor.opacity(0.04),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: MobileTheme.Spacing.md) {
                if let providerEnum {
                    ProviderAvatar(provider: providerEnum, mode: .aurora, size: 72)
                }

                Text(providerEnum?.displayName ?? provider)
                    .font(MobileTheme.Typography.title)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text("\(snapshots.count) account\(snapshots.count == 1 ? "" : "s")")
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            .padding(MobileTheme.Spacing.xl)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    // MARK: - Account Carousel

    private var accountCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileTheme.Spacing.md) {
                ForEach(snapshots, id: \.id) { snapshot in
                    accountCard(snapshot)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    private func accountCard(_ snapshot: ProviderQuotaSnapshot) -> some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                Text(snapshot.accountLabel ?? snapshot.accountID ?? "Account")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                if let scope = snapshot.accountStorageScope {
                    ProviderAccountStorageChip(scope: scope, compact: true)
                }

                ForEach(snapshot.buckets, id: \.name) { bucket in
                    if let providerEnum {
                        UnifiedQuotaSignalView(bucket: bucket, provider: providerEnum, compact: true)
                    }
                }
            }
            .frame(width: 280)
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            StatChip(label: "Confidence", value: snapshots.first?.confidence.rawValue ?? "—")
            StatChip(label: "Source", value: snapshots.first?.source ?? "—")
            StatChip(label: "Freshness", value: freshnessText)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var freshnessText: String {
        guard let timestamp = snapshots.first?.fetchedAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    // MARK: - Buckets

    private var bucketsSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Quota Breakdown")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)

            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(allBuckets, id: \.name) { bucket in
                    if let providerEnum {
                        UnifiedQuotaSignalView(bucket: bucket, provider: providerEnum, compact: false)
                            .padding(.horizontal, MobileTheme.Spacing.lg)
                    }
                }
            }
        }
    }

    private var allBuckets: [ProviderQuotaBucket] {
        snapshots.flatMap(\.buckets)
    }
}

// MARK: - Stat Chip

private struct StatChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(label)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
        )
    }
}

#Preview {
    NavigationStack {
        QuotaDetailSheet(
            provider: "openai",
            snapshots: [],
            routingState: nil
        )
    }
}

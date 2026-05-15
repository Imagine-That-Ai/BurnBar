import SwiftUI
import OpenBurnBarCore

struct QuotaDetailSheet: View {
    let provider: String
    let snapshots: [ProviderQuotaSnapshot]
    let routingState: ProviderRoutingStateSnapshot?

    @State private var isRefreshing = false
    var onRefresh: (() async -> Void)?

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
                if snapshots.count > 1 {
                    accountCarousel
                }
                statsRow
                accountSections
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        isRefreshing = true
                        defer { isRefreshing = false }
                        await onRefresh?()
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh quota")
            }
        }
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
        let relative = formatter.localizedString(for: timestamp, relativeTo: Date())
        if snapshots.first?.isStale() == true {
            return "stale \(relative)"
        }
        return relative
    }

    // MARK: - Account-grouped buckets

    /// Each account renders its own grouped section. Every gauge is preceded
    /// by a small caption explaining what the bucket measures so the user
    /// never sees a wall of identical-looking battery bars.
    private var accountSections: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            ForEach(snapshots, id: \.id) { snapshot in
                accountQuotaCard(snapshot)
                    .padding(.horizontal, MobileTheme.Spacing.lg)
            }
        }
    }

    @ViewBuilder
    private func accountQuotaCard(_ snapshot: ProviderQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            // Account header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.accountLabel ?? snapshot.accountID ?? "Account")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("Quota Breakdown")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .tracking(1.2)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
                if let scope = snapshot.accountStorageScope {
                    ProviderAccountStorageChip(scope: scope, compact: true)
                }
            }

            // Helper note: explains the gauges
            if snapshot.isStale() {
                Text("Quota data is stale. Refresh this account before trusting the numbers.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !snapshot.buckets.isEmpty {
                Text(quotaExplanation(for: snapshot.buckets))
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Gauges — one per bucket, with name + window labels (now shown
            // by the updated `UnifiedQuotaSignalView`).
            VStack(spacing: MobileTheme.Spacing.sm) {
                ForEach(snapshot.buckets, id: \.name) { bucket in
                    if let providerEnum {
                        UnifiedQuotaSignalView(bucket: bucket, provider: providerEnum, compact: false)
                    }
                }
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(themeColor.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func quotaExplanation(for buckets: [ProviderQuotaBucket]) -> String {
        let windows = buckets.compactMap { $0.window?.lowercased() }
        let names = buckets.map { $0.name.lowercased() }
        if windows.contains(where: { $0.contains("hour") }) && windows.contains(where: { $0.contains("week") || $0.contains("day") }) {
            return "Each gauge tracks usage over a different rolling window. The shorter window paces your near-term burn; the longer window protects against weekly caps."
        }
        if names.contains(where: { $0.contains("token") }) && names.contains(where: { $0.contains("request") }) {
            return "One gauge tracks tokens consumed; the other tracks request count. Hitting either limit pauses the account."
        }
        if buckets.count > 1 {
            return "Each gauge is a separate quota the provider exposes. The smallest reserve is the one that will throttle first."
        }
        return "Headroom remaining in this account's active quota window."
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

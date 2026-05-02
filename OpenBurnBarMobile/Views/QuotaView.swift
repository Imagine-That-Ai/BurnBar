import SwiftUI
import OpenBurnBarCore

struct QuotaView: View {
    @State private var store = QuotaStore()
    @State private var selectedProvider: String?

    var body: some View {
        ScrollView {
            if store.isLoading && store.snapshotsByProvider.isEmpty {
                loadingPlaceholder
            } else if store.snapshotsByProvider.isEmpty {
                EmptyStateView(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "No Quota Data",
                    message: "Connect a provider to see quota snapshots."
                )
            } else {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    if !store.urgentProviders.isEmpty {
                        urgentSection
                    }
                    healthySection
                }
                .padding(.vertical, MobileTheme.Spacing.lg)
            }
        }
        .background(MobileTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Quota")
        .refreshable { await store.refresh() }
        .task { store.startListening() }
        .onDisappear { store.stopListening() }
        .sheet(isPresented: .init(
            get: { selectedProvider != nil },
            set: { if !$0 { selectedProvider = nil } }
        )) {
            if let provider = selectedProvider {
                QuotaDetailSheet(provider: provider, snapshots: store.snapshotsByProvider[provider] ?? [])
            }
        }
    }

    // MARK: - Urgent Section

    private var urgentSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Label("Urgent", systemImage: "exclamationmark.triangle.fill")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.error)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(store.urgentProviders, id: \.self) { provider in
                    QuotaProviderCard(
                        provider: provider,
                        snapshots: store.snapshotsByProvider[provider] ?? [],
                        onTap: { selectedProvider = provider }
                    )
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    // MARK: - Healthy Section

    private var healthySection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Healthy")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(store.healthyProviders, id: \.self) { provider in
                    QuotaProviderCard(
                        provider: provider,
                        snapshots: store.snapshotsByProvider[provider] ?? [],
                        onTap: { selectedProvider = provider }
                    )
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    // MARK: - Loading Placeholder

    private var loadingPlaceholder: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            SkeletonView(height: 120, cornerRadius: MobileTheme.Radius.lg)
            SkeletonView(height: 120, cornerRadius: MobileTheme.Radius.lg)
            SkeletonView(height: 120, cornerRadius: MobileTheme.Radius.lg)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.top, MobileTheme.Spacing.xl)
    }
}

// MARK: - Quota Provider Card

private struct QuotaProviderCard: View {
    let provider: String
    let snapshots: [ProviderQuotaSnapshot]
    let onTap: () -> Void

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(provider)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack {
                    if let providerEnum {
                        ProviderBadge(provider: providerEnum, size: 36)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(providerEnum?.displayName ?? provider)
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(sourceProvenance)
                            .font(MobileTheme.Typography.footnote)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                if let first = snapshots.first, let bucket = first.buckets.first {
                    QuotaBucketView(bucket: bucket)
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
        }
        .buttonStyle(.plain)
    }

    private var sourceProvenance: String {
        guard let first = snapshots.first else { return "No data" }
        return "Source: \(first.source) · \(first.confidence.rawValue)"
    }
}

#Preview {
    NavigationStack {
        QuotaView()
    }
}

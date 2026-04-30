import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

struct ProviderDashboardQuotaPanel: View {
    let provider: AgentProvider
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStoreCoordinator

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

                        if let url = providerQuotaManagementURL(for: provider, snapshot: snapshot) {
                            Button("Open official quota") {
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

import SwiftUI
import OpenBurnBarCore

// MARK: - Quota Pulse Card
//
// Compact preview of the QuotaRingsConstellation; tap to navigate to Burn.

struct QuotaPulseCard: View {
    let snapshots: [ProviderQuotaSnapshot]
    let onSelect: (String) -> Void
    let onOpenBurn: () -> Void

    var body: some View {
        AuroraGlassCard(
            variant: hasUrgent ? .urgent : .standard,
            cornerRadius: AuroraDesign.Shape.heroCorner
        ) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                AuroraSection(
                    "Quota",
                    subtitle: hasUrgent
                        ? "One or more providers are under pressure"
                        : "All providers healthy",
                    accent: hasUrgent ? MobileTheme.warning : MobileTheme.success
                ) {
                    Button(action: onOpenBurn) {
                        Label("Open", systemImage: "arrow.up.right.square")
                            .labelStyle(.titleAndIcon)
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.ember)
                    }
                    .buttonStyle(.plain)
                }

                if items.isEmpty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "gauge.with.dots.needle.bottom.50percent",
                        title: "No quota signal yet",
                        message: "Connect a provider on your Mac to start tracking quota."
                    )
                    .frame(height: 220)
                } else {
                    QuotaRingsConstellation(items: items) { item in
                        onSelect(item.providerKey)
                    }
                    .frame(height: 220)
                }
            }
        }
    }

    // MARK: - Derived

    private var hasUrgent: Bool {
        snapshots.flatMap(\.buckets).contains { bucket in
            guard bucket.limit > 0 else { return false }
            return max(0, bucket.remaining) / bucket.limit < 0.25
        }
    }

    private var items: [QuotaRingsConstellation.Item] {
        let grouped = Dictionary(grouping: snapshots, by: { $0.providerID.rawValue })
        return grouped.compactMap { key, snaps -> QuotaRingsConstellation.Item? in
            guard let provider = AgentProvider.fromProviderID(ProviderID(rawValue: key))
                ?? AgentProvider.fromPersistedToken(key) else { return nil }
            let pressure = snaps
                .flatMap(\.buckets)
                .filter { $0.limit > 0 }
                .map { max(0, $0.remaining) / $0.limit }
                .min() ?? 1.0
            return QuotaRingsConstellation.Item(
                provider: provider,
                providerKey: key,
                pressureRemaining: pressure,
                label: provider.displayName
            )
        }
        .sorted { $0.pressureRemaining < $1.pressureRemaining }
    }
}

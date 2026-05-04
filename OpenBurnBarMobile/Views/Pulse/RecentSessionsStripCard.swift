import SwiftUI
import OpenBurnBarCore

// MARK: - Recent Sessions Strip Card
//
// Horizontal carousel of the 5 most recent sessions. Each card uses a
// provider-tinted aurora gradient and tappable navigation into the
// SessionDetailView.

struct RecentSessionsStripCard: View {
    let sessions: [TokenUsage]
    let onSelect: (TokenUsage) -> Void
    let onSeeAll: () -> Void

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                AuroraSection(
                    "Recent",
                    subtitle: sessions.isEmpty ? "Awaiting first session" : "Last \(sessions.count) sessions",
                    accent: MobileTheme.whimsy
                ) {
                    Button(action: onSeeAll) {
                        Label("See all", systemImage: "arrow.up.right.square")
                            .labelStyle(.titleAndIcon)
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.whimsy)
                    }
                    .buttonStyle(.plain)
                }

                if sessions.isEmpty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "doc.text.magnifyingglass",
                        title: "No sessions yet",
                        message: "Sessions will appear here as soon as your Mac syncs."
                    )
                    .frame(height: 160)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(sessions.prefix(8)) { session in
                                Button {
                                    HapticBus.sheetOpen()
                                    onSelect(session)
                                } label: {
                                    SessionTileMicro(usage: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Session Tile (Micro)

private struct SessionTileMicro: View {
    let usage: TokenUsage

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(usage.provider.rawValue)
    }

    private var primary: Color {
        providerEnum.map { MobileTheme.Colors.primary(for: $0) } ?? MobileTheme.ember
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let providerEnum {
                    ProviderAuroraAvatar(provider: providerEnum, size: 32, animated: false)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(providerEnum?.displayName ?? usage.provider.rawValue)
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(primary)
                    Text(usage.startTime, style: .relative)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(1)
                }
            }
            Text(usage.model)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(1)
            if !usage.projectName.isEmpty {
                Text(usage.projectName)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(usage.cost.formatAsCost())
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .contentTransition(.numericText())
                Text("·")
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Text(usage.totalTokens.formatAsTokens())
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 160, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [primary.opacity(0.18), primary.opacity(0.06), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(primary.opacity(0.4), lineWidth: 0.5)
                )
        )
    }
}

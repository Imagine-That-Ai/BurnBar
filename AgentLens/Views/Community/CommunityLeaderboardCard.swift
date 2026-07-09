import SwiftUI
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

struct CommunityLeaderboardCard: View {
    let tier: FirestoreGeographyTier
    let geoLabel: String
    let board: FirestoreCommunityLeaderboardDoc?
    let pinnedAnonId: String?
    let isLoading: Bool

    private var displayBoard: FirestoreCommunityLeaderboardDoc? {
        guard let board, !board.belowThreshold else { return nil }
        return board
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                header

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, DesignSystem.Spacing.lg)
                } else if let board, board.belowThreshold {
                    CommunityThresholdView(
                        tierLabel: geoLabel,
                        kThreshold: board.kThreshold,
                        neededCount: max(board.kThreshold - board.cohortSize, 1)
                    )
                } else if let board = displayBoard {
                    leaderboardBody(board)
                } else {
                    Text("Leaderboard unavailable for \(geoLabel).")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tierTitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                Text(geoLabel)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            Spacer()
            if let board = displayBoard {
                Text("\(board.cohortSize) burners")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func leaderboardBody(_ board: FirestoreCommunityLeaderboardDoc) -> some View {
        let top = Array(board.entries.prefix(5))
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ForEach(top) { entry in
                row(entry, pinned: entry.anonId == pinnedAnonId)
            }
            if let pinned = pinnedEntry(in: board), !top.contains(where: { $0.anonId == pinned.anonId }) {
                Divider().opacity(0.35)
                row(pinned, pinned: true, showPin: true)
            }
        }
    }

    private func pinnedEntry(in board: FirestoreCommunityLeaderboardDoc) -> FirestoreLeaderboardEntry? {
        guard let pinnedAnonId else { return nil }
        return board.entries.first { $0.anonId == pinnedAnonId }
    }

    private func row(_ entry: FirestoreLeaderboardEntry, pinned: Bool, showPin: Bool = false) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("#\(entry.rank)")
                .font(DesignSystem.Typography.caption.monospacedDigit())
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 28, alignment: .leading)

            movementIcon(entry.movement)

            Text(entry.handle ?? "anon-\(entry.anonId.prefix(6))")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(pinned ? DesignSystem.Colors.ember : DesignSystem.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            Text(formatTokens(entry.totalTokens))
                .font(DesignSystem.Typography.caption.monospacedDigit())
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if showPin || pinned {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .accessibilityLabel("Your rank")
            }
        }
    }

    @ViewBuilder
    private func movementIcon(_ movement: String) -> some View {
        switch movement {
        case "up":
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.success)
        case "down":
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.error)
        case "new":
            Text("NEW")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.whimsy)
        default:
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private var tierTitle: String {
        switch tier {
        case .city: return "City"
        case .region: return "Region"
        case .country: return "Country"
        case .world: return "World"
        }
    }

    private func formatTokens(_ value: Int64) -> String {
        let n = Int(value)
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
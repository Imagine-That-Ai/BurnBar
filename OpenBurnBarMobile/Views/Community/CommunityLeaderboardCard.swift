import SwiftUI
import OpenBurnBarCore

struct CommunityLeaderboardCard: View {
    let tier: FirestoreGeographyTier
    let board: FirestoreCommunityLeaderboardDoc
    let pinnedAnonId: String?

    private var tierLabel: String {
        switch tier {
        case .city: "City"
        case .region: "Region"
        case .country: "Country"
        case .world: "World"
        }
    }

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    CommunityEditorialTypography.eyebrowText("Leaderboard · \(tierLabel)")
                    Spacer()
                    Text("\(board.cohortSize) burners")
                        .font(CommunityEditorialTypography.metaStrip)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                if board.belowThreshold {
                    belowThresholdFallback
                } else {
                    leaderboardBody
                }
            }
        }
    }

    private var belowThresholdFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text("Needs \(board.kThreshold) more burners in \(tierLabel.lowercased())")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("We never show individual ranks until the cohort is large enough. Try a broader geography above.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("community.leaderboard.belowThreshold.\(tier.rawValue)")
    }

    private var leaderboardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(board.entries.prefix(5)) { entry in
                leaderboardRow(entry, pinned: entry.anonId == pinnedAnonId)
            }
            if let pinned = pinnedRow {
                Divider().opacity(0.35)
                leaderboardRow(pinned.entry, pinned: true, forceShow: true)
            }
        }
    }

    private var pinnedRow: (entry: FirestoreLeaderboardEntry, rank: Int)? {
        guard let pinnedAnonId else { return nil }
        guard let entry = board.entries.first(where: { $0.anonId == pinnedAnonId }) else { return nil }
        if board.entries.prefix(5).contains(where: { $0.anonId == pinnedAnonId }) { return nil }
        return (entry, entry.rank)
    }

    private func leaderboardRow(
        _ entry: FirestoreLeaderboardEntry,
        pinned: Bool,
        forceShow: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Text("#\(entry.rank)")
                .font(CommunityEditorialTypography.instrument)
                .foregroundStyle(pinned ? MobileTheme.ember : MobileTheme.Colors.textMuted)
                .frame(width: 36, alignment: .leading)

            movementIcon(entry.movement)

            Text(entry.handle ?? "anon-\(entry.anonId.prefix(6))")
                .font(MobileTheme.Typography.body)
                .fontWeight(pinned ? .semibold : .regular)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(formatTokens(entry.totalTokens))
                .font(CommunityEditorialTypography.metaStrip)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
        .padding(.vertical, 2)
        .background(
            pinned || forceShow
                ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MobileTheme.ember.opacity(0.08))
                : nil
        )
    }

    @ViewBuilder
    private func movementIcon(_ raw: String) -> some View {
        let movement = FirestoreRankMovement(rawValue: raw) ?? .same
        switch movement {
        case .up:
            Image(systemName: "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(MobileTheme.success)
        case .down:
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(MobileTheme.error)
        case .new:
            Text("NEW")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(MobileTheme.ember)
        case .same:
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.5))
        }
    }

    private func formatTokens(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
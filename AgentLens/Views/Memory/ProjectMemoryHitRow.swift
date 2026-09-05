import OpenBurnBarKernel
import SwiftUI

/// B9: one project-memory recall hit, with the single line that says why it was
/// served (`BurnBarProjectMemoryHit.whyExplanation`, built from the daemon's
/// ranking report — never from a second scoring pass here).
///
/// Not yet mounted: the app has no project-memory recall surface today, so this
/// row is the presentation half waiting on one. It takes a hit and renders it;
/// there is nothing else to wire.
struct ProjectMemoryHitRow: View {
    let hit: BurnBarProjectMemoryHit

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(hit.kind.capitalized)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(DesignSystem.Colors.ember.opacity(0.12))
                    .clipShape(Capsule())

                Text(hit.memoryID)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if let rank = hit.rank {
                    // `rank` is the daemon's 0-based position; humans count from 1.
                    Text("#\(Int(rank) + 1)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Text(hit.snippet)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(3)

            if let explanation = hit.whyExplanation {
                Text(explanation)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 1)
        )
    }
}

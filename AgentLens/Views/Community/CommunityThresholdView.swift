import SwiftUI
import OpenBurnBarCore

struct CommunityThresholdView: View {
    let tierLabel: String
    let kThreshold: Int
    let neededCount: Int

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Label("Not enough burners yet", systemImage: "person.3.sequence")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Needs \(max(neededCount, 1)) more burners in \(tierLabel) before rankings appear.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("We never show individual ranks below \(kThreshold) participants (k-anonymity).")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
    }
}
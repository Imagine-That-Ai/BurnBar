import SwiftUI
import OpenBurnBarCore

/// Pulse feed entry — opens Community via `NavigationLink(value: CommunityRoute.self)`.
struct CommunityEntryCard: View {
    let participates: Bool
    let headlineTokens: String?

    var body: some View {
        NavigationLink(value: CommunityRoute.root) {
            AuroraGlassCard(variant: .standard, cornerRadius: 16, interactive: true) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(MobileTheme.ember.opacity(0.15))
                            .frame(width: 48, height: 48)
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(MobileTheme.ember)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        CommunityEditorialTypography.eyebrowText("Community")
                        Text(participates ? "Your burn vs other burners" : "See how you compare")
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        if let headlineTokens {
                            Text(headlineTokens)
                                .font(CommunityEditorialTypography.metaStrip)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        } else {
                            Text("Opt in when you're ready — no pressure.")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pulse.community.card")
    }
}

enum CommunityRoute: Hashable {
    case root
}
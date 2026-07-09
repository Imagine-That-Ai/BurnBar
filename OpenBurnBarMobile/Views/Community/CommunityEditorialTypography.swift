import SwiftUI
import OpenBurnBarCore

/// Editorial Observatory labels for Community boards (matches Intelligence Brief / Insights).
enum CommunityEditorialTypography {
    static let eyebrow = Font.system(size: 11, weight: .semibold, design: .default)
        .leading(.tight)
    static let displayHeadline = Font.system(size: 28, weight: .heavy, design: .rounded)
        .leading(.tight)
    static let sectionTitle = Font.system(size: 15, weight: .semibold, design: .default)
    static let metaStrip = UnifiedDesignSystem.Typography.monoTiny
    static let instrument = Font.system(size: 13, weight: .medium, design: .monospaced)

    static func eyebrowText(_ text: String) -> some View {
        Text(text.uppercased())
            .font(eyebrow)
            .tracking(2)
            .foregroundStyle(MobileTheme.Colors.textMuted)
    }

    static var mercuryHairline: some View {
        Rectangle()
            .fill(MobileTheme.hermesMercury.opacity(0.35))
            .frame(height: 1)
    }
}
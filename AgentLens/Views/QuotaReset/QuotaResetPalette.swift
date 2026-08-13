import SwiftUI
import OpenBurnBarCore

struct QuotaResetPalette {
    let metal: Color
    let ring: Color
    let fill: Color
    let ink: Color
    let dust: Color

    static func resolved(for provider: AgentProvider, kind: QuotaResetKind, colorScheme: ColorScheme) -> QuotaResetPalette {
        let theme = ProviderTheme.theme(for: provider)
        let metal: Color
        switch kind {
        case .scheduled:
            metal = Color(hex: "C5CDD6")
        case .surprise:
            metal = Color(hex: "7EB6FF")
        case .bankedGrant, .bankedRedeem:
            metal = Color(hex: "E4C37A")
        }

        switch provider {
        case .xAI:
            let ink = colorScheme == .dark ? Color.white : Color(hex: "111111")
            return QuotaResetPalette(
                metal: metal,
                ring: Color(hex: "3A3A3A"),
                fill: Color(hex: "111111"),
                ink: ink,
                dust: Color.white.opacity(colorScheme == .dark ? 0.55 : 0.18)
            )
        case .warp:
            return QuotaResetPalette(
                metal: metal,
                ring: Color(hex: "1B1F24"),
                fill: Color(hex: "F4F6F8"),
                ink: Color(hex: "111111"),
                dust: Color(hex: "1B1F24").opacity(0.22)
            )
        default:
            return QuotaResetPalette(
                metal: metal,
                ring: theme.primaryColor,
                fill: theme.accentColor,
                ink: theme.primaryColor,
                dust: theme.primaryColor.opacity(0.35)
            )
        }
    }
}

import SwiftUI
import OpenBurnBarCore

enum MobileTheme {
    static let ember   = Color(hex: "F45B69")
    static let amber   = Color(hex: "F28C38")
    static let blaze   = Color(hex: "E86100")
    static let whimsy  = Color(hex: "6A5ACD")

    static let background      = Color.adaptive(light: "F3E8E6", dark: "0D1117")
    static let surface         = Color.adaptive(light: "FAF5F2", dark: "161B22")
    static let surfaceElevated = Color.adaptive(light: "FDF8F5", dark: "1F2630")
    static let border          = Color.adaptive(light: "E8BFB5", dark: "30363D")

    static let textPrimary   = Color.adaptive(light: "2A1816", dark: "E6EDF3")
    static let textSecondary = Color.adaptive(light: "6E4E48", dark: "8B949E")
    static let textMuted     = Color.adaptive(light: "9A756D", dark: "6E7681")

    static let success = Color.adaptive(light: "3A7835", dark: "38D898")
    static let warning = Color.adaptive(light: "C47800", dark: "FFA800")
    static let error   = Color.adaptive(light: "D43030", dark: "FA5053")

    static let primaryGradient = LinearGradient(
        colors: [ember, amber],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        colors: [ember.opacity(0.08), amber.opacity(0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 16
    static let spacingLarge: CGFloat = 24
    static let cornerRadius: CGFloat = 16
    static let cornerRadiusSmall: CGFloat = 12

    /// Corner radius scale used by `MobileTheme.Radius.*` call sites. Mirrors
    /// the macOS DesignSystem `Radius` tokens.
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
    }

    /// Spacing scale used by `MobileTheme.Spacing.*` call sites. Mirrors the
    /// macOS DesignSystem token names (`xs/sm/md/lg/xl/xxl`) on a 4pt base.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    /// Typography scale used by `MobileTheme.Typography.*` call sites. Uses
    /// SF Pro Rounded everywhere to match the macOS DESIGN.md typography axis.
    enum Typography {
        static let display    = Font.system(size: 32, weight: .bold,     design: .rounded)
        static let title      = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline   = Font.system(size: 17, weight: .semibold, design: .rounded)
        static let body       = Font.system(size: 15, weight: .regular,  design: .rounded)
        static let footnote   = Font.system(size: 13, weight: .regular,  design: .rounded)
        static let caption    = Font.system(size: 12, weight: .medium,   design: .rounded)
        static let mono       = Font.system(size: 14, weight: .medium,   design: .monospaced)
        static let monoSmall  = Font.system(size: 12, weight: .medium,   design: .monospaced)
    }

    /// Aliases for surface/text/state tokens grouped under `Colors` for views
    /// that prefer the namespaced form. The flat `MobileTheme.background`
    /// tokens above remain canonical; this is a thin façade so call sites can
    /// read `MobileTheme.Colors.surface` etc.
    enum Colors {
        static let background      = MobileTheme.background
        static let surface         = MobileTheme.surface
        static let surfaceElevated = MobileTheme.surfaceElevated
        static let border          = MobileTheme.border

        static let textPrimary   = MobileTheme.textPrimary
        static let textSecondary = MobileTheme.textSecondary
        static let textMuted     = MobileTheme.textMuted

        static let success = MobileTheme.success
        static let warning = MobileTheme.warning
        static let error   = MobileTheme.error

        /// Generic accent used by buttons, links, and highlight glyphs.
        static let accent = MobileTheme.ember

        /// Primary brand color for a given provider. Mirrors the macOS
        /// `DesignSystem.Colors` provider palette so iOS feels visually
        /// consistent with the menu bar app.
        static func primary(for provider: AgentProvider) -> Color {
            switch provider {
            case .claudeCode:  return MobileTheme.ember
            case .factory:     return MobileTheme.whimsy
            case .codex:       return Color(hex: "10A37F")
            case .cursor:      return Color(hex: "1DAAAF")
            case .kimi:        return Color(hex: "2CCAC0")
            case .minimax:     return Color(hex: "D49A3A")
            case .zai:         return Color(hex: "D49A3A")
            case .geminiCLI:   return Color(hex: "4285F4")
            case .copilot:     return Color(hex: "8E86D0")
            case .aider:       return Color(hex: "C8604E")
            case .cline:       return MobileTheme.amber
            case .kiloCode:    return MobileTheme.blaze
            case .rooCode:     return Color(hex: "9080D8")
            case .forgeDev:    return Color(hex: "C8604E")
            case .augment:     return Color(hex: "8E86D0")
            case .hermes:      return Color(hex: "C8BFB5")
            case .goose:       return Color(hex: "8E86D0")
            case .openClaw:    return Color(hex: "E87060")
            case .ollama:      return Color(hex: "8B8589")
            case .windsurf:    return Color(hex: "1DAAAF")
            case .warp:        return Color(hex: "E87060")
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor(
            light: UIColor(Color(hex: light)),
            dark: UIColor(Color(hex: dark))
        ))
    }
}

extension UIColor {
    convenience init(light: UIColor, dark: UIColor) {
        self.init { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        }
    }
}

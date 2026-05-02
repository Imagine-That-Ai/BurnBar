import SwiftUI

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

import AppKit
import SwiftUI
import OpenBurnBarCore

extension Color {
    /// Creates a Color that automatically adapts to macOS dark/light appearance.
    static func adaptive(light: String, dark: String) -> Color {
        adaptive(editorial: light, light: light, dark: dark)
    }

    /// Skin- and appearance-aware token color. When the Editorial skin is active
    /// the `editorial` hex wins regardless of aqua/dark appearance (the skin is
    /// light-locked, mirroring the app.burnbar.ai console); otherwise resolves
    /// `light`/`dark` off the system appearance. Supports 8-digit `AARRGGBB`
    /// hexes so editorial ink hairlines can carry alpha.
    static func adaptive(editorial: String, light: String, dark: String) -> Color {
        Color(NSColor(name: nil) { appearance in
            let hex: String = AppSkin.current == .editorial
                ? editorial
                : (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(nsColorHex: hex)
        })
    }
}

private extension NSColor {
    /// Parses `RRGGBB` or `AARRGGBB` (alpha-first) hex into an sRGB `NSColor`.
    convenience init(nsColorHex hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&int)
        let a, r, g, b: UInt64
        if trimmed.count == 8 {
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        } else {
            (a, r, g, b) = (255, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        }
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

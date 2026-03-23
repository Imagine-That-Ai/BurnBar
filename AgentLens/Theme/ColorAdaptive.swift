import AppKit
import SwiftUI

extension Color {
    /// Creates a Color that automatically adapts to macOS dark/light appearance.
    static func adaptive(light: String, dark: String) -> Color {
        Color(NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            var int: UInt64 = 0
            Scanner(string: hex).scanHexInt64(&int)
            return NSColor(
                srgbRed:   CGFloat((int >> 16) & 0xFF) / 255,
                green:     CGFloat((int >>  8) & 0xFF) / 255,
                blue:      CGFloat( int        & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

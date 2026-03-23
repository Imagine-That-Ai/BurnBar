import SwiftUI
import Combine

/// Unified theme manager using the DesignSystem.
/// All colors, typography, and spacing now come from DesignSystem.
/// Provider-specific themes are defined in ProviderTheme.swift.
@Observable
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    typealias DS = DesignSystem

    static let chartPalette: [Color] = [
        DesignSystem.Colors.ember,
        DesignSystem.Colors.amber,
        DesignSystem.Colors.blaze,
        DesignSystem.Colors.whimsy,
        Color(hex: "34D399"),
        Color(hex: "F472B6"),
    ]

    static func chartColor(for index: Int) -> Color {
        chartPalette[index % chartPalette.count]
    }
}

import SwiftUI
import Combine

/// Unified theme manager using the DesignSystem.
/// All colors, typography, and spacing now come from DesignSystem.
/// Provider-specific themes are defined in ProviderTheme.swift.
@Observable
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    // Re-export DesignSystem for convenience
    typealias DS = DesignSystem

    // Chart palette — used for multi-provider charts
    static let chartPalette: [Color] = [
        DesignSystem.Colors.coral,
        DesignSystem.Colors.purple,
        DesignSystem.Colors.teal,
        DesignSystem.Colors.gold,
        Color(hex: "34D399"),
        Color(hex: "F472B6"),
    ]

    static func chartColor(for index: Int) -> Color {
        chartPalette[index % chartPalette.count]
    }
}

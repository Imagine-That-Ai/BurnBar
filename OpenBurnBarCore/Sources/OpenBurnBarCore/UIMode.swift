import SwiftUI

// MARK: - UI Mode
/// App-wide visual persona. Each mode adapts typography, color, spacing,
/// and motion to fit a specific use-case or mood.
public enum UIMode: String, CaseIterable, Identifiable, Sendable {
    case standard = "standard"
    case cooking  = "cooking"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .cooking:  return "Cooking"
        }
    }

    public var description: String {
        switch self {
        case .standard: return "The classic Aurora experience"
        case .cooking:  return "Big, bright, and finger-friendly"
        }
    }

    public var iconName: String {
        switch self {
        case .standard: return "sparkles"
        case .cooking:  return "frying.pan" // SF Symbol fallback; replaced by SVG asset in picker
        }
    }
}

// MARK: - UIMode Theme
/// Mode-specific design token overrides. Delegates to `UnifiedDesignSystem`
/// for standard mode and computes adapted values for each persona.
public struct UIModeTheme {
    public let mode: UIMode

    public init(mode: UIMode) {
        self.mode = mode
    }

    // MARK: - Colors

    public var primaryAccent: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.ember
        case .cooking:  return Color(hex: "FF5F1F") // Sriracha
        }
    }

    public var secondaryAccent: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.amber
        case .cooking:  return Color(hex: "FFD700") // Lemon
        }
    }

    public var tertiaryAccent: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.blaze
        case .cooking:  return Color(hex: "32CD32") // Basil
        }
    }

    public var quaternaryAccent: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.whimsy
        case .cooking:  return Color(hex: "FF1493") // Dragonfruit
        }
    }

    public var background: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.background
        case .cooking:  return Color(light: "FFF8F0", dark: "1A120B") // Vanilla / Dark Chocolate
        }
    }

    public var surface: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.surface
        case .cooking:  return Color(light: "FFFFFF", dark: "2D1F14") // Meringue / Espresso
        }
    }

    public var textPrimary: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.textPrimary
        case .cooking:  return Color(light: "1A0F00", dark: "FFF5E6") // Coffee / Cream
        }
    }

    public var textSecondary: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.textSecondary
        case .cooking:  return Color(light: "5C3D2E", dark: "D4A574") // Caramel
        }
    }

    public var border: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.border
        case .cooking:  return Color(light: "FFB347", dark: "8B4513") // Apricot / Cocoa
        }
    }

    // MARK: - Typography

    public var displayLarge: Font {
        switch mode {
        case .standard: return UnifiedDesignSystem.Typography.displayLarge
        case .cooking:  return .system(size: 42, weight: .bold, design: .rounded)
        }
    }

    public var display: Font {
        switch mode {
        case .standard: return UnifiedDesignSystem.Typography.display
        case .cooking:  return .system(size: 34, weight: .bold, design: .rounded)
        }
    }

    public var title: Font {
        switch mode {
        case .standard: return UnifiedDesignSystem.Typography.title
        case .cooking:  return .system(size: 24, weight: .semibold, design: .rounded)
        }
    }

    public var headline: Font {
        switch mode {
        case .standard: return UnifiedDesignSystem.Typography.headline
        case .cooking:  return .system(size: 20, weight: .semibold, design: .rounded)
        }
    }

    public var body: Font {
        switch mode {
        case .standard: return UnifiedDesignSystem.Typography.body
        case .cooking:  return .system(size: 17, weight: .regular, design: .rounded)
        }
    }

    public var caption: Font {
        switch mode {
        case .standard: return UnifiedDesignSystem.Typography.caption
        case .cooking:  return .system(size: 14, weight: .medium, design: .rounded)
        }
    }

    public var tiny: Font {
        switch mode {
        case .standard: return UnifiedDesignSystem.Typography.tiny
        case .cooking:  return .system(size: 13, weight: .medium, design: .rounded)
        }
    }

    // MARK: - Spacing

    public var spacingScale: CGFloat {
        switch mode {
        case .standard: return 1.0
        case .cooking:  return 1.25
        }
    }

    // MARK: - Radius

    public var extraRadius: CGFloat {
        switch mode {
        case .standard: return 0
        case .cooking:  return 4
        }
    }

    // MARK: - Motion

    public var ambientAnimationsEnabled: Bool {
        switch mode {
        case .standard: return true
        case .cooking:  return false
        }
    }

    // MARK: - Gradients

    public var heroGradient: LinearGradient {
        switch mode {
        case .standard: return UnifiedDesignSystem.primaryGradient
        case .cooking:
            return LinearGradient(
                colors: [Color(hex: "FF5F1F"), Color(hex: "FFD700")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    public var cardGradient: LinearGradient {
        switch mode {
        case .standard: return UnifiedDesignSystem.cardGradient
        case .cooking:
            return LinearGradient(
                colors: [
                    Color(hex: "FFFFFF").opacity(0.15),
                    Color(hex: "FFF8F0").opacity(0.10),
                    Color(hex: "FF5F1F").opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Environment

private struct UIModeKey: EnvironmentKey {
    static let defaultValue: UIMode = .standard
}

public extension EnvironmentValues {
    var uiMode: UIMode {
        get { self[UIModeKey.self] }
        set { self[UIModeKey.self] = newValue }
    }
}

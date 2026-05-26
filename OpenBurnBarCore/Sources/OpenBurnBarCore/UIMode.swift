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
        case .cooking:  return Color(hex: "FF2A85") // Vibrant Pitaya Pink
        }
    }

    public var secondaryAccent: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.amber
        case .cooking:  return Color(hex: "FFA500") // Luminous Mango Orange
        }
    }

    public var tertiaryAccent: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.blaze
        case .cooking:  return Color(hex: "39FF14") // Neon Lime Green
        }
    }

    public var quaternaryAccent: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.whimsy
        case .cooking:  return Color(hex: "00F5FF") // Electric Turquoise/Kiwi
        }
    }

    public var background: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.background
        case .cooking:  return Color(light: "FFFDF0", dark: "12041A") // Coconut Cream / Deep Pitaya Acai
        }
    }

    public var surface: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.surface
        case .cooking:  return Color(light: "FFF0F5", dark: "260835") // Guava Sorbet / Translucent Pitaya Pulp
        }
    }

    public var textPrimary: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.textPrimary
        case .cooking:  return Color(light: "3B0A20", dark: "FFF5FA") // Berry Jam / Sweet Meringue Cream
        }
    }

    public var textSecondary: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.textSecondary
        case .cooking:  return Color(light: "B85C00", dark: "FCA3B7") // Papaya Gold / Soft Peach Pink
        }
    }

    public var border: Color {
        switch mode {
        case .standard: return UnifiedDesignSystem.Colors.border
        case .cooking:  return Color(light: "FF4D80", dark: "D80073") // Strawberry Gloss / Bright Magenta Edge
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
                colors: [Color(hex: "FF2A85"), Color(hex: "FFA500"), Color(hex: "39FF14")],
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
                    Color(hex: "FFFFFF").opacity(0.20),
                    Color(hex: "FF2A85").opacity(0.06),
                    Color(hex: "FFA500").opacity(0.02)
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

    var uiTheme: UIModeTheme {
        UIModeTheme(mode: uiMode)
    }
}

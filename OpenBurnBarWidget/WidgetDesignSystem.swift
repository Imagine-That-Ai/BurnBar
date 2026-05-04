import SwiftUI
import WidgetKit
import OpenBurnBarCore

// MARK: - Widget Design System

/// Self-contained design tokens for the widget extension.
/// Mirrors the main app's `DesignSystem` without creating a target dependency.
enum WidgetDesignSystem {

    // MARK: - Colors

    enum Colors {
        static let ember  = Color(hex: "F45B69")
        static let amber  = Color(hex: "F28C38")
        static let blaze  = Color(hex: "E86100")
        static let whimsy = Color(hex: "6A5ACD")

        static let backgroundLight = Color(hex: "F3E8E6")
        static let surfaceLight    = Color(hex: "FAF5F2")
        static let surfaceElevated = Color(hex: "FDF8F5")

        static let textPrimary   = Color.primary
        static let textSecondary = Color.secondary
        static let textMuted     = Color.secondary.opacity(0.7)

        static let success = Color.green
        static let warning = Color.orange

        static let primaryGradient = LinearGradient(
            colors: [ember.opacity(0.18), amber.opacity(0.12), blaze.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let headerGradient = LinearGradient(
            colors: [ember.opacity(0.10), amber.opacity(0.06)],
            startPoint: .leading,
            endPoint: .trailing
        )

        static let accentGradient = LinearGradient(
            colors: [ember, amber],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Typography

    enum Typography {
        static let displayLarge = Font.system(size: 36, weight: .bold, design: .rounded)
        static let display      = Font.system(size: 28, weight: .bold, design: .rounded)
        static let title        = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline     = Font.system(size: 16, weight: .semibold, design: .rounded)
        static let body         = Font.system(size: 14, weight: .regular, design: .rounded)
        static let caption      = Font.system(size: 12, weight: .medium, design: .rounded)
        static let tiny         = Font.system(size: 11, weight: .medium, design: .rounded)
        static let micro        = Font.system(size: 10, weight: .semibold, design: .rounded)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: - Radius

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let full: CGFloat = 9999
    }
}

// MARK: - View Modifiers

extension View {
    func widgetCardBackground() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.md)
                .fill(WidgetDesignSystem.Colors.surfaceLight)
        )
    }

    func widgetGradientBackground() -> some View {
        self.background(WidgetDesignSystem.Colors.primaryGradient)
    }

    func widgetHeaderBackground() -> some View {
        self.background(
            Rectangle()
                .fill(WidgetDesignSystem.Colors.headerGradient)
        )
    }
}

// MARK: - Reusable Widget Components

struct WidgetProviderPill: View {
    let name: String
    let tokens: Int?

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(name)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let providerEnum,
               UIImage(named: providerEnum.bundledLogoName) != nil {
                UnifiedProviderLogoView(provider: providerEnum, size: 12)
            } else {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WidgetDesignSystem.Colors.amber)
            }

            Text(name)
                .font(WidgetDesignSystem.Typography.tiny)
                .lineLimit(1)

            if let tokens {
                Text("· \(tokens.formatAsTokens())")
                    .font(WidgetDesignSystem.Typography.micro)
                    .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(WidgetDesignSystem.Colors.amber.opacity(0.10))
        )
        .overlay(
            Capsule()
                .stroke(WidgetDesignSystem.Colors.amber.opacity(0.25), lineWidth: 1)
        )
        .foregroundStyle(WidgetDesignSystem.Colors.amber)
    }
}

struct WidgetMetricBadge: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(WidgetDesignSystem.Typography.micro)
                    .foregroundStyle(WidgetDesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
            }
            Text(value)
                .font(WidgetDesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.sm)
                .fill(color.opacity(0.08))
        )
    }
}

struct WidgetProgressBar: View {
    let value: Double
    let total: Double
    let color: Color

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(value / total, 1.0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.full)
                    .fill(color.opacity(0.12))
                    .frame(height: 5)

                RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.full)
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * fraction, height: 5)
            }
        }
        .frame(height: 5)
    }
}

struct WidgetModelChip: View {
    let model: String

    var body: some View {
        Text(model)
            .font(WidgetDesignSystem.Typography.micro)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(WidgetDesignSystem.Colors.whimsy.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(WidgetDesignSystem.Colors.whimsy.opacity(0.25), lineWidth: 1)
            )
            .foregroundStyle(WidgetDesignSystem.Colors.whimsy)
    }
}

struct WidgetFlameGlow: View {
    var body: some View {
        Image(systemName: "flame.fill")
            .font(.system(size: 64, weight: .bold))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        WidgetDesignSystem.Colors.ember.opacity(0.10),
                        WidgetDesignSystem.Colors.amber.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .blur(radius: 8)
    }
}

// MARK: - Color Hex Init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

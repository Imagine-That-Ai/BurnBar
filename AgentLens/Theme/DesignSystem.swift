import AppKit
import SwiftUI

// MARK: - Adaptive Color Helper

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

// MARK: - Design System

/// Unified design tokens for BurnBar.
/// Uses macOS 26+ GlassButtonStyle / GlassProminentButtonStyle where available,
/// with dark glass fallbacks on older OS versions.
enum DesignSystem {

    // MARK: - Colors

    enum Colors {
        // Brand accents — shift slightly between modes for proper contrast
        static let coral  = Color.adaptive(light: "D96B5A", dark: "E07868")
        static let purple = Color.adaptive(light: "7E74C4", dark: "8E86D0")
        static let teal   = Color.adaptive(light: "1DAAAF", dark: "2CBEC8")
        static let gold   = Color.adaptive(light: "D49A3A", dark: "D49A3A")

        // Surfaces
        static let background     = Color.adaptive(light: "F5F0EB", dark: "0D1117")
        static let surface        = Color.adaptive(light: "FAF7F4", dark: "161B22")
        static let surfaceElevated = Color.adaptive(light: "FFFFFF", dark: "1C2128")
        static let border         = Color.adaptive(light: "DDD8D1", dark: "30363D")
        static let borderSubtle   = Color.adaptive(light: "EDE9E4", dark: "21262D")

        // Text
        static let textPrimary   = Color.adaptive(light: "1A1208", dark: "FFFFFF")
        static let textSecondary = Color.adaptive(light: "4A4038", dark: "8B949E")
        static let textMuted     = Color.adaptive(light: "8A7E72", dark: "6E7681")

        // Semantic
        static let success = Color.adaptive(light: "2E8B57", dark: "34D399")
        static let warning = Color.adaptive(light: "C97F1A", dark: "FBBF24")
        static let error   = Color.adaptive(light: "C93D3D", dark: "F45B69")

        static let primaryGradient = LinearGradient(
            colors: [coral, purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let accentGradient = LinearGradient(
            colors: [teal, purple],
            startPoint: .leading,
            endPoint: .trailing
        )

        static let cardGradient = LinearGradient(
            colors: [
                coral.opacity(0.08),
                purple.opacity(0.06),
                teal.opacity(0.04)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static func primary(for provider: AgentProvider) -> Color {
            switch provider {
            case .factory: return purple
            case .claudeCode: return Color(hex: "CC785C")
            case .copilot: return Color(hex: "23EA3B")
            case .aider: return Color(hex: "FF6B35")
            case .cursor: return Color(hex: "AC8C57")
            case .codex: return Color(hex: "00A67E")
            case .zai: return Color(hex: "8B5CF6")
            case .minimax: return Color(hex: "F59E0B")
            case .kimi: return Color(hex: "6366F1")
            }
        }

        static func accent(for provider: AgentProvider) -> Color {
            switch provider {
            case .factory: return coral
            case .claudeCode: return Color(hex: "D4A574")
            case .copilot: return Color(hex: "0969DA")
            case .aider: return teal
            case .cursor: return Color(hex: "007AFF")
            case .codex: return Color(hex: "00C48C")
            case .zai: return Color(hex: "A78BFA")
            case .minimax: return Color(hex: "FCD34D")
            case .kimi: return Color(hex: "818CF8")
            }
        }

        static func chartPalette(for provider: AgentProvider) -> [Color] {
            switch provider {
            case .factory: return [purple, coral, teal, Color(hex: "A78BFA")]
            case .claudeCode: return [Color(hex: "CC785C"), Color(hex: "D4A574"), Color(hex: "8B949E"), Color(hex: "E8C4A0")]
            case .copilot: return [Color(hex: "23EA3B"), Color(hex: "0969DA"), coral, purple]
            case .aider: return [Color(hex: "FF6B35"), teal, coral, purple]
            case .cursor: return [Color(hex: "AC8C57"), Color(hex: "007AFF"), teal, coral]
            case .codex: return [Color(hex: "00A67E"), Color(hex: "00C48C"), Color(hex: "7FDBDA"), Color(hex: "66CDAA")]
            case .zai: return [Color(hex: "8B5CF6"), Color(hex: "A78BFA"), Color(hex: "6366F1"), Color(hex: "7C3AED")]
            case .minimax: return [Color(hex: "F59E0B"), Color(hex: "FCD34D"), Color(hex: "D97706"), Color(hex: "FBBF24")]
            case .kimi: return [Color(hex: "6366F1"), Color(hex: "818CF8"), Color(hex: "A5B4FC"), Color(hex: "C7D2FE")]
            }
        }
    }

    // MARK: - Typography

    enum Typography {
        static let displayLarge = Font.system(size: 36, weight: .bold, design: .rounded)
        static let display = Font.system(size: 28, weight: .bold, design: .rounded)
        static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline = Font.system(size: 16, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 14, weight: .regular, design: .rounded)
        static let caption = Font.system(size: 12, weight: .medium, design: .rounded)
        static let tiny = Font.system(size: 11, weight: .medium, design: .rounded)

        static let monoLarge = Font.system(size: 28, weight: .bold, design: .monospaced)
        static let mono = Font.system(size: 14, weight: .medium, design: .monospaced)
        static let monoSmall = Font.system(size: 12, weight: .medium, design: .monospaced)
        static let monoTiny = Font.system(size: 11, weight: .medium, design: .monospaced)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // MARK: - Corner Radius

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
        static let full: CGFloat = 9999
    }

    // MARK: - Animation

    enum Animation {
        static let standard = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.75)
        static let gentle = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.85)
        static let snappy = SwiftUI.Animation.easeOut(duration: 0.15)
        static let hover = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.8)
    }
}

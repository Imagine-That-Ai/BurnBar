import SwiftUI

/// Cross-platform frosted glass card with gradient sheen and luminous border.
/// Used identically on macOS, iPad, and iOS for visual consistency.
/// Mode-Aware: in Cooking Mode it scales padding, increases corner radius, and shifts borders to warm culinary colors.
public struct UnifiedGlassCard<Content: View>: View {
    public let interactive: Bool
    @ViewBuilder public let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.uiMode) private var uiMode
    @State private var isHovered = false

    public init(interactive: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.interactive = interactive
        self.content = content
    }

    public var body: some View {
        let theme = UIModeTheme(mode: uiMode)
        let paddingScale = uiMode == .cooking ? theme.spacingScale : 1.0
        let radiusOffset = uiMode == .cooking ? theme.extraRadius : 0.0
        let cornerRadius = UnifiedDesignSystem.Radius.lg + radiusOffset

        let card = content()
            .padding(UnifiedDesignSystem.Spacing.lg * paddingScale)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(glassSheenGradient(theme: theme))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(glassEdgeGradient(theme: theme), lineWidth: uiMode == .cooking ? 1.0 : 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(isHovered ? 1.015 : 1.0)
            .animation(UnifiedDesignSystem.Animation.hover, value: isHovered)

        if interactive {
            card
                .onHover { hovering in isHovered = hovering }
        } else {
            card
        }
    }

    // MARK: - Sheen

    private func glassSheenGradient(theme: UIModeTheme) -> LinearGradient {
        if uiMode == .cooking {
            if colorScheme == .light {
                return LinearGradient(
                    colors: [
                        theme.primaryAccent.opacity(0.08),
                        Color.clear,
                        theme.tertiaryAccent.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                return LinearGradient(
                    colors: [
                        theme.primaryAccent.opacity(0.12),
                        Color.clear,
                        theme.secondaryAccent.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            if colorScheme == .light {
                return LinearGradient(
                    colors: [
                        UnifiedDesignSystem.Colors.ember.opacity(0.07),
                        Color.clear,
                        UnifiedDesignSystem.Colors.blaze.opacity(0.045)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                return LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color.clear,
                        UnifiedDesignSystem.Colors.ember.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    // MARK: - Edge

    private func glassEdgeGradient(theme: UIModeTheme) -> LinearGradient {
        if uiMode == .cooking {
            if colorScheme == .light {
                return LinearGradient(
                    colors: [
                        theme.primaryAccent.opacity(0.28),
                        theme.border.opacity(0.6),
                        theme.tertiaryAccent.opacity(0.22)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                return LinearGradient(
                    colors: [
                        theme.primaryAccent.opacity(0.35),
                        theme.border.opacity(0.4),
                        theme.secondaryAccent.opacity(0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            if colorScheme == .light {
                return LinearGradient(
                    colors: [
                        UnifiedDesignSystem.Colors.ember.opacity(0.22),
                        UnifiedDesignSystem.Colors.border.opacity(0.55),
                        UnifiedDesignSystem.Colors.blaze.opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                return LinearGradient(
                    colors: [
                        Color.white.opacity(0.12),
                        UnifiedDesignSystem.Colors.border.opacity(0.35),
                        UnifiedDesignSystem.Colors.ember.opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

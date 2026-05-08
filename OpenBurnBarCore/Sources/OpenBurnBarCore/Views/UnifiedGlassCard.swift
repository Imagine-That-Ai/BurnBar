import SwiftUI

/// Cross-platform frosted glass card with gradient sheen and luminous border.
/// Used identically on macOS, iPad, and iOS for visual consistency.
public struct UnifiedGlassCard<Content: View>: View {
    public let interactive: Bool
    @ViewBuilder public let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isPressed = false

    public init(interactive: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.interactive = interactive
        self.content = content
    }

    public var body: some View {
        let card = content()
            .padding(UnifiedDesignSystem.Spacing.lg)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                        .fill(glassSheenGradient)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                    .stroke(glassEdgeGradient, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous))
            .scaleEffect(isPressed ? 0.98 : (isHovered ? 1.01 : 1.0))
            .animation(UnifiedDesignSystem.Animation.hover, value: isHovered)
            .animation(UnifiedDesignSystem.Animation.snappy, value: isPressed)

        // Critical: only attach hover/drag gestures when the card is
        // actually interactive. The previous unconditional
        // `DragGesture(minimumDistance: 0)` was installed on every glass
        // card and swallowed scroll touches, so any ScrollView with stacked
        // glass cards (Session Detail, Settings, etc.) couldn't scroll.
        if interactive {
            card
                .onHover { hovering in isHovered = hovering }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isPressed = true }
                        .onEnded { _ in isPressed = false }
                )
        } else {
            card
        }
    }

    // MARK: - Sheen

    private var glassSheenGradient: LinearGradient {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.ember.opacity(0.07),
                    Color.clear,
                    UnifiedDesignSystem.Colors.blaze.opacity(0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
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

    // MARK: - Edge

    private var glassEdgeGradient: LinearGradient {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.ember.opacity(0.22),
                    UnifiedDesignSystem.Colors.border.opacity(0.55),
                    UnifiedDesignSystem.Colors.blaze.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
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

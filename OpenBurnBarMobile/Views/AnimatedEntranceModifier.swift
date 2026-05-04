import SwiftUI

// MARK: - Staggered Entrance Modifier

struct StaggeredEntrance: ViewModifier {
    let delay: Double
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85).delay(delay)) {
                    appeared = true
                }
            }
    }
}

extension View {
    func staggeredEntrance(delay: Double = 0) -> some View {
        modifier(StaggeredEntrance(delay: delay))
    }
}

// MARK: - Glass Card (iPad)

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(MobileTheme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                            .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - Hover Scale Effect

struct HoverScale: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(MobileTheme.Animation.hover, value: isHovered)
            .onHover { hovered in
                isHovered = hovered
            }
    }
}

extension View {
    func hoverScale() -> some View {
        modifier(HoverScale())
    }
}

// MARK: - Chart Entrance Animation

struct ChartEntrance: ViewModifier {
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.95, anchor: .bottom)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                    appeared = true
                }
            }
    }
}

extension View {
    func chartEntrance() -> some View {
        modifier(ChartEntrance())
    }
}

// MARK: - Page Push Transition

struct PushTransition: ViewModifier {
    let direction: Edge
    @State private var offset: CGFloat = 100
    @State private var opacity: Double = 0

    func body(content: Content) -> some View {
        content
            .offset(x: direction == .trailing || direction == .leading ? offset : 0,
                    y: direction == .top || direction == .bottom ? offset : 0)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    offset = 0
                    opacity = 1
                }
            }
    }
}

extension View {
    func pushTransition(from direction: Edge = .trailing) -> some View {
        modifier(PushTransition(direction: direction))
    }
}

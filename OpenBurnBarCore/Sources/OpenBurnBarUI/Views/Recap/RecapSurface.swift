import SwiftUI
import OpenBurnBarRecap

// MARK: - Surface

/// The card plate: Liquid Glass where the OS has it, a material stack where it
/// does not.
///
/// The app deploys to macOS 14 / iOS 17, so glass is always behind
/// `#available` with a fallback that reads as close to the same surface. Routing
/// every card through one modifier is also what makes the user's transparency
/// preference and Reduce Transparency apply to the whole deck at once.
public struct RecapSurface: ViewModifier {

    public let accent: Color
    public let cornerRadius: CGFloat
    /// Heroes carry slightly more presence than tiles.
    public let isProminent: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawTransparency: Double = 0

    public init(accent: Color, cornerRadius: CGFloat, isProminent: Bool = false) {
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.isProminent = isProminent
    }

    private var transparency: Double {
        LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: reduceTransparency)
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    plate(shape: shape)
                    // The card's own accent, kept faint — colour should say
                    // "this card is about Claude", not "look at me".
                    shape.fill(RecapTheme.wash(accent))
                    let frost = LiquidGlassTransparency.frostScrimOpacity(transparency)
                    if frost > 0 {
                        shape.fill(.thickMaterial).opacity(frost)
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    accent.opacity(isProminent ? 0.30 : 0.18),
                    lineWidth: 0.75
                )
            }
            .clipShape(shape)
    }

    @ViewBuilder
    private func plate(shape: RoundedRectangle) -> some View {
        if #available(macOS 26, iOS 26, *) {
            shape
                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.28))
                .glassEffect(
                    LiquidGlassTransparency.usesClearGlass(transparency) ? .clear : .regular,
                    in: shape
                )
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(UnifiedDesignSystem.Colors.surface.opacity(isProminent ? 0.55 : 0.45))
            }
        }
    }
}

public extension View {
    /// The recap's card plate. Every card goes through this.
    func recapSurface(
        accent: Color,
        cornerRadius: CGFloat = RecapTheme.Layout.cardCornerRadius,
        isProminent: Bool = false
    ) -> some View {
        modifier(RecapSurface(accent: accent, cornerRadius: cornerRadius, isProminent: isProminent))
    }
}

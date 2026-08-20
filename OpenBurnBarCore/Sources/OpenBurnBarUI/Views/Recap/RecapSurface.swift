import SwiftUI

// MARK: - Transparency preference
//
// Mirrors the semantics of the two per-app `Theme/LiquidGlass.swift` files,
// reading the same UserDefaults key so a preference set anywhere in the app
// applies here too. The shared UI module has no glass vocabulary of its own,
// so the recap brings one rather than reaching into a platform target.

enum RecapGlassTransparency {
    static let storageKey = "liquidGlassTransparency"
    static let range: ClosedRange<Double> = -1.0...1.0

    /// Reduce Transparency always wins over "clearer": the accessibility flag
    /// only ever asks for more opacity, so positive values collapse to neutral
    /// while negative (frostier) values still apply.
    static func effective(_ raw: Double, reduceTransparency: Bool) -> Double {
        guard raw.isFinite else { return 0 }
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        return (reduceTransparency && clamped > 0) ? 0 : clamped
    }

    /// Kept in lockstep with `LiquidGlassTransparency.usesClearGlass` in both app
    /// targets. WWDC25 s219 permits `.clear` only over media-rich content and with a
    /// dimming layer; `value > 0.001` met neither, so at t = 0.3 the recap plate went
    /// `.clear` while every other plate in the app stayed `.regular` — one slider
    /// giving two opposite answers.
    static func usesClearGlass(_ value: Double, overMediaRichContent: Bool) -> Bool {
        guard overMediaRichContent else { return false }
        return value > 0.55
    }

    static func isOverMediaRichContent(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "useKernelBackdrop")
    }

    static func usesClearGlass(_ value: Double) -> Bool {
        usesClearGlass(value, overMediaRichContent: isOverMediaRichContent())
    }

    static func frostScrimOpacity(_ value: Double) -> Double {
        value < 0 ? 0.9 * -value : 0
    }

    static var stored: Double {
        UserDefaults.standard.object(forKey: storageKey) as? Double ?? 0
    }
}

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
    @AppStorage(RecapGlassTransparency.storageKey) private var rawTransparency: Double = 0

    public init(accent: Color, cornerRadius: CGFloat, isProminent: Bool = false) {
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.isProminent = isProminent
    }

    private var transparency: Double {
        RecapGlassTransparency.effective(rawTransparency, reduceTransparency: reduceTransparency)
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
                    let frost = RecapGlassTransparency.frostScrimOpacity(transparency)
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
                    RecapGlassTransparency.usesClearGlass(transparency) ? .clear : .regular,
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

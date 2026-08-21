import SwiftUI

// MARK: - Liquid Glass (iOS 26+) adapters
//
// The central bridge between OpenBurnBar's surfaces and the iOS 26 Liquid
// Glass design language. The app deploys to iOS 17,
// so every glass API is gated on `#available(iOS 26, *)` with a material
// fallback that approximates the look on older systems.
//
// Vocabulary:
//   • `liquidGlassSurface(in:fallback:)`     — glass plate for passive
//     surfaces: trays, floating bars, cards, sheet inserts.
//   • `liquidGlassInteractive(tint:in:fallback:)` — glass that responds to
//     touch, for tappable controls: buttons, chips, segmented options.
//   • `liquidGlassCircleButton(diameter:)`   — the recurring circular
//     toolbar/overlay control (close ✕, follow ⤓, etc.).
//   • `liquidGlassEffect(_:in:)`             — drop-in for SwiftUI's
//     `glassEffect(_:in:)` at iOS-26-only call sites, so one-off glass
//     accents honor the transparency preference too.
//   • `LiquidGlassGroup(spacing:)`           — `GlassEffectContainer` when
//     available (glass cannot sample other glass, so grouped elements must
//     share one container); passes content through untouched on iOS 17–25.
//   • `LiquidGlassTransparency`              — the user's glass transparency
//     preference (Frosted ⟷ System ⟷ Clear); see below.
//
// Brand rule: glass is the language of the utilitarian shell — tab bar,
// trays, sheets, toolbars, chips. The membership/Pro world keeps its
// obsidian-foil identity; there, glass appears only in system chrome
// (close buttons, sheet material), never on the foil cards themselves.

// MARK: - Transparency preference

/// User-adjustable glass transparency, shared across iOS and macOS through
/// the same UserDefaults key (the two `Theme/LiquidGlass.swift` files mirror
/// each other — keep in lockstep).
///
/// Semantics of the stored value `t` (Double, clamped to -1…1):
///   • `t == 0` — system default. Glass renders exactly as the OS does, which
///     already honors Settings → Accessibility → Reduce Transparency.
///   • `t > 0`  — clearer. The plate switches to the `.clear` glass variant
///     (more see-through); on iOS 17–25 the fallback material plate fades
///     toward the raw backdrop instead.
///   • `t < 0`  — frostier. A thick-material scrim slides in between the
///     plate and the content, approaching an opaque surface at -1.
///
/// Reduce Transparency always wins over "clearer": when the accessibility
/// flag is on, positive values resolve to 0 so glass never becomes *more*
/// transparent than the system allows. Frostier values still apply — they
/// only ever add opacity, which is the direction the flag asks for.
enum LiquidGlassTransparency {
    static let storageKey = "liquidGlassTransparency"
    static let range: ClosedRange<Double> = -1.0 ... 1.0

    /// Resolve the raw stored value against the accessibility state.
    static func effective(_ raw: Double, reduceTransparency: Bool) -> Double {
        guard raw.isFinite else { return 0 }
        let t = min(max(raw, range.lowerBound), range.upperBound)
        return (reduceTransparency && t > 0) ? 0 : t
    }

    /// The key the kernel backdrop stores its on/off state under.
    ///
    /// A literal rather than an import: this type is a pure preference model and must
    /// not depend on the view layer that owns the backdrop.
    static let mediaRichBackdropKey = "useKernelBackdrop"

    /// Whether a plate may use the `.clear` glass variant.
    ///
    /// WWDC25 s219 permits `.clear` only when **all three** hold: the element sits over
    /// media-rich content, the content layer tolerates a dimming layer, and the content
    /// above it is bold and bright. `.clear` has no adaptive behaviour — no light/dark
    /// flip, no shadow adaptation — so using it outside those conditions is what
    /// produces washed, low-contrast chrome.
    ///
    /// The previous mapping was `t > 0.001`: any nudge of the slider chose `.clear`
    /// over an ordinary opaque background, meeting none of the three.
    static func usesClearGlass(_ t: Double, overMediaRichContent: Bool) -> Bool {
        guard overMediaRichContent else { return false }
        return t > 0.55
    }

    static func isOverMediaRichContent(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: mediaRichBackdropKey)
    }

    static func usesClearGlass(_ t: Double) -> Bool {
        usesClearGlass(t, overMediaRichContent: isOverMediaRichContent())
    }

    /// Opacity of the thick-material frost scrim between plate and content.
    static func frostScrimOpacity(_ t: Double) -> Double { t < 0 ? 0.9 * -t : 0 }

    /// The dimming layer that makes `.clear` legitimate.
    ///
    /// Takes the media condition explicitly rather than reading `UserDefaults`, so the
    /// value is a pure function of its inputs and a test cannot be silently steered by
    /// whatever the developer happens to have switched on.
    ///
    /// Zero unless `.clear` is actually selected — below the threshold the plate is
    /// `.regular`, which is adaptive and needs no help.
    static func clearBridgeScrimOpacity(_ t: Double, overMediaRichContent: Bool) -> Double {
        guard usesClearGlass(t, overMediaRichContent: overMediaRichContent) else { return 0 }
        // `.clear` is only sanctioned *with* a dimming layer, so this is load-bearing
        // rather than cosmetic. Two changes from the old `max(0.06, 0.14 * (1 - t))`:
        // the floor is thick enough to actually carry legibility, and the ramp is
        // additive so it still varies across the valid range. The old form floored out
        // immediately once the threshold moved, leaving a constant — a dead gradient.
        return 0.12 + 0.10 * (1 - t)
    }

    /// Convenience for view code, which always evaluates against the live backdrop.
    static func clearBridgeScrimOpacity(_ t: Double) -> Double {
        clearBridgeScrimOpacity(t, overMediaRichContent: isOverMediaRichContent())
    }

    /// Opacity of the fallback material plate on iOS 17–25.
    static func fallbackPlateOpacity(_ t: Double) -> Double {
        t > 0 ? 1 - 0.78 * t : 1
    }
}

/// The frost/bridge scrim layered between the plate (glass or material) and
/// the content. Renders nothing at `t == 0`, so the default look is exactly
/// the unadjusted system render.
@ViewBuilder
private func liquidGlassScrim(for t: Double, in shape: some Shape) -> some View {
    let frost = LiquidGlassTransparency.frostScrimOpacity(t)
    let bridge = LiquidGlassTransparency.clearBridgeScrimOpacity(t)
    if frost > 0 {
        shape.fill(.thickMaterial).opacity(frost)
    } else if bridge > 0 {
        shape.fill(.ultraThinMaterial).opacity(bridge)
    }
}

private struct LiquidGlassSurfaceModifier<S: Shape>: ViewModifier {
    let tint: Color?
    let shape: S
    let fallback: Material

    @AppStorage(LiquidGlassTransparency.storageKey) private var rawTransparency: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: reduceTransparency)
        if #available(iOS 26, *) {
            let base: Glass = LiquidGlassTransparency.usesClearGlass(t) ? .clear : .regular
            let glass = tint.map { base.tint($0) } ?? base
            content
                .background { liquidGlassScrim(for: t, in: shape) }
                .glassEffect(glass, in: shape)
        } else {
            content
                .background { liquidGlassScrim(for: t, in: shape) }
                .background { if let tint { shape.fill(tint.opacity(0.22)) } }
                .background(fallback.opacity(LiquidGlassTransparency.fallbackPlateOpacity(t)), in: shape)
        }
    }
}

private struct LiquidGlassInteractiveModifier<S: Shape>: ViewModifier {
    let tint: Color?
    let shape: S
    let fallback: Material

    @AppStorage(LiquidGlassTransparency.storageKey) private var rawTransparency: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: reduceTransparency)
        if #available(iOS 26, *) {
            let base: Glass = LiquidGlassTransparency.usesClearGlass(t) ? .clear : .regular
            let glass = (tint.map { base.tint($0) } ?? base).interactive()
            content
                .background { liquidGlassScrim(for: t, in: shape) }
                .glassEffect(glass, in: shape)
        } else {
            content
                .background { liquidGlassScrim(for: t, in: shape) }
                .background { if let tint { shape.fill(tint.opacity(0.22)) } }
                .background(fallback.opacity(LiquidGlassTransparency.fallbackPlateOpacity(t)), in: shape)
        }
    }
}

extension View {
    /// Glass plate for a passive surface (tray, floating bar, card).
    /// Falls back to the given material on iOS 17–25.
    ///
    /// Pass `tint` to lean the plate toward a theme/brand cast. Keep it subtle —
    /// the tint refracts the backdrop, it does not paint over it.
    func liquidGlassSurface(
        tint: Color? = nil,
        in shape: some Shape,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(tint: tint, shape: shape, fallback: fallback))
    }

    /// Glass for a tappable control. Pass `tint` only to convey meaning
    /// (primary action, destructive), not decoration — toolbar glass is
    /// monochrome by default in the new design.
    func liquidGlassInteractive(
        tint: Color? = nil,
        in shape: some Shape,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        modifier(LiquidGlassInteractiveModifier(tint: tint, shape: shape, fallback: fallback))
    }

    /// The recurring circular glass control used in toolbars and as floating
    /// overlay buttons (close ✕, scroll-to-bottom, etc.).
    func liquidGlassCircleButton(diameter: CGFloat = 30) -> some View {
        frame(width: diameter, height: diameter)
            .liquidGlassInteractive(in: .circle)
    }
}

// MARK: - Tuned drop-in for direct `glassEffect` call sites

/// Mirror of SwiftUI's `Glass` fluent configuration, so iOS-26-only call
/// sites keep the familiar spelling while routing through the transparency
/// preference: `.liquidGlassEffect(.regular.tint(accent).interactive(), in: .circle)`.
@available(iOS 26.0, *)
struct LiquidGlassStyle {
    var tintColor: Color?
    var isInteractive: Bool

    static var regular: LiquidGlassStyle { .init(tintColor: nil, isInteractive: false) }

    func tint(_ color: Color?) -> LiquidGlassStyle {
        var style = self
        style.tintColor = color
        return style
    }

    func interactive(_ isEnabled: Bool = true) -> LiquidGlassStyle {
        var style = self
        style.isInteractive = isEnabled
        return style
    }

    /// The system glass this style resolves to at transparency `t`.
    func resolvedGlass(
        at t: Double,
        overMediaRichContent: Bool = LiquidGlassTransparency.isOverMediaRichContent()
    ) -> Glass {
        var glass: Glass = LiquidGlassTransparency.usesClearGlass(t, overMediaRichContent: overMediaRichContent) ? .clear : .regular
        if let tintColor { glass = glass.tint(tintColor) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}

@available(iOS 26.0, *)
private struct LiquidGlassEffectModifier<S: Shape>: ViewModifier {
    let style: LiquidGlassStyle
    let shape: S

    @AppStorage(LiquidGlassTransparency.storageKey) private var rawTransparency: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: reduceTransparency)
        content
            .background { liquidGlassScrim(for: t, in: shape) }
            .glassEffect(style.resolvedGlass(at: t), in: shape)
    }
}

@available(iOS 26.0, *)
extension View {
    /// Drop-in replacement for `glassEffect(_:in:)` that honors the user's
    /// Liquid Glass transparency preference. Use this instead of calling
    /// `glassEffect` directly inside `#available(iOS 26, *)` branches.
    func liquidGlassEffect(_ style: LiquidGlassStyle = .regular, in shape: some Shape) -> some View {
        modifier(LiquidGlassEffectModifier(style: style, shape: shape))
    }

    /// Shape-less overload mirroring `glassEffect(_:)`.
    ///
    /// Substitutes `ConcentricRectangle`, **not** `Capsule`. The system default is
    /// `DefaultGlassEffectShape()`, which concentrically matches the container it sits
    /// in; a capsule is only correct for pill-shaped controls, so the previous version
    /// silently rounded every shape-less call site into a lozenge and drifted away from
    /// system chrome. `ConcentricRectangle` is the closest public equivalent and is
    /// available on the same OS versions as the glass APIs themselves.
    func liquidGlassEffect(_ style: LiquidGlassStyle = .regular) -> some View {
        modifier(LiquidGlassEffectModifier(style: style, shape: ConcentricRectangle()))
    }
}

// MARK: - Grouping container

/// Wraps grouped glass elements in a `GlassEffectContainer` on iOS 26 so they
/// share one sampling region (glass cannot sample other glass); on earlier
/// systems the content renders unchanged. `spacing` should match the actual
/// layout spacing of the grouped elements.
struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26, *) {
            if let spacing {
                GlassEffectContainer(spacing: spacing, content: content)
            } else {
                GlassEffectContainer(content: content)
            }
        } else {
            content()
        }
    }
}

// NOTE: a `LiquidGlassButtonStyle` already exists for Mercury action stacks
// (Features/Mercury/Views/LiquidGlassButtonStyle.swift) and `.auroraGlass()`
// (Views/Aurora/LiquidGlassFallback.swift) is the variant-tinted card system.
// This file holds only the small shape-level adapters; button-level glass
// rides on those existing styles (their iOS 26 paths route through
// `liquidGlassEffect`, so they honor the transparency preference too).

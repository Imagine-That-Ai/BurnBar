import AppKit
import SwiftUI

// MARK: - Liquid Glass (macOS 26+) adapters
//
// macOS mirror of `OpenBurnBarMobile/Theme/LiquidGlass.swift` — keep the two
// files in lockstep when the vocabulary grows. The app deploys to macOS 14,
// so every glass API is gated on `#available(macOS 26, *)` with a material
// fallback that approximates the look on older systems.
//
// Vocabulary:
//   • `liquidGlassSurface(in:fallback:)`     — glass plate for passive
//     surfaces: trays, floating bars, cards, sheet inserts.
//   • `liquidGlassInteractive(tint:in:fallback:)` — glass that responds to
//     pointer/touch, for clickable controls: buttons, chips, pills.
//   • `liquidGlassCircleButton(diameter:)`   — the recurring circular
//     toolbar/overlay control (close ✕, collapse ⌄, etc.).
//   • `liquidGlassEffect(_:in:)`             — drop-in for SwiftUI's
//     `glassEffect(_:in:)` at macOS-26-only call sites, so one-off glass
//     accents honor the transparency preference too.
//   • `LiquidGlassGroup(spacing:)`           — `GlassEffectContainer` when
//     available (glass cannot sample other glass, so grouped elements must
//     share one container); passes content through untouched on macOS 14–15.
//   • `LiquidGlassTransparency`              — the user's glass transparency
//     preference (Frosted ⟷ System ⟷ Clear); see below.
//
// Brand rule: glass is the language of the utilitarian shell — popover cards,
// HUD pills, toolbars, overlay chrome. The membership/Pro world keeps its
// obsidian-foil identity (`Views/Components/Pro`); there, glass appears only
// in system chrome (close buttons, sheet material), never on the foil cards
// themselves.

// MARK: - Transparency preference

/// User-adjustable glass transparency, shared across iOS and macOS through
/// the same UserDefaults key (the two `Theme/LiquidGlass.swift` files mirror
/// each other — keep in lockstep).
///
/// Semantics of the stored value `t` (Double, clamped to -1…1):
///   • `t == 0` — system default. Glass renders exactly as the OS does, which
///     already honors System Settings → Accessibility → Reduce transparency.
///   • `t > 0`  — clearer. The plate switches to the `.clear` glass variant
///     (more see-through); on macOS 14–15 the fallback material plate fades
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
    static let contentSurfacesEnabledKey = "liquidGlassContentSurfacesEnabled"
    static let range: ClosedRange<Double> = -1.0 ... 1.0

    // MARK: - Liquidity

    /// How much refraction the material performs, 0…1, authored default at the midpoint.
    ///
    /// The second axis, and the one the transparency slider could never express. Opacity
    /// asks "how much can I see through this?"; liquidity asks "how much does it bend?".
    /// They are independent — dense clear glass and thin frosted glass are both real
    /// materials — and collapsing them into one control is why the existing slider felt
    /// like it did nothing: at the frosted end it only added haze, and at the clear end
    /// it only removed substrate. Neither touched the optics.
    static let liquidityKey = "liquidGlassLiquidity"
    static let liquidityRange: ClosedRange<Double> = 0.0 ... 1.0
    /// Midpoint means "exactly as the theme authored it", so a fresh install and a reset
    /// slider are the same material.
    static let liquidityDefault = 0.5

    /// The multiplier applied to the optical axes.
    ///
    /// `0 → 0×` (a flat pane, still lit at the rim — never a blur), `0.5 → 1×` (authored),
    /// `1 → 2×` (a heavy optical block). Linear on purpose: the axes it scales are
    /// already perceptually shaped by the shader's own curves, so a second curve here
    /// would make the middle of the slider feel dead.
    static func liquidityMultiplier(_ raw: Double, reduceTransparency: Bool) -> Double {
        guard raw.isFinite else { return 1 }
        // Reduce Transparency is a legibility request, not a taste one: it may lower the
        // optics but must never be overridden into raising them.
        let clamped = min(max(raw, liquidityRange.lowerBound), liquidityRange.upperBound)
        let resolved = reduceTransparency ? min(clamped, liquidityDefault) : clamped
        return resolved * 2
    }

    /// The substrate multiplier for the transparency axis.
    ///
    /// Negative (frosted) walks the scrim toward opaque; positive (clear) thins it. The
    /// previous mapping only chose between two `Glass` constants above `t > 0.55`, so
    /// most of the slider's travel changed nothing at all — this one is continuous
    /// across the whole range and applies to the app's real dashboard material.
    static func scrimScale(_ t: Double, base: Double) -> Double {
        guard t.isFinite else { return base }
        let clamped = min(max(t, range.lowerBound), range.upperBound)
        if clamped >= 0 { return base * (1 - 0.85 * clamped) }
        return base + (1 - base) * -clamped
    }

    /// Resolve the raw stored value against the accessibility state.
    static func effective(_ raw: Double, reduceTransparency: Bool) -> Double {
        guard raw.isFinite else { return 0 }
        let t = min(max(raw, range.lowerBound), range.upperBound)
        return (reduceTransparency && t > 0) ? 0 : t
    }

    /// The key the kernel backdrop stores its on/off state under.
    ///
    /// Duplicated as a literal rather than importing `KernelBackdropPreferences`,
    /// which lives in the view layer — this type is a pure preference model and must
    /// not depend on a view. Pinned by `LiquidGlassTransparencyTests`.
    static let mediaRichBackdropKey = "useKernelBackdrop"

    /// Whether a plate may use the `.clear` glass variant.
    ///
    /// WWDC25 s219 permits `.clear` only when **all three** hold: the element sits over
    /// media-rich content, the content layer tolerates a dimming layer, and the content
    /// above it is bold and bright. `.clear` has no adaptive behaviour at all — no
    /// light/dark flip, no shadow adaptation — so using it outside those conditions is
    /// what produces washed, low-contrast chrome.
    ///
    /// The previous mapping was `t > 0.001`: any nudge of the slider selected `.clear`
    /// over an ordinary opaque background, meeting none of the three. Now it requires
    /// the live kernel backdrop to actually be running (condition 1) and a decisive
    /// preference rather than a nudge; the dimming layer (condition 2) is
    /// `clearBridgeScrimOpacity`.
    static func usesClearGlass(_ t: Double, overMediaRichContent: Bool) -> Bool {
        guard overMediaRichContent else { return false }
        return t > 0.55
    }

    /// Reads the media-rich condition from the live preference.
    static func isOverMediaRichContent(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: mediaRichBackdropKey)
    }

    /// Convenience for view code, which always evaluates against the live backdrop.
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

    /// Opacity of the fallback material plate on macOS 14–15.
    static func fallbackPlateOpacity(_ t: Double) -> Double {
        t > 0 ? 1 - 0.78 * t : 1
    }

    /// Whether content-surface glass is enabled. Defaults to true on macOS 26+,
    /// false on earlier systems. When false, `liquidGlassSurface` and
    /// `liquidGlassInteractive` render their fallback material exclusively.
    static var defaultContentSurfacesEnabled: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static func contentSurfacesEnabled() -> Bool {
        let raw = UserDefaults.standard.object(forKey: contentSurfacesEnabledKey) as? Bool
        if let raw { return raw }
        return defaultContentSurfacesEnabled
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
    @AppStorage(LiquidGlassTransparency.contentSurfacesEnabledKey) private var contentSurfacesEnabled: Bool = LiquidGlassTransparency.defaultContentSurfacesEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: reduceTransparency)
        if #available(macOS 26, *), contentSurfacesEnabled {
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
    @AppStorage(LiquidGlassTransparency.contentSurfacesEnabledKey) private var contentSurfacesEnabled: Bool = LiquidGlassTransparency.defaultContentSurfacesEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: reduceTransparency)
        if #available(macOS 26, *), contentSurfacesEnabled {
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
    /// Falls back to the given material on macOS 14–15.
    ///
    /// Pass `tint` to lean the plate toward a theme/brand cast (e.g. the
    /// dashboard sidebar leaning on the active layout's signature colour). Keep
    /// it subtle — the tint refracts the backdrop, it does not paint over it.
    func liquidGlassSurface(
        tint: Color? = nil,
        in shape: some Shape,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        modifier(LiquidGlassSurfaceModifier(tint: tint, shape: shape, fallback: fallback))
    }

    /// Glass for a clickable control. Pass `tint` only to convey meaning
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
    /// overlay buttons (close ✕, collapse chevron, etc.).
    func liquidGlassCircleButton(diameter: CGFloat = 30) -> some View {
        frame(width: diameter, height: diameter)
            .liquidGlassInteractive(in: .circle)
    }
}

// MARK: - Tuned drop-in for direct `glassEffect` call sites

/// Mirror of SwiftUI's `Glass` fluent configuration, so macOS-26-only call
/// sites keep the familiar spelling while routing through the transparency
/// preference: `.liquidGlassEffect(.regular.tint(accent).interactive(), in: .circle)`.
@available(macOS 26.0, *)
struct LiquidGlassStyle {
    var tintColor: Color?
    var isInteractive: Bool
    var clearAtNeutral: Bool

    static var regular: LiquidGlassStyle { .init(tintColor: nil, isInteractive: false, clearAtNeutral: false) }
    static var clear: LiquidGlassStyle { .init(tintColor: nil, isInteractive: false, clearAtNeutral: true) }

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
    ///
    /// `overMediaRichContent` is injectable so no caller — and no test — resolves glass
    /// through a global `UserDefaults` read. A test that routed through the convenience
    /// was green only on a machine with the kernel backdrop switched on.
    func resolvedGlass(
        at t: Double,
        overMediaRichContent: Bool = LiquidGlassTransparency.isOverMediaRichContent()
    ) -> Glass {
        let shouldUseClear = clearAtNeutral
            ? t >= 0
            : LiquidGlassTransparency.usesClearGlass(t, overMediaRichContent: overMediaRichContent)
        var glass: Glass = shouldUseClear ? .clear : .regular
        if let tintColor { glass = glass.tint(tintColor) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}

@available(macOS 26.0, *)
private struct LiquidGlassEffectModifier<S: Shape>: ViewModifier {
    let style: LiquidGlassStyle
    let shape: S

    @AppStorage(LiquidGlassTransparency.storageKey) private var rawTransparency: Double = 0
    @AppStorage(LiquidGlassTransparency.contentSurfacesEnabledKey) private var contentSurfacesEnabled: Bool = LiquidGlassTransparency.defaultContentSurfacesEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: reduceTransparency)
        if contentSurfacesEnabled {
            content
                .background { liquidGlassScrim(for: t, in: shape) }
                .glassEffect(style.resolvedGlass(at: t), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Drop-in replacement for `glassEffect(_:in:)` that honors the user's
    /// Liquid Glass transparency preference. Use this instead of calling
    /// `glassEffect` directly inside `#available(macOS 26, *)` branches.
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

// MARK: - Behind-window blend (macOS clarity payoff)

/// Blurred desktop showing through the window — the macOS payoff for the
/// "Clear" side of the transparency preference. Layer it at the very back of
/// a window's backdrop and fade it in with the effective adjustment; at
/// `t == 0` callers skip it entirely, so the default window stays opaque.
struct LiquidGlassWindowBlend: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        Self.makeVisualEffectView()
    }

    static func makeVisualEffectView() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Grouping container

/// Wraps grouped glass elements in a `GlassEffectContainer` on macOS 26 so
/// they share one sampling region (glass cannot sample other glass); on
/// earlier systems the content renders unchanged. `spacing` should match the
/// actual layout spacing of the grouped elements.
struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26, *) {
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

// NOTE: `GlassCard` / `GlassButton` (Views/Popover/MenuBarPopoverView.swift)
// remain the variant card system for popover/dashboard content — they layer
// the house sheen + edge gradient and adopt real glass on macOS 26 themselves.
// This file holds only the small shape-level adapters; card-level glass rides
// on those existing styles (their macOS 26 paths route through
// `liquidGlassEffect`, so they honor the transparency preference too).

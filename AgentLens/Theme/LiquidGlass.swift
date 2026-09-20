import AppKit
import SwiftUI
import OpenBurnBarUI

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
/// Preference math lives in OpenBurnBarUI.LiquidGlassTransparency.
/// This file keeps the platform view adapters only.

/// Optical dimming behind system glass. Renders nothing at `t == 0`.
///
/// Never a `Material`. Material under `glassEffect` is sampled instead of
/// the live canvas, which collapses Liquid Glass into a blur panel.
@ViewBuilder
private func liquidGlassScrim(for t: Double, in shape: some Shape) -> some View {
    let frost = LiquidGlassTransparency.frostScrimOpacity(t)
    let bridge = LiquidGlassTransparency.clearBridgeScrimOpacity(t)
    if frost > 0 {
        shape.fill(Color.black.opacity(min(LiquidGlassTransparency.maximumUnderGlassScrimOpacity, frost)))
    } else if bridge > 0 {
        shape.fill(Color.black.opacity(bridge))
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
                .glassEffect(glass, in: shape)
                .background { liquidGlassScrim(for: t, in: shape) }
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
                .glassEffect(glass, in: shape)
                .background { liquidGlassScrim(for: t, in: shape) }
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
                .glassEffect(style.resolvedGlass(at: t), in: shape)
                .background { liquidGlassScrim(for: t, in: shape) }
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

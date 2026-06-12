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
//   • `LiquidGlassGroup(spacing:)`           — `GlassEffectContainer` when
//     available (glass cannot sample other glass, so grouped elements must
//     share one container); passes content through untouched on macOS 14–15.
//
// Brand rule: glass is the language of the utilitarian shell — popover cards,
// HUD pills, toolbars, overlay chrome. The membership/Pro world keeps its
// obsidian-foil identity (`Views/Components/Pro`); there, glass appears only
// in system chrome (close buttons, sheet material), never on the foil cards
// themselves.

extension View {
    /// Glass plate for a passive surface (tray, floating bar, card).
    /// Falls back to the given material on macOS 14–15.
    @ViewBuilder
    func liquidGlassSurface(
        in shape: some Shape,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }

    /// Glass for a clickable control. Pass `tint` only to convey meaning
    /// (primary action, destructive), not decoration — toolbar glass is
    /// monochrome by default in the new design.
    @ViewBuilder
    func liquidGlassInteractive(
        tint: Color? = nil,
        in shape: some Shape,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        if #available(macOS 26, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                self.glassEffect(.regular.interactive(), in: shape)
            }
        } else if let tint {
            self.background(tint.opacity(0.22), in: shape)
                .background(fallback, in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }

    /// The recurring circular glass control used in toolbars and as floating
    /// overlay buttons (close ✕, collapse chevron, etc.).
    func liquidGlassCircleButton(diameter: CGFloat = 30) -> some View {
        frame(width: diameter, height: diameter)
            .liquidGlassInteractive(in: .circle)
    }
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
// on those existing styles.

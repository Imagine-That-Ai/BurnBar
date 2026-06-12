import SwiftUI

// MARK: - Liquid Glass (iOS 26+) adapters
//
// The central bridge between OpenBurnBar's surfaces and the iOS 26 Liquid
// Glass design language. The app deploys to iOS 17, so every glass API is
// gated on `#available(iOS 26, *)` with a material fallback that approximates
// the look on older systems.
//
// Vocabulary:
//   • `liquidGlassSurface(in:fallback:)`     — glass plate for passive
//     surfaces: trays, floating bars, cards, sheet inserts.
//   • `liquidGlassInteractive(tint:in:fallback:)` — glass that responds to
//     touch, for tappable controls: buttons, chips, segmented options.
//   • `liquidGlassCircleButton(diameter:)`   — the recurring circular
//     toolbar/overlay control (close ✕, follow ⤓, etc.).
//   • `LiquidGlassGroup(spacing:)`           — `GlassEffectContainer` when
//     available (glass cannot sample other glass, so grouped elements must
//     share one container); passes content through untouched on iOS 17–25.
//
// Brand rule: glass is the language of the utilitarian shell — tab bar,
// trays, sheets, toolbars, chips. The membership/Pro world keeps its
// obsidian-foil identity; there, glass appears only in system chrome
// (close buttons, sheet material), never on the foil cards themselves.

extension View {
    /// Glass plate for a passive surface (tray, floating bar, card).
    /// Falls back to the given material on iOS 17–25.
    @ViewBuilder
    func liquidGlassSurface(
        in shape: some Shape,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }

    /// Glass for a tappable control. Pass `tint` only to convey meaning
    /// (primary action, destructive), not decoration — toolbar glass is
    /// monochrome by default in the new design.
    @ViewBuilder
    func liquidGlassInteractive(
        tint: Color? = nil,
        in shape: some Shape,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        if #available(iOS 26, *) {
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
    /// overlay buttons (close ✕, scroll-to-bottom, etc.).
    func liquidGlassCircleButton(diameter: CGFloat = 30) -> some View {
        frame(width: diameter, height: diameter)
            .liquidGlassInteractive(in: .circle)
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
// rides on those existing styles.

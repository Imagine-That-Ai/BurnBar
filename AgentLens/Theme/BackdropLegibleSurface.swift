import OpenBurnBarUI
import SwiftUI

// MARK: - Backdrop-legible surface
//
// The contract a content surface must satisfy to sit on top of the live WebGL
// kernel backdrop and still be readable.
//
// This exists because the Control Deck shipped without it and was unreadable
// the moment a kernel was switched on. Two *independent* defects put it there,
// and fixing either one alone does not clear the bar:
//
//   1. **No substrate.** A plate of `glassEffect + accent wash` has nothing
//      opaque underneath it. Glass *refracts*; it does not darken. So an
//      animated, fully saturated mesh arrives at the text unattenuated.
//
//   2. **Decorative ink.** `DesignSystem.Colors.textMuted` (`#6E7681`) measures
//      **3.77:1 against the app's own `surface` (`#161B22`)**. It has never
//      cleared 4.5:1 anywhere, on any background this app can draw. It is a
//      hairline/ornament token that was being used for body copy.
//
// So the contract is a pair, and `BackdropLegiblePlateTests` pins both halves:
//
//   * `.backdropLegiblePlate(...)` puts a `surface` slab under the glass when a
//     live backdrop is active, and paints opaque paper under Editorial.
//   * `BackdropInk` resolves every text role from `BackdropAdaptiveColors` when
//     a live backdrop is active — the family the readability sampler already
//     sizes to clear 4.5:1 against whatever the kernel is currently painting.
//
// Why ink and not just a thicker slab: an opacity high enough to rescue
// `textSecondary` over a bright kernel is ~0.78, at which point the plate is a
// solid rectangle and the entire liquid-glass language is gone. At 0.60 with
// adaptive ink every role clears 4.5:1 with room to spare *and* the plate still
// reads as glass. That trade is the whole point of this file.
//
// Adopt this on any surface that renders over the dashboard backdrop.
// `ChartCardView` has the identical unprotected recipe and is the next
// candidate; it is left alone here only to keep this change reviewable.

// MARK: - Substrate

enum BackdropSubstrate {
    /// Opacity of the `DesignSystem.Colors.surface` slab painted *under* the
    /// glass when a live backdrop is on.
    ///
    /// Set from rendered evidence, not from taste, and not from the contrast
    /// maths — contrast alone is satisfied well below this.
    ///
    /// The binding constraint is *coherence*. A thin slab lets ~40% of the
    /// kernel through, and the kernel is a gradient, so two tiles in the same
    /// band pick up visibly different hues depending on what happens to sit
    /// behind them. The band stops reading as a band and the page reads as
    /// dirt. `ControlDeckSnapshotHarness` renders exactly that failure.
    ///
    /// At 0.70 the plate is dominated by the app's own `surface`, so a band is
    /// one colour all the way across the row, while the ~30% still coming
    /// through carries the backdrop's *motion* without carrying its hue. The
    /// glass layer sits above this and supplies the refraction a flat render
    /// cannot show.
    static let live: Double = 0.70

    /// For surfaces that carry the smallest type (10–11pt eyebrows, dense
    /// ladders) and therefore want more headroom than the shared floor.
    static let liveElevated: Double = 0.82

    /// Window chrome — the command deck and its status rail.
    ///
    /// Sized for liquid glass: luminous and translucent so the moving live
    /// backdrop shines and refracts through the glass body while providing
    /// the contrast floor needed for crisp typography.
    static let chrome: Double = 0.38
}

// MARK: - Ink

/// The text roles a backdrop-aware surface draws with.
///
/// Three rungs, all of them *readable*. There is deliberately no fourth
/// "decorative text" rung: if a string is worth rendering it is worth reading,
/// and the token that used to serve that role could not be read.
struct BackdropInk {
    /// Headlines, values, anything the eye lands on first.
    let primary: Color
    /// Supporting copy, labels, status words.
    let secondary: Color
    /// The quietest readable rung — eyebrows, captions, footers.
    let subtle: Color
    /// Glyphs and symbols. Held apart from text because WCAG grades
    /// non-text contrast at 3:1, so this may be quieter than `secondary`.
    let icon: Color
    /// Hairlines, dividers, and well fills. The one genuinely decorative role.
    let hairline: Color

    /// Resolve for the current backdrop.
    ///
    /// When a live backdrop is active this returns the sampled
    /// `BackdropAdaptiveColors` family, which the WebGL readability pass keeps
    /// above 4.5:1 for the canvas it is actually painting. Under Editorial the
    /// same call resolves to the *dark* family over paper, which is correct —
    /// `BackdropReadabilityProfile.nativeFallback` pins Editorial to
    /// `.lightCanvasFallback` for exactly this reason.
    ///
    /// On a static canvas it returns design tokens — but never `textMuted`,
    /// which cannot clear 4.5:1 even there.
    static func resolve(
        liveBackdropActive: Bool,
        profile: BackdropReadabilityProfile
    ) -> BackdropInk {
        guard liveBackdropActive else {
            return BackdropInk(
                primary: DesignSystem.Colors.textPrimary,
                secondary: DesignSystem.Colors.textSecondary,
                // `textSecondary` again, deliberately. `textMuted` is 3.77:1 on
                // `surface` and belongs to hairlines only.
                subtle: DesignSystem.Colors.textSecondary,
                icon: DesignSystem.Colors.textSecondary,
                hairline: DesignSystem.Colors.border
            )
        }
        let adaptive = BackdropAdaptiveColors(profile: profile)
        return BackdropInk(
            primary: adaptive.primary,
            secondary: adaptive.secondary,
            subtle: adaptive.muted,
            icon: adaptive.icon,
            hairline: adaptive.muted.opacity(0.28)
        )
    }

    /// Ink that contrasts with a `surface` slab, not with the kernel behind it.
    ///
    /// Adaptive kernel ink is for text sitting *on the backdrop* (page titles,
    /// chrome that has no plate). Once `BackdropLegiblePlate` paints a dark
    /// `surface` slab, that slab is the background that has to clear 4.5:1.
    /// Using a bright-kernel sample (`tone: .dark`, near-black ink) on that
    /// slab is how the Control Deck shipped as a wall of empty cards: the
    /// header stayed readable on Aurora, and every tile headline vanished.
    static func resolveForPlate(skin: AppSkin, colorScheme: ColorScheme) -> BackdropInk {
        // Appearance tokens (`textSecondary` / `textMuted`) lose 4.5:1 once
        // kernel bleed brightens the slab — that is the empty-deck pair,
        // just with the polarity flipped. Use the adaptive family sized for
        // the *plate* tone (dark slab → light ink, Editorial paper → dark
        // ink), never the kernel sample and never the quiet static tokens.
        let profile = BackdropReadabilityProfile.nativeFallback(
            colorScheme: colorScheme,
            appearanceSkin: skin,
            liveBackdropActive: false
        )
        return resolve(liveBackdropActive: true, profile: profile)
    }
}

private struct BackdropInkKey: EnvironmentKey {
    static let defaultValue = BackdropInk.resolve(
        liveBackdropActive: false,
        profile: .darkCanvasFallback
    )
}

extension EnvironmentValues {
    /// The resolved ink for the backdrop this subtree is drawn over.
    ///
    /// Injected once per page (see `ControlDeckView.body`) rather than resolved
    /// per view, so a whole surface can never end up half-adaptive.
    var backdropInk: BackdropInk {
        get { self[BackdropInkKey.self] }
        set { self[BackdropInkKey.self] = newValue }
    }
}

extension View {
    /// Resolve and publish `\.backdropInk` for everything below this view.
    func resolvingBackdropInk(
        liveBackdropActive: Bool,
        profile: BackdropReadabilityProfile
    ) -> some View {
        environment(
            \.backdropInk,
            BackdropInk.resolve(liveBackdropActive: liveBackdropActive, profile: profile)
        )
    }
}

// MARK: - Plate

/// The card plate for a surface that may be sitting over a live backdrop.
///
/// Three branches, in the order they are checked:
///
///   * **Editorial** — opaque paper plus a hairline, explicitly glass-free.
///     This is the branch `SidebarThemeGlass` takes; a glass plate on paper
///     reads as a smudge.
///   * **Live backdrop** — real glass with a `surface` slab underneath. The
///     slab is what makes the difference; the wash and the glass sit on top of
///     it and keep the material language intact.
///   * **Static canvas** — the original glass + wash recipe, untouched, so
///     nothing changes for users who run with the backdrop off.
struct BackdropLegiblePlate: ViewModifier {
    let accent: Color
    let washOpacity: Double
    let strokeColor: Color
    let strokeWidth: CGFloat
    var cornerRadius: CGFloat = DesignSystem.Radius.lg
    var substrate: Double = BackdropSubstrate.live

    @Environment(\.dashboardLiveBackdropActive) private var liveBackdropActive
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSkin.storageKey) private var rawSkin: String = AppSkin.aurora.rawValue

    /// Read through `@AppStorage` rather than `AppSkin.current` so flipping the
    /// skin actually invalidates the view. `AppSkin.current` is a bare
    /// `UserDefaults` read and is not observable.
    private var skin: AppSkin { AppSkin(rawValue: rawSkin) ?? .aurora }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        plated(content)
            // Plate-local ink: the slab is `surface`, so the text on it must
            // contrast with `surface`, not with whatever the kernel sampler
            // last saw. Page-level adaptive ink stays on the header.
            .environment(\.backdropInk, BackdropInk.resolveForPlate(skin: skin, colorScheme: colorScheme))
            .overlay(shape.stroke(strokeColor, lineWidth: strokeWidth))
            .clipShape(shape)
    }

    /// Apply glass *to the content*, never as a sibling `Color.clear` layer.
    ///
    /// Control Deck wraps every band in `LiquidGlassGroup` (`GlassEffectContainer`).
    /// A background view that carries its own `glassEffect` is an independent
    /// glass shape; the container unifies those shapes into one pass that
    /// composites *above* the tile copy. That is why the deck rendered as empty
    /// plates with only the nested glass buttons still visible — the buttons
    /// apply glass to themselves, so they stay the foreground of their own
    /// shape, while the headline, ladder and footer sit under the unified tile
    /// glass. Same failure the command-deck chrome had; same fix.
    @ViewBuilder
    private func plated(_ content: Content) -> some View {
        if skin == .editorial {
            content.background {
                shape
                    .fill(DesignSystem.Colors.surface)
                    .overlay(shape.fill(accent.opacity(washOpacity)))
            }
        } else if #available(macOS 26, *) {
            content
                .liquidGlassEffect(.regular, in: shape)
                .background { shape.fill(accent.opacity(washOpacity)) }
                .background {
                    shape.fill(
                        DesignSystem.Colors.surface
                            .opacity(liveBackdropActive ? substrate : staticSubstrate)
                    )
                }
        } else {
            content
                .background { shape.fill(.ultraThinMaterial) }
                .background { shape.fill(accent.opacity(washOpacity)) }
                .background {
                    shape.fill(
                        DesignSystem.Colors.surface
                            .opacity(liveBackdropActive ? substrate : staticSubstrate)
                    )
                }
        }
    }

    private var staticSubstrate: Double {
        colorScheme == .dark ? 0.45 : 0.55
    }
}

extension View {
    func backdropLegiblePlate(
        accent: Color,
        washOpacity: Double,
        strokeColor: Color,
        strokeWidth: CGFloat = 0.75,
        cornerRadius: CGFloat = DesignSystem.Radius.lg,
        substrate: Double = BackdropSubstrate.live
    ) -> some View {
        modifier(
            BackdropLegiblePlate(
                accent: accent,
                washOpacity: washOpacity,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                cornerRadius: cornerRadius,
                substrate: substrate
            )
        )
    }
}

// MARK: - Chrome plate

/// The surface for window chrome that floats over the dashboard backdrop.
///
/// A sibling of ``BackdropLegiblePlate`` with three differences, all of which
/// come from chrome being chrome rather than content:
///
///   * **It is generic over its shape.** The deck is a rounded rectangle and the
///     status rail is effectively a capsule, and both track a user-set height,
///     so the shape cannot be baked in as a corner radius.
///   * **It has a specular edge.** Real glass catches light at its top rim. A
///     uniform hairline all the way around reads as a drawn border; a gradient
///     that is brightest at the top and fades by the bottom reads as material.
///     This is the single cheapest thing that makes a bar look like glass
///     instead of a translucent rectangle.
///   * **It honours ``LiquidGlassTransparency``.** The preference existed but
///     never reached the chrome, so dragging the Clear/Frost slider changed the
///     page and left the bars alone. Clear thins the substrate toward the
///     desktop; Frost lays a thick-material scrim over it.
struct BackdropChromePlate<S: Shape>: ViewModifier {
    let shape: S
    var substrate: Double = BackdropSubstrate.chrome
    var strokeOpacity: Double = 0.5
    var shadowRadius: CGFloat = 18
    var shadowY: CGFloat = 6

    @Environment(\.dashboardLiveBackdropActive) private var liveBackdropActive
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppSkin.storageKey) private var rawSkin: String = AppSkin.aurora.rawValue
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0

    private var skin: AppSkin { AppSkin(rawValue: rawSkin) ?? .aurora }

    private var clarity: Double {
        LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency)
    }

    /// The substrate after the Clear/Frost preference has had its say.
    ///
    /// Floored rather than allowed to reach zero: at full Clear the bars should
    /// read as a pane of glass over the desktop, not vanish and leave floating
    /// glyphs with nothing behind them.
    private var effectiveSubstrate: Double {
        guard clarity > 0 else { return substrate }
        return max(0.24, substrate * LiquidGlassTransparency.fallbackPlateOpacity(clarity))
    }

    func body(content: Content) -> some View {
        surfaced(content)
            .overlay { specularEdge }
            .clipShape(shape)
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
    }

    /// Build the surface by applying glass *to the content*, never as a separate
    /// layer inside `.background`.
    ///
    /// This is load-bearing rather than stylistic. A `Color.clear` view carrying
    /// its own `glassEffect` is an independent glass shape, and inside a
    /// `GlassEffectContainer` — which the deck uses so the bars merge — the
    /// container unifies every glass shape into one pass that composites above
    /// the container's plain sibling content. A glass background therefore paints
    /// over the labels and buttons instead of behind them: the bars render as
    /// blank frosted slabs while the controls are still present and hit-testable.
    /// Applying the effect to the content, the way `liquidGlassSurface` does,
    /// keeps the content as the glass's foreground.
    ///
    /// The opaque slab then goes *behind* the glass, which is also what makes the
    /// bars legible: glass refracts what is behind it, so it needs a floor rather
    /// than the raw kernel.
    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        if skin == .editorial {
            content
                .background {
                    shape
                        .fill(DesignSystem.Colors.surface.opacity(0.92))
                }
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                }
        } else if #available(macOS 26, *) {
            content
                .liquidGlassEffect(.regular, in: shape)
                .background { frostVeil }
                .background { substrateSlab }
        } else {
            content
                .background { shape.fill(.ultraThinMaterial) }
                .background { substrateSlab }
        }
    }

    private var substrateSlab: some View {
        shape.fill(
            DesignSystem.Colors.surface
                .opacity(liveBackdropActive ? effectiveSubstrate : staticSubstrate)
        )
    }

    @ViewBuilder
    private var frostVeil: some View {
        if clarity < 0 {
            shape
                .fill(.thickMaterial)
                .opacity(LiquidGlassTransparency.frostScrimOpacity(clarity))
        }
    }

    private var shadowColor: Color {
        // Chrome casts onto the page beneath it with crisp, refined depth.
        if skin == .editorial {
            return Color.black.opacity(0.08)
        }
        return colorScheme == .dark
            ? Color.black.opacity(0.35)
            : Color.black.opacity(0.12)
    }

    /// On a static canvas the page behind the bar is already the app's own
    /// background, so the slab only has to lift the bar off it.
    private var staticSubstrate: Double {
        colorScheme == .dark ? 0.52 : 0.75
    }

    /// Brightest at the top rim, fading gracefully — crisp defined border in Light mode,
    /// luminous specular highlight in Dark mode.
    private var specularEdge: some View {
        let isLight = colorScheme == .light || skin == .editorial
        return shape.stroke(
            LinearGradient(
                colors: isLight ? [
                    DesignSystem.Colors.border.opacity(0.85),
                    DesignSystem.Colors.border.opacity(0.60),
                    DesignSystem.Colors.border.opacity(0.40)
                ] : [
                    Color.white.opacity(0.38),
                    DesignSystem.Colors.border.opacity(strokeOpacity),
                    DesignSystem.Colors.border.opacity(strokeOpacity * 0.4)
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: isLight ? 1.0 : 0.75
        )
    }
}

extension View {
    /// Draw this view as window chrome floating over the dashboard backdrop.
    func backdropChromePlate<S: Shape>(
        in shape: S,
        substrate: Double = BackdropSubstrate.chrome,
        strokeOpacity: Double = 0.5,
        shadowRadius: CGFloat = 18,
        shadowY: CGFloat = 6
    ) -> some View {
        modifier(
            BackdropChromePlate(
                shape: shape,
                substrate: substrate,
                strokeOpacity: strokeOpacity,
                shadowRadius: shadowRadius,
                shadowY: shadowY
            )
        )
    }
}

// MARK: - Page background

extension View {
    /// The page background every dashboard route paints.
    ///
    /// Routes that skip this are the ones that look broken over a live kernel:
    /// with no background at all the scroll view shows the raw backdrop and
    /// every plate has to fight it alone.
    func dashboardPageBackground(liveBackdropActive: Bool) -> some View {
        background(liveBackdropActive ? Color.clear : DesignSystem.Colors.background)
    }
}

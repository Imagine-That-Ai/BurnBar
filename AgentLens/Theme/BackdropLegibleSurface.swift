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
        content
            .background { plate }
            .overlay(shape.stroke(strokeColor, lineWidth: strokeWidth))
            .clipShape(shape)
    }

    @ViewBuilder
    private var plate: some View {
        if skin == .editorial {
            shape
                .fill(DesignSystem.Colors.surface)
                .overlay(shape.fill(accent.opacity(washOpacity)))
        } else if liveBackdropActive {
            ZStack {
                // The load-bearing layer. Everything above it is material.
                shape.fill(DesignSystem.Colors.surface.opacity(substrate))
                glassLayer
                shape.fill(accent.opacity(washOpacity))
            }
        } else {
            staticPlate
        }
    }

    @ViewBuilder
    private var glassLayer: some View {
        if #available(macOS 26, *) {
            Color.clear.liquidGlassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var staticPlate: some View {
        if #available(macOS 26, *) {
            shape
                .fill(accent.opacity(washOpacity))
                .liquidGlassEffect(.regular, in: shape)
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.45 : 0.55))
                shape.fill(accent.opacity(washOpacity))
            }
        }
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

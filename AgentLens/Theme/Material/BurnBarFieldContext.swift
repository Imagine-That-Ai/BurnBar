import OpenBurnBarCore
import SwiftUI

// MARK: - The field, as something a plate can ask about
//
// The whole "lazy glass" problem in one sentence: a glass plate could never see the
// living backdrop, because the backdrop was a `WKWebView` — a sealed rectangle in the
// compositor that cannot be rasterised by `drawingGroup`, refracted by `layerEffect`,
// captured by `ImageRenderer`, or sampled by macOS 26 `glassEffect`. Plates were
// lensing a decorative gradient that merely resembled the page.
//
// `BurnBarKernelField` fixed the first half by making the field an ordinary fill
// shader. This fixes the second: it publishes everything a plate needs to *re-synthesise
// the exact patch of field behind itself* — same uniforms, same clock, same page
// geometry — and then refract that. The plate is not sampling the page (no API can do
// that); it is recomputing it. The result is identical pixels, which is what makes the
// refraction real rather than suggestive.
//
// Nothing here is above the macOS 14 deployment floor.

// MARK: - Namespace

enum BurnBarField {
    /// The coordinate space the page's field is anchored in.
    ///
    /// A plate converts its own frame into this space to learn where it sits on the
    /// field. Attached once, at the same level as the backdrop, so its origin is the
    /// window content origin — including under the transparent titlebar, which is why
    /// the top bar participates rather than floating on its own private weather.
    static let space = "burnbar.field"
}

// MARK: - Context

/// Everything a plate needs to redraw its own patch of the page's field.
///
/// `Equatable` so publishing it into the environment does not invalidate the world on
/// every frame — the clock lives inside `BurnBarFieldInterior`, deliberately scoped to
/// the tiny background subtree, so a plate's *content* never re-evaluates for weather.
struct BurnBarFieldContext: Equatable, Sendable {

    /// The live fleet. Same value the page field and the ember swarm consume.
    var driver: SwarmColorDriver
    /// The opaque page colour the field settles onto.
    var ground: Color
    /// The page's readability scrim, applied *inside* the plate's lensed layer so the
    /// rim has no brightness step against the page.
    var scrim: Color
    var scrimOpacity: Double
    /// The field's size in `BurnBarField.space`. Changes only on window resize.
    var size: CGSize
    var isAnimating: Bool
    var frameRate: Double

    /// How much of the field survives at this depth in the stack, 0…1.
    ///
    /// A chip inside a rail inside the deck is three plates deep, and each plate mixes
    /// what is behind it toward its own ground. Republishing one multiplied float is
    /// what keeps a nested chip's weather the correct tone without any plate having to
    /// sample another — arbitrary depth, one multiply, no extra taps.
    var attenuation: Double
    /// What the field is mixed *toward* as attenuation falls.
    var attenuationGround: Color

    /// False when no field is mounted (static skin, Editorial paper, a WebGL kernel).
    /// Plates fall back to their authored interior, which is the pre-field behaviour.
    var isAvailable: Bool

    static let unavailable = BurnBarFieldContext(
        driver: SwarmColorDriver(),
        ground: DesignSystem.Colors.background,
        scrim: .black,
        scrimOpacity: 0,
        size: .zero,
        isAnimating: false,
        frameRate: 30,
        attenuation: 1,
        attenuationGround: DesignSystem.Colors.background,
        isAvailable: false
    )

    /// The context a plate hands to whatever it contains.
    ///
    /// `scrim` is dropped: the parent already applied it inside its own lensed layer,
    /// and applying it again per nesting level is how a three-deep chip turns into mud
    /// — the exact stacked-translucency failure the deck's hand-tuned opacities were
    /// compensating for.
    func nested(behind scrim: Double, ground: Color) -> BurnBarFieldContext {
        var next = self
        next.attenuation = attenuation * max(0, 1 - scrim)
        next.attenuationGround = ground
        next.scrimOpacity = 0
        return next
    }
}

// MARK: - Environment

private struct BurnBarFieldContextKey: EnvironmentKey {
    static let defaultValue = BurnBarFieldContext.unavailable
}

extension EnvironmentValues {
    var burnBarField: BurnBarFieldContext {
        get { self[BurnBarFieldContextKey.self] }
        set { self[BurnBarFieldContextKey.self] = newValue }
    }
}

extension View {
    /// Publishes the page's field so every plate below can re-synthesise it.
    func burnBarField(_ context: BurnBarFieldContext) -> some View {
        environment(\.burnBarField, context)
            .coordinateSpace(name: BurnBarField.space)
    }
}

// MARK: - Preference

/// Whether the living backdrop is drawn natively.
///
/// A pure preference model with no view-layer dependency — same discipline
/// `LiquidGlassTransparency` keeps, and for the same reason: the material layer must be
/// able to ask this question without importing the views that own the backdrop.
enum BurnBarGlassFieldPreferences {
    static let nativeFieldKey = "useNativeGlassField"
    static let nativeFieldDefault = true

    /// Whether plates may re-synthesise the field.
    ///
    /// All three must hold. A WebGL kernel is a `WKWebView` and cannot be reproduced;
    /// Editorial paper has no field at all; and with no live backdrop selected there is
    /// nothing to refract. In every false case plates fall back to their authored
    /// interior, which is exactly the behaviour that shipped before this existed.
    static func isFieldAvailable(
        liveBackdropSelected: Bool,
        nativeFieldEnabled: Bool,
        isEditorialSkin: Bool
    ) -> Bool {
        liveBackdropSelected && nativeFieldEnabled && !isEditorialSkin
    }
}

// MARK: - The live fleet, published once

/// The driver the field renders from.
///
/// Published by `DashboardView` from the same store the ember swarm reads, so the
/// backdrop, the plates and the desktop wallpaper are all showing one fleet rather than
/// three independently-derived approximations of it.
private struct BurnBarFleetDriverKey: EnvironmentKey {
    static let defaultValue = SwarmColorDriver()
}

extension EnvironmentValues {
    var burnBarFleetDriver: SwarmColorDriver {
        get { self[BurnBarFleetDriverKey.self] }
        set { self[BurnBarFleetDriverKey.self] = newValue }
    }
}

extension View {
    func burnBarFleetDriver(_ driver: SwarmColorDriver) -> some View {
        environment(\.burnBarFleetDriver, driver)
    }
}

// MARK: - The plate's own copy of the field

/// The page's weather, redrawn at this plate's position on the page.
///
/// The registration is the entire trick, and it is one line: the shader computes
/// `uv = (position - bounds.origin) / bounds.size`, so passing a `bounds` whose origin
/// is the **negated** plate origin makes the plate's local `uv` resolve to the page's
/// `uv`. A plate at (600, 340) therefore draws exactly the pixels the page draws at
/// (600, 340) — not something similar, the same.
///
/// Everything here lives inside a `.background { }`, so its per-frame invalidation is
/// scoped to this subtree and never touches the plate's text, charts or rows.
struct BurnBarFieldInterior: View {
    @Environment(\.burnBarField) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The pose the field holds when motion is off — reference-date zero puts every
    /// phase at exactly 0, so a frozen plate shows the *authored* resting pose rather
    /// than whichever frame the clock happened to stop on. Same contract
    /// `BurnBarKernelField` keeps.
    private static let restingDate = Date(timeIntervalSinceReferenceDate: 0)

    private var isAnimating: Bool { context.isAnimating && !reduceMotion }

    var body: some View {
        let uniforms = BurnBarKernelMath.uniforms(
            for: context.driver,
            reduceTransparency: reduceTransparency
        )
        // A plate keeps its own `TimelineView` rather than reading a shared clock box.
        // Writing a clock from a view body is a side effect during update, and hoisting
        // the timeline above the content would re-evaluate the whole dashboard every
        // frame. The cost of not sharing is at most one frame of phase difference —
        // against periods of 191 s, 47 s and 9 s that is under 0.03 radians on the
        // fastest term, which is far below anything the eye (or a lens) can resolve.
        TimelineView(
            .animation(minimumInterval: 1 / max(1, context.frameRate), paused: !isAnimating)
        ) { timeline in
            let date = isAnimating ? timeline.date : Self.restingDate
            Rectangle()
                .fill(context.ground)
                .visualEffect { effect, proxy in
                    effect.colorEffect(
                        Self.shader(
                            uniforms,
                            at: date,
                            ground: context.ground,
                            // Negated origin: plate-local uv → page uv.
                            origin: proxy.frame(in: .named(BurnBarField.space)).origin,
                            size: context.size.width > 0 ? context.size : proxy.size
                        )
                    )
                }
                .overlay {
                    if context.scrimOpacity > 0 {
                        context.scrim.opacity(context.scrimOpacity)
                    }
                }
                .overlay {
                    // Depth attenuation: how much weather survives at this nesting
                    // level. A flat mix, so a chip three plates deep still reads as the
                    // same material rather than as a differently-coloured one.
                    if context.attenuation < 1 {
                        context.attenuationGround.opacity(1 - context.attenuation)
                    }
                }
        }
        // The raster boundary the lens needs. `layerEffect` samples the layer it is
        // attached to, and without an explicit compositing group the field, scrim and
        // attenuation are not guaranteed to be flattened into one before it reads them.
        .compositingGroup()
        .allowsHitTesting(false)
    }

    private static func shader(
        _ uniforms: BurnBarKernelUniforms,
        at date: Date,
        ground: Color,
        origin: CGPoint,
        size: CGSize
    ) -> Shader {
        let phase = BurnBarKernelMath.phases(at: date.timeIntervalSinceReferenceDate)
        var arguments: [Shader.Argument] = [
            .float4(-origin.x, -origin.y, size.width, size.height),
            .float3(phase.x, phase.y, phase.z),
            .float(uniforms.energy),
            .float(uniforms.turbulence),
            .float(uniforms.detail),
            .color(ground)
        ]
        arguments.append(contentsOf: BurnBarKernelField.bandArguments(uniforms))
        return Shader(function: ShaderLibrary.default.burnBarUsageFieldColor, arguments: arguments)
    }
}

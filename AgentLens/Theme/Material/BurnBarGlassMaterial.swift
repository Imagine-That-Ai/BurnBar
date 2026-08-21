import Metal
import OpenBurnBarUI
import SwiftUI

// MARK: - BurnBar glass material
//
// One material. Seven themes are seven *constants* of a value type, not seven
// rendering paths — adding a theme is adding eight numbers, and the renderer never
// branches on which theme it is drawing.
//
// Two decisions govern this file, both from first-party sources.
//
// **1. The shader tier is the reference implementation, not a fallback.**
// `project.yml:4-6` deploys macOS 14 / iOS 17. Every Liquid Glass API is macOS 26 —
// twelve majors above the floor. But `Shader`, `ShaderLibrary` and `layerEffect` land
// at *exactly* macOS 14 / iOS 17 (SwiftUICore.swiftinterface:8197 / 8167 / 8282). So
// the optics are authored in Metal, everyone gets them, and native `glassEffect` is a
// substitution on 26+ rather than the thing the design depends on.
//
// **2. Glass is the navigation layer, not the content layer.** WWDC25 s219: "it is
// best reserved for the navigation layer that floats above the content of your app…
// making it Liquid Glass would make it compete with other elements and muddy the
// hierarchy." Wallet's cards are opaque foil; Health's rings are opaque; Music's glass
// is the now-playing bar, not the artwork. `AgentLens/Theme/LiquidGlass.swift:28-31`
// already states this as BurnBar's own rule — but
// `LiquidGlassTransparency.defaultContentSurfacesEnabled` defaults to `true`, which is
// precisely what pushed glass down into charts and cards and made the surface read as
// fog. `SurfaceRole` below makes that structurally impossible instead of a convention:
// a `.content` surface *cannot* be glass no matter what spec its call site passes.

// MARK: - Spec

/// Which layer of the app a surface belongs to.
///
/// The enforcement hook for the navigation-layer rule. This is deliberately not a
/// style choice: passing `.content` overrides the spec's optics to zero, so a chart,
/// a table or a session row can never turn itself into glass.
enum SurfaceRole: Equatable, Sendable {
    /// Navigation and command surfaces that float above the app. Glass lives here.
    case chrome
    /// Data. Opaque substrate with real elevation — never glass.
    case content
    /// Live readouts (gauges, meters). Thin glass, strong legibility substrate.
    case instrument
}

/// The physical description of a glass surface.
///
/// Themes differ along *physical* axes — how thick, how much it bends light, how
/// strongly it takes ambient colour — rather than along stylistic ones. That is what
/// lets seven visibly different surfaces share one renderer.
struct GlassSpec: Equatable, Sendable {
    /// Edge refraction amplitude, 0…1. How far the rim bends what is behind it.
    var lensing: Double
    /// 0…1. Widens the bevel band and deepens the shadow; what reads as "thick".
    var thickness: Double
    /// 0…1 opacity of the opaque legibility substrate under the optics.
    var scrim: Double
    /// 0…1 rim highlight and sheen amplitude.
    var specular: Double
    /// 0…1 how strongly the ambient lighting environment tints this plate.
    var ambience: Double
    /// Chromatic dispersion, 0…1. The colour fringe along the rim.
    var dispersion: Double
    /// Subsurface bleed, 0…1. Light entering the body and scattering sideways before
    /// it exits — the inner glow that separates a jewel from a pane.
    var scatter: Double

    init(
        lensing: Double,
        thickness: Double,
        scrim: Double,
        specular: Double,
        ambience: Double,
        dispersion: Double,
        scatter: Double = 0.30
    ) {
        self.lensing = max(0, min(1, lensing))
        self.thickness = max(0, min(1, thickness))
        self.scrim = max(0, min(1, scrim))
        self.specular = max(0, min(1, specular))
        self.ambience = max(0, min(1, ambience))
        self.dispersion = max(0, min(1, dispersion))
        self.scatter = max(0, min(1, scatter))
    }
}

extension GlassSpec {
    /// Neutral chrome. The default for anything that has not made a choice.
    static let standard = GlassSpec(
        lensing: 0.42, thickness: 0.45, scrim: 0.20, specular: 0.55, ambience: 0.35, dispersion: 0.28, scatter: 0.3
    )

    // The seven personalities. Same physics, different glass.

    /// **Focus** — deep, calm, cinematic. Thick and slow, minimal fringe, so the one
    /// thing on screen sits on something substantial rather than a pane.
    static let focus = GlassSpec(
        lensing: 0.55, thickness: 0.78, scrim: 0.14, specular: 0.48, ambience: 0.55, dispersion: 0.22, scatter: 0.55
    )

    /// **Bento** — jewel-like modular objects. High dispersion is what makes a small
    /// tile read as a cut gem instead of a rounded rectangle.
    static let bento = GlassSpec(
        lensing: 0.62, thickness: 0.55, scrim: 0.22, specular: 0.80, ambience: 0.40, dispersion: 0.55, scatter: 0.72
    )

    /// **Ledger** — restrained and precise. Almost no optics: legibility dominates
    /// spectacle, because this is the mode you read numbers in.
    static let ledger = GlassSpec(
        lensing: 0.14, thickness: 0.18, scrim: 0.46, specular: 0.26, ambience: 0.14, dispersion: 0.06, scatter: 0.08
    )

    /// **Ask** — responsive glass that forms around generated content. Soft and
    /// reactive; the surface should feel like it is still setting.
    static let ask = GlassSpec(
        lensing: 0.48, thickness: 0.40, scrim: 0.24, specular: 0.62, ambience: 0.48, dispersion: 0.34, scatter: 0.48
    )

    /// **Cockpit** — instrumentation. Thin, hard-edged, high specular so live state
    /// cues stay crisp against a dense panel.
    static let cockpit = GlassSpec(
        lensing: 0.26, thickness: 0.30, scrim: 0.38, specular: 0.74, ambience: 0.30, dispersion: 0.16, scatter: 0.2
    )

    /// **Canvas** — dimensional objects with real depth. The thickest glass, because
    /// here the plates are things in a space rather than panels on a page.
    static let canvas = GlassSpec(
        lensing: 0.70, thickness: 0.85, scrim: 0.12, specular: 0.58, ambience: 0.60, dispersion: 0.42, scatter: 0.8
    )

    /// **Atlas** — atmospheric, floating above a landscape. Very low scrim so the
    /// topography beneath stays visible through it.
    static let atlas = GlassSpec(
        lensing: 0.50, thickness: 0.35, scrim: 0.10, specular: 0.44, ambience: 0.70, dispersion: 0.30, scatter: 0.62
    )

    /// **Stream** — a quiet river. Between Ledger's precision and Ask's softness.
    static let stream = GlassSpec(
        lensing: 0.30, thickness: 0.28, scrim: 0.34, specular: 0.40, ambience: 0.26, dispersion: 0.14, scatter: 0.16
    )

    /// Applies the navigation-layer rule. Content surfaces lose their optics entirely.
    func resolved(for role: SurfaceRole) -> GlassSpec {
        switch role {
        case .chrome:
            return self
        case .content:
            // Not a dimming — a different material. Opaque substrate, no lensing, no
            // thickness. This is the rule that keeps charts and tables readable.
            var spec = self
            // Rim optics survive; the centre stays perfectly flat because the lens is
            // driven by the edge height field. Text is never displaced.
            spec.lensing = lensing * 0.45
            spec.thickness = thickness * 0.55
            spec.dispersion = dispersion * 0.35
            spec.scatter = scatter * 0.30
            // Scale, do not clamp. `min(specular, 0.22)` collapsed all nine specs onto
            // one value, which erased every theme's identity on the one role that every
            // section actually uses. Scaling preserves the ordering under the ceiling.
            spec.specular = specular * 0.55
            // The legibility guarantee, and the one axis content may not trade away:
            // a near-opaque substrate under the optics.
            spec.scrim = 0.82 + scrim * 0.18
            return spec
        case .instrument:
            var spec = self
            // Same reasoning as `.content`: proportional, so ledger still reads thinner
            // than canvas on an instrument rather than both landing on the clamp.
            spec.lensing = lensing * 0.32
            spec.scrim = 0.45 + scrim * 0.35
            return spec
        }
    }
}

// MARK: - Tier

/// Which implementation of the material this process will use.
///
/// Resolved once rather than per call site: mixing tiers within one window would show
/// two different materials side by side, which is worse than either alone.
enum MaterialTier: Equatable, Sendable {
    /// macOS 26+: hand the optics to the system so BurnBar's chrome matches the OS.
    case system
    /// macOS 14+: the Metal lens. The reference implementation.
    case shader
    /// Reduce Transparency, or no Metal device. Opaque, still lit, never a blur.
    case flat

    static var resolved: MaterialTier {
        switch ProcessInfo.processInfo.environment["OPENBURNBAR_FORCE_MATERIAL_TIER"] {
        case "shader": return .shader
        case "system": return .system
        case "flat":   return .flat
        default:       break
        }
        // No Metal device (a VM, a stripped CI box) is the only automatic downgrade.
        if MTLCreateSystemDefaultDevice() == nil { return .flat }

        // The shader is the material, on every OS version — NOT a fallback for old ones.
        //
        // This previously returned `.system` on macOS 26+, which meant the hand-authored
        // lens never executed on a modern Mac: the newest machines got Apple's generic
        // frosted material and the oldest got BurnBar's optics, which is exactly
        // backwards. `glassEffect` is a fine system chrome material, but it is not this
        // product's material — it has no dispersion, no caustics, no subsurface scatter,
        // and no cursor-tracked specular. Use it only where matching system chrome
        // matters more than identity, opted into explicitly.
        return .shader
    }
}

// MARK: - Material

private struct BurnBarGlassModifier<S: InsettableShape>: ViewModifier {
    let spec: GlassSpec
    let role: SurfaceRole
    let shape: S
    let tint: Color?
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.burnBarAmbient) private var ambient
    @Environment(\.burnBarField) private var field

    // Stored `@AppStorage` properties, not static convenience reads.
    //
    // `LiquidGlassTransparency.usesClearGlass(_:)` does an untracked
    // `UserDefaults.standard.bool(forKey:)` inside a modifier body, which is why
    // flipping the backdrop never invalidated any plate. Declared as properties, these
    // drive re-evaluation the way the rest of the app expects.
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawTransparency: Double = 0
    @AppStorage(LiquidGlassTransparency.liquidityKey)
    private var rawLiquidity: Double = LiquidGlassTransparency.liquidityDefault

    /// The authored spec for this role, then the user's two axes on top.
    ///
    /// Deliberately downstream of `GlassSpec.resolved(for:)`. That function is a pure
    /// value function pinned by ordering assertions in `BurnBarMaterialTests` — Ledger
    /// quieter than Canvas, no role collapsing distinct themes onto one value — and
    /// folding a user multiplier into it would make those tests depend on a preference.
    /// The sliders shift the whole ladder; they never reorder its rungs.
    private var effective: GlassSpec {
        let base = spec.resolved(for: role)
        let liquid = LiquidGlassTransparency.liquidityMultiplier(
            rawLiquidity, reduceTransparency: reduceTransparency
        )
        let transparency = LiquidGlassTransparency.effective(
            rawTransparency, reduceTransparency: reduceTransparency
        )
        // Content keeps a legibility floor no slider may cross. Chrome and instruments
        // may go fully clear: nothing is reading text off them.
        let floor = role == .content ? 0.55 : 0.0
        return GlassSpec(
            lensing: base.lensing * liquid,
            thickness: base.thickness * liquid,
            scrim: max(floor, LiquidGlassTransparency.scrimScale(transparency, base: base.scrim)),
            specular: base.specular,
            ambience: base.ambience,
            dispersion: base.dispersion * liquid,
            scatter: base.scatter * liquid
        )
    }

    func body(content: Content) -> some View {
        let spec = effective
        let tier: MaterialTier = reduceTransparency ? .flat : MaterialTier.resolved

        // LAYER ORDER IS THE WHOLE DESIGN, and getting it wrong is what made this read
        // as frost for three rounds.
        //
        // `layerEffect` can only sample the layer it is attached to — it cannot see what
        // is *behind* the view. Applying it to [opaque substrate + text] meant the lens
        // was refracting a flat fill, which returns the flat fill. Every optical term was
        // correct and invisible.
        //
        // So: the plate carries its own luminous interior, the lens is applied to THAT
        // ALONE, and the content composites on top untouched. `.background` rather than a
        // `ZStack` because a background never drives layout — an interior built from
        // `Color` would otherwise expand the plate to fill its parent.
        content
            // Text is resolved against the PLATE, not the page. `backdropLegiblePlate`
            // published this and dropping it put section rows on kernel-sampled page ink.
            .environment(\.backdropInk, BackdropInk.resolveForPlate(skin: AppSkin.current, colorScheme: scheme))
            // Hand whatever this plate contains a field that has already been dimmed by
            // this plate's own substrate. A chip inside a rail inside the deck is three
            // plates deep; without this each level would re-synthesise the field at full
            // strength and the nesting would read as three unrelated materials stacked up
            // rather than as depth.
            .environment(
                \.burnBarField,
                field.nested(
                    behind: spec.scrim,
                    ground: scheme == .dark
                        ? DesignSystem.Colors.surface
                        : DesignSystem.Colors.surfaceElevated
                )
            )
            .background {
                ZStack {
                    interior(spec)
                        .modifier(
                            LensModifier(
                                spec: spec, shape: shape, radius: cornerRadius,
                                tier: tier, tint: tint
                            )
                        )
                    // Legibility rides under the text only. A scrim across the whole
                    // plate flattens the optics beside the text as well as behind it.
                    // Just enough to seat the text; the body carries legibility now.
                    shape.fill(
                        (scheme == .dark ? Color.black : Color.white).opacity(0.10 + 0.16 * spec.scrim)
                    )
                    .blur(radius: 22)
                    .padding(14 + spec.thickness * 18)
                }
                .clipShape(shape)
            }
            .overlay { rim(spec) }
            .clipShape(shape)
            .shadow(
                color: ambientShadow(spec),
                radius: 6 + 18 * spec.thickness,
                y: 2 + 8 * spec.thickness
            )
    }

    /// The plate's interior: what the lens actually bends.
    ///
    /// Deliberately *structured*. A gradient wash refracts to itself and the optics
    /// vanish — the lens needs edges and colour transitions to displace. These bands are
    /// derived from `BurnBarAmbient`, so the light inside the glass is the live provider
    /// mix rather than decoration.
    @ViewBuilder
    private func interior(_ spec: GlassSpec) -> some View {
        let key = tint ?? ambient.key
        let counter = ambient.counter
        ZStack {
            if field.isAvailable {
                // The page's own weather, recomputed at this plate's position.
                //
                // This is the line the whole programme was for. Before it, the lens was
                // handed a near-opaque fill plus three gradients and asked to refract
                // them — every optical term computed correctly against a surface with
                // nothing in it, which is precisely why it read as frost. Now the thing
                // being bent is the field itself, registered to the page, so what comes
                // out the other side of the glass is the backdrop, displaced.
                //
                // No `.opacity(0.82…)` ground under it: the field is already opaque and
                // already the correct page colour, and a substrate on top would put the
                // old flat fill straight back.
                BurnBarFieldInterior()
            } else {
                // No field mounted — a static skin, Editorial paper, or a WebGL kernel
                // the plate cannot re-synthesise. Fall back to the authored interior,
                // which is exactly the pre-field behaviour.
                (scheme == .dark ? DesignSystem.Colors.surface : DesignSystem.Colors.surfaceElevated)
                    .opacity(0.82 + 0.16 * spec.scrim)
            }

            // Two offset lobes: light arriving from two directions rather than a wash.
            //
            // Held well back over a live field, which already carries the provider
            // colour — at full strength they would wash out the very weather the lens is
            // there to bend. They stay because an idle fleet makes the field nearly
            // flat, and a lens with nothing to displace has nothing to show.
            let lobe = field.isAvailable ? 0.34 : 1.0
            RadialGradient(
                colors: [key.opacity((0.55 * spec.ambience + 0.20) * lobe), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 260
            )
            RadialGradient(
                colors: [counter.opacity((0.70 * spec.ambience + 0.22) * lobe), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 240
            )

            // Internal depth, NOT a pattern.
            //
            // This was a set of hard diagonal striations, added so the lens would have
            // edges to bend. That was a debugging aid for the shader and it had no
            // business shipping — it read as barber-pole stripes across every panel.
            // A material's interior should be felt, never counted.
            //
            // What replaces it: a soft vertical falloff, which gives the body a sense of
            // depth (light entering the top, absorbed toward the bottom) without drawing
            // a single line the eye can resolve.
            LinearGradient(
                colors: [
                    .white.opacity((0.05 + 0.04 * spec.specular) * lobe),
                    .clear,
                    .black.opacity((0.10 + 0.08 * spec.thickness) * lobe)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // One raster boundary for the whole interior. `layerEffect` samples the layer it
        // is attached to, and without this the field, the lobes and the depth gradient
        // are not guaranteed to be flattened into one before the lens reads them — the
        // proven idiom from `GlassProofSnapshots.lensedPlate`.
        .compositingGroup()
    }

    /// The rim. Even on the flat tier this survives, because a lit edge — not a blur —
    /// is what makes a surface read as glass, and it is the only edge treatment that
    /// works on a light *and* a dark ground.
    private func rim(_ spec: GlassSpec) -> some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [
                    .white.opacity((scheme == .dark ? 0.60 : 0.92) * spec.specular),
                    .clear,
                    .black.opacity((scheme == .dark ? 0.38 : 0.26) * spec.specular)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 0.75 + spec.thickness * 0.75
        )
    }

    private func ambientShadow(_ spec: GlassSpec) -> Color {
        (tint ?? ambient.key).opacity((scheme == .dark ? 0.34 : 0.20) * (0.35 + spec.ambience))
    }
}

/// The Metal pass, isolated so the tier check is one branch in one place.
///
/// Owns the light. The highlight tracks the pointer and *springs* toward it rather than
/// snapping: a specular that teleports reads as a texture swap, one that has momentum
/// reads as a physical object catching the light.
private struct LensModifier<S: Shape>: ViewModifier {
    let spec: GlassSpec
    let shape: S
    let radius: CGFloat
    let tier: MaterialTier
    let tint: Color?

    @State private var light: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.burnBarAmbient) private var ambient

    /// How far, in points, any tap may reach from the pixel being shaded.
    ///
    /// Mirrors `BurnBarGlass.metal`: `band = mix(14, 52, thickness)`, `travel = height ·
    /// band · 2.1 · lensing` with `height ≤ 1`, scatter reaches `band · 0.85 · scatter`,
    /// and magnification displaces up to `0.14 · lensing` of the half-diagonal. Capped
    /// so a full-window plate does not ask the compositor for an enormous halo — beyond
    /// the cap the shader shortens rays instead, which preserves their direction.
    static func sampleBudget(spec: GlassSpec, size: CGSize) -> CGFloat {
        let band = 14 + 38 * spec.thickness
        let travel = band * 2.1 * spec.lensing
        let scatter = band * 0.85 * spec.scatter
        let magnify = 0.14 * spec.lensing * max(size.width, size.height) / 2
        let reflection = 1.85 * max(size.width, size.height) / 2
        let wanted = max(travel + scatter + magnify, min(reflection, 220))
        return min(max(wanted, 48), 260)
    }

    func body(content: Content) -> some View {
        switch tier {
        case .flat:
            content
        case .system:
            if #available(macOS 26, *) {
                // Hand the optics to the OS so BurnBar's chrome matches system chrome.
                // `Glass` has exactly `.regular` / `.clear` / `.identity` — there is no
                // `.prominent`, despite what several widely-copied guides claim.
                // Carry the spec through rather than reducing it to on/off. `Glass` has
                // exactly .regular/.clear/.identity (no .prominent), so the axes that can
                // still be expressed are the tint and whether the surface is interactive;
                // the rest is the system's to render.
                content.glassEffect(
                    spec.lensing > 0
                        ? .regular.tint((tint ?? ambient.key).opacity(0.10 + 0.14 * spec.ambience))
                        : .identity,
                    in: shape
                )
            } else {
                content
            }
        case .shader:
            content
                .visualEffect { [spec, radius, light, ambient] effect, proxy in
                    let size = proxy.size
                    // Resting light sits off the top-leading corner, matching macOS and
                    // the plasma orbs. The cursor displaces it while the pointer is inside.
                    let resting = CGPoint(x: size.width * 0.22, y: -size.height * 0.35)
                    let point = light ?? resting
                    // The budget the shader must not exceed, derived from the same
                    // numbers the shader uses rather than guessed.
                    //
                    // This was a fixed 96×96, which is short for anything above a chip:
                    // `band` reaches 52pt at full thickness, `travel` is `height · band ·
                    // 2.1 · lensing`, magnification pulls up to 14% of the half-size, and
                    // the internal-reflection tap displaces `1.85 · centred` — on a 400pt
                    // card that alone is ~370pt. `SwiftUI::Layer::sample` CLAMPS rather
                    // than failing, so every overrun became an edge-clamped smear that
                    // read as a cheap blur and never announced itself.
                    let budget = Self.sampleBudget(spec: spec, size: size)
                    return effect.layerEffect(
                        ShaderLibrary.default.burnBarGlassLens(
                            .float2(size.width, size.height),
                            .float(radius),
                            .float(spec.lensing),
                            .float(spec.dispersion),
                            .float(spec.specular),
                            .float(spec.thickness),
                            .float(spec.scatter),
                            .float2(point.x, point.y),
                            .float(ambient.energy),
                            .float(budget)
                        ),
                        maxSampleOffset: CGSize(width: budget, height: budget)
                    )
                }
                .animation(
                    reduceMotion
                        ? .easeOut(duration: MotionTokens.reducedDuration)
                        : .spring(response: 0.34, dampingFraction: 0.72),
                    value: light
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): light = point
                    case .ended: light = nil
                    }
                }
        }
    }
}

// MARK: - Ambient environment

/// The lighting environment: colour derived from what the system is actually doing.
///
/// Provider mix and quota pressure become light that reaches every surface, rather
/// than a legend nobody reads. Fed from `SwarmColorDriver`, which already computes
/// weighted provider bands and pressure.
struct BurnBarAmbient: Equatable, Sendable {
    /// The dominant provider's colour.
    var key: Color
    /// The second voice, used on the opposite corner so plates have two-tone light.
    var counter: Color
    /// 0…1 overall energy — burn rate relative to normal.
    var energy: Double

    static let neutral = BurnBarAmbient(
        key: DesignSystem.Colors.blaze,
        counter: DesignSystem.Colors.whimsy,
        energy: 0.4
    )
}

private struct BurnBarAmbientKey: EnvironmentKey {
    static let defaultValue = BurnBarAmbient.neutral
}

extension EnvironmentValues {
    var burnBarAmbient: BurnBarAmbient {
        get { self[BurnBarAmbientKey.self] }
        set { self[BurnBarAmbientKey.self] = newValue }
    }
}

// MARK: - Entry points

extension View {
    /// A BurnBar surface.
    ///
    /// `role` is not decoration — `.content` strips the optics entirely, which is how
    /// the navigation-layer rule is enforced rather than merely documented.
    func burnBarGlass(
        _ spec: GlassSpec = .standard,
        role: SurfaceRole = .chrome,
        tint: Color? = nil,
        cornerRadius: CGFloat = DesignSystem.Radius.lg
    ) -> some View {
        modifier(
            BurnBarGlassModifier(
                spec: spec,
                role: role,
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                cornerRadius: cornerRadius
            )
        )
    }

    /// A capsule control — the shape most BurnBar chrome actually uses.
    func burnBarGlassControl(
        _ spec: GlassSpec = .standard,
        tint: Color? = nil,
        height: CGFloat = 28
    ) -> some View {
        modifier(
            BurnBarGlassModifier(
                spec: spec,
                role: .chrome,
                shape: Capsule(style: .continuous),
                tint: tint,
                cornerRadius: height / 2
            )
        )
    }

    /// Publishes the ambient lighting environment to everything below.
    func burnBarAmbient(_ ambient: BurnBarAmbient) -> some View {
        environment(\.burnBarAmbient, ambient)
    }
}

// MARK: - Deriving ambient light from live activity

extension BurnBarAmbient {
    /// Builds the lighting environment from what the fleet is actually doing.
    ///
    /// This is the "data illuminates the interface" rule, made concrete: the two
    /// providers you are spending the most on become the two lights in the room, and
    /// burn rate relative to a normal day becomes their energy. It is derived, not
    /// configured — there is no palette to pick.
    ///
    /// Pure and `static` so the mapping can be pinned by a test without a window, the
    /// contract every layout rule in this app already keeps.
    static func from(
        providerSummaries: [ProviderSummary],
        totalCostToday: Double,
        typicalDailyCost: Double = 25
    ) -> BurnBarAmbient {
        let ranked = providerSummaries
            .filter { $0.totalCost > 0 }
            .sorted { $0.totalCost > $1.totalCost }

        guard let dominant = ranked.first else { return .neutral }

        let key = ProviderTheme.theme(for: dominant.provider).primaryColor
        // The second voice, so plates are lit from two directions rather than washed in
        // one hue. With a single provider the counter stays the brand's cool accent so
        // the composition keeps a warm/cool axis instead of going monochrome.
        let counter = ranked.dropFirst().first
            .map { ProviderTheme.theme(for: $0.provider).accentColor }
            ?? DesignSystem.Colors.whimsy

        // Energy saturates rather than clipping: a 10× day should read as "very busy",
        // not as the same maximum a 2× day hits.
        let ratio = typicalDailyCost > 0 ? totalCostToday / typicalDailyCost : 0
        let energy = 1 - exp(-max(0, ratio))

        return BurnBarAmbient(key: key, counter: counter, energy: min(1, energy))
    }
}

// MARK: - Per-theme material

/// The glass personality in force for this part of the tree.
///
/// Published once by whichever shell is mounted, so every `DashboardSection` beneath it
/// inherits that theme's physics without a single call site naming a theme. This is how
/// seven visibly different surfaces stay one material rather than seven stylesheets.
private struct BurnBarGlassSpecKey: EnvironmentKey {
    static let defaultValue = GlassSpec.standard
}

extension EnvironmentValues {
    var burnBarGlassSpec: GlassSpec {
        get { self[BurnBarGlassSpecKey.self] }
        set { self[BurnBarGlassSpecKey.self] = newValue }
    }
}

extension View {
    /// Declares the glass personality for everything below.
    func burnBarGlassSpec(_ spec: GlassSpec) -> some View {
        environment(\.burnBarGlassSpec, spec)
    }
}

extension DashboardLayout {
    /// The material personality this layout is rendered in.
    ///
    /// Lives beside the material rather than inside `DashboardLayout` so the shared
    /// cross-platform enum in `OpenBurnBarUI` stays free of macOS rendering concerns.
    var glassSpec: GlassSpec {
        switch self {
        case .aurora:        return .focus
        case .nebula:        return .bento
        case .classic:       return .ledger
        case .constellation: return .ask
        case .cockpit:       return .cockpit
        case .atelier:       return .canvas
        case .stream:        return .stream
        case .atlas:         return .atlas
        }
    }
}

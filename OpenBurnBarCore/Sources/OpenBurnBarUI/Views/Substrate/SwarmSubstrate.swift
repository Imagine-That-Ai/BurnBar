import SwiftUI
import OpenBurnBarKernel
import CoreGraphics

// MARK: - Swarm Substrate contract
//
// A *substrate* is a full-field painter that draws over the existing particle
// cloud for one frame. It is the native analog of an imaginethat-llc glyph
// `StyleModule.drawBody(rc)`: given the same kind of per-frame context (the
// silhouette points, time, formation progress, theme colors), it paints the
// provider-glyph swarm in a distinct material idiom (Stellar Plasma, Glass
// Ribbon, Caustic Pool, Crepuscular Shafts, …).
//
// Substrates NEVER touch the simulation — positions, velocities, colors and
// morph targets are all computed by `SwarmSimulation` exactly as before. A
// substrate only restyles how the resolved dots are painted.

/// One non-glyph particle handed to a substrate, with its color already resolved
/// through `SwarmSimulation.resolvedRGBA(for:at:…)` (driver / palette / scheme all
/// applied). Ports read numeric channels directly off `rgba` — no string parsing.
public struct SwarmSubstrateDot: Sendable {
    public let x: Double
    public let y: Double
    /// Velocity (canvas space); useful for flow-direction idioms. Sim-space.
    public let vx: Double
    public let vy: Double
    /// The draw radius the plain DOTS path would use: `max(0.4, size*(inShape ?1.2:0.85))`.
    public let radius: Double
    /// The base unscaled size seed (`0.8…2.3`).
    public let baseSize: Double
    /// Color already resolved by the engine (driver/palette/scheme + opacity in `a`).
    public let rgba: RGBA
    /// Live opacity of the particle (`p.opacity`), separate from `rgba.a`.
    public let opacity: Double
    /// True when the field is forming a shape and this dot has a target (`tx != nil`).
    public let inShape: Bool
    public let role: String?
    public let slotIndex: Int?
    /// Stable 0…1 per-particle seed (palette position) — good for per-point phase.
    public let colorIndex: Double
    /// 0…1 bezier travel parameter (router-flow); 0 for most modes.
    public let flowProgress: Double

    /// Convenience SwiftUI color (opacity baked in).
    public var color: Color { rgba.color }

    public init(x: Double, y: Double, vx: Double, vy: Double, radius: Double,
                baseSize: Double, rgba: RGBA, opacity: Double, inShape: Bool,
                role: String?, slotIndex: Int?, colorIndex: Double, flowProgress: Double) {
        self.x = x; self.y = y; self.vx = vx; self.vy = vy
        self.radius = radius; self.baseSize = baseSize
        self.rgba = rgba; self.opacity = opacity; self.inShape = inShape
        self.role = role; self.slotIndex = slotIndex
        self.colorIndex = colorIndex; self.flowProgress = flowProgress
    }
}

/// Theme palette + polarity — the native analog of the source `StageColors`.
/// `accent2`/`ink` are derived from `accent` + scheme so ports that read
/// `stage.accent2` / `stage.ink` map 1:1.
public struct SubstrateStage: Sendable {
    public let accent: RGBA
    public let accent2: RGBA
    public let ink: RGBA
    /// True when the canvas behind is dark (additive bloom reads with `.plusLighter`).
    public let dark: Bool

    public init(accent: RGBA, accent2: RGBA, ink: RGBA, dark: Bool) {
        self.accent = accent; self.accent2 = accent2; self.ink = ink; self.dark = dark
    }
}

/// The per-frame draw context handed to a substrate — the native `rc`. Mirrors
/// the source `GlyphRenderContext`: host-transformed dot positions live in `dots`;
/// `cx/cy/cloudRadius/sizePx` are computed once; `t`/`dt` drive animation; `formed`/
/// `settleProgress` gate assembly; `structure` is built lazily and cached across
/// frames by the simulation.
public struct SwarmSubstrateFrame {
    public let size: CGSize
    public let dark: Bool                 // renderScheme == .dark
    public let reduced: Bool              // accessibilityReduceMotion (threaded in)
    public let batteryThrottled: Bool
    public let uiMode: UIMode
    /// True whenever the field is forming a glyph/shape (mode != .swarm).
    public let isShapeMode: Bool
    /// True once the active shape has settled (`shapeSettledAt != nil`).
    public let formed: Bool
    /// Continuous 0…1 "how formed" — the close-fraction of targeted particles.
    public let settleProgress: Double
    public let t: Double                  // flowTime — the always-advancing clock (seconds)
    public let dt: Double                 // normalized so 1 ≈ 60fps
    public let stage: SubstrateStage      // accent / accent2 / ink / dark
    public let backdrop: RGBA?            // backdrop plate, for blend choices
    public let dots: [SwarmSubstrateDot]  // non-glyph particles, color-resolved

    // Derived cloud anchors (computed once per frame from `dots`).
    public let cx: Double
    public let cy: Double
    public let cloudRadius: Double        // representative cloud radius
    public let sizePx: Double             // suggested base point px (median dot radius)

    /// Lazily-built, cached NN order + kNN neighbor lists for lattice / stroke /
    /// sketch idioms. Rebuilds only when the topology signature changes; styles
    /// that ignore it pay nothing.
    public let structure: SubstrateStructureProvider

    public init(size: CGSize, dark: Bool, reduced: Bool, batteryThrottled: Bool,
                uiMode: UIMode, isShapeMode: Bool, formed: Bool, settleProgress: Double,
                t: Double, dt: Double, stage: SubstrateStage, backdrop: RGBA?,
                dots: [SwarmSubstrateDot], cx: Double, cy: Double, cloudRadius: Double,
                sizePx: Double, structure: SubstrateStructureProvider) {
        self.size = size; self.dark = dark; self.reduced = reduced
        self.batteryThrottled = batteryThrottled; self.uiMode = uiMode
        self.isShapeMode = isShapeMode; self.formed = formed; self.settleProgress = settleProgress
        self.t = t; self.dt = dt; self.stage = stage; self.backdrop = backdrop
        self.dots = dots; self.cx = cx; self.cy = cy; self.cloudRadius = cloudRadius; self.sizePx = sizePx
        self.structure = structure
    }
}

/// A full-field painter that draws over the existing particle cloud for one
/// frame. Implementations are created once and cached by the simulation, so they
/// may hold per-layout caches (sprites, kNN graphs, density fields, particle
/// pools). `@MainActor` because `GraphicsContext` drawing is main-actor; a
/// reference type so caches survive across frames.
@MainActor public protocol SwarmSubstrate: AnyObject {
    /// Zero-arg init so the catalog can build instances from a metatype with no
    /// coordination between the bespoke authors.
    init()

    /// Paint the whole field. Return `true` when fully handled — the engine then
    /// skips its own dot/twinkle loops (glyph particles are handled separately —
    /// see ``suppressesGlyphs``). Return `false` to defer to the engine's default
    /// dot render (this is what `PlainDotsSubstrate` and unfilled stubs do).
    /// `ctx` is a value; take a local `var ctx = ctx` to change blendMode / push
    /// layers per pass.
    func paint(_ frame: SwarmSubstrateFrame, into ctx: GraphicsContext) -> Bool

    /// Whether this substrate also wants the engine to skip the Text-glyph pass.
    /// Default `false` (keep the `$`/`tok`/`429` brand glyphs). Stroke/line
    /// substrates that own the whole silhouette may return `true`.
    var suppressesGlyphs: Bool { get }
}

public extension SwarmSubstrate {
    var suppressesGlyphs: Bool { false }
}

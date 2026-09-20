import CoreGraphics
import Foundation

// MARK: - The aurora kernel's motion
//
// The fluid-aurora WebGL kernel (`packages/gl-engine` `fluidAuroraKernel.ts`) moves
// its ribbons with multi-frequency clocks "so the loop never visually repeats",
// and the usage field wraps absolute time into 0…2π phases because a linearly
// growing `Float` is quantised to visible stutter after a day of uptime. Both
// lessons live here: every track is a pure function of a *wrapped* phase, so the
// motion curves are unit-testable without rendering, `Float` precision never
// degrades no matter how long the sheet stays open, and a shared `PlasmaClock`
// drives the whole kernel in one display-link wake-up.
//
// The tracks are sine and cosine folds of those phases. A triangle fold would
// put each track's *extreme* at phase zero — which makes the Reduce-Motion still
// pose the most swung frame the loop ever holds, and puts a derivative
// discontinuity at the wrap. Sine starts at the centre, is smooth everywhere,
// and wraps seamlessly by construction. The breath fold `(1 - cos(2πφ)) / 2`
// starts at its floor and crests mid-cycle — the shape of an inhale.
//
// Periods are deliberately incommensurate (37s / 8.5s / 23s / 2.9s / 11s) — the
// same trick the plasma constellation's four drifts use so a field never falls
// into a visible grid rhythm. Any two ribbons whose periods divide into each
// other phase-lock; these never do.

/// One frame of the kernel: where every layer sits, as pure values.
struct FluidAuroraFrame: Equatable, Sendable {
    /// Each ribbon's horizontal sway, in points at the authored 96pt kernel.
    var sway: [CGFloat]
    /// Each ribbon's horizontal squash. The ribbons breathe.
    var stretch: [CGFloat]
    /// Each ribbon's vertical lift, in points at the authored 96pt kernel.
    var lift: [CGFloat]
    /// Each ribbon's opacity envelope, `0…1`.
    var alpha: [CGFloat]
    /// The specular core's breath: scale and brightness, `0…1`.
    var coreScale: CGFloat
    var coreBrightness: CGFloat
    /// The outer halo's breath, `0…1`.
    var halo: CGFloat
}

/// Pure sampling math. No SwiftUI, no AppKit, no clock.
enum FluidAuroraMotion {

    /// How many ribbons the kernel carries.
    ///
    /// Three, ordered cool → warm: whimsy-mint up top, mint-lavender through the
    /// middle, lavender-ember along the horizon. A fourth would be a sliver at
    /// 96pt — the same "noise, not information" call `BurnBarKernelMath.bandCount`
    /// makes at four provider ribbons.
    static let ribbonCount = 3

    /// The size the authored sway/lift amplitudes assume. A rendered kernel
    /// scales them by `renderedSize / authoredSize`, the same contract
    /// `PlasmaBlobMotion.translation(_:renderedSize:)` keeps for the orbs — a
    /// 48pt emblem drifts proportionally instead of flying off its plate.
    static let authoredSize: CGFloat = 96

    // MARK: Periods
    //
    // Mutually incommensurate, and each is consumed as a 0…1 phase so a
    // long-lived sheet never exposes `Float` quantisation.

    /// Lead drift, in seconds. Slow weather, not a busy loop.
    static let driftPeriod: Double = 37
    /// The middle ribbon's own period, running counter to the outer two.
    static let counterDriftPeriod: Double = 8.5
    /// The shared breath — one opacity swell per cycle.
    static let breathPeriod: Double = 23
    /// The specular core's pulse. Faster than the ribbons because the core is
    /// the kernel's "alive" tell at a glance.
    static let corePeriod: Double = 2.9
    /// The outer halo's slow bloom.
    static let haloPeriod: Double = 11

    // MARK: Sampling

    /// Wraps absolute time into a `0…1` phase. Negative time (a date before the
    /// reference epoch) wraps to a positive phase rather than a negative one.
    static func phase(at time: TimeInterval, period: Double) -> Double {
        guard period > 0 else { return 0 }
        let wrapped = time.truncatingRemainder(dividingBy: period)
        let positive = wrapped < 0 ? wrapped + period : wrapped
        return positive / period
    }

    /// One full frame of the kernel at `time`.
    static func frame(at time: TimeInterval, renderedSize: CGFloat = 96) -> FluidAuroraFrame {
        let lead = CGFloat(phase(at: time, period: driftPeriod))
        let counter = CGFloat(phase(at: time, period: counterDriftPeriod))
        let breath = auroraBreath(CGFloat(phase(at: time, period: breathPeriod)))
        let core = auroraBreath(CGFloat(phase(at: time, period: corePeriod)))
        let halo = auroraBreath(CGFloat(phase(at: time, period: haloPeriod)))

        let scale = renderedSize / max(authoredSize, 1)
        let swayAmplitude: CGFloat = 4.0 * scale
        let liftAmplitude: CGFloat = 3.0 * scale

        // Each ribbon rides its own phase, displaced by a fixed third of a
        // cycle so the three never move as one blob. Two structural guards keep
        // them from phase-locking: the counter ribbon rides a different,
        // incommensurate period (8.5s against 37s), and the third rides the
        // lead's phase *inverted* (1 − lead). No direction flips are needed —
        // at time zero the fanned displacements alone give each ribbon its own
        // station (sin 0, sin 2π/3, sin 4π/3), which is the silhouette a frozen
        // kernel holds: three distinct layers of weather, not a stack of
        // dead-centre ellipses.
        let displacements: [CGFloat] = [0, 1.0 / 3.0, 2.0 / 3.0]
        let tracks: [CGFloat] = [lead, counter, 1 - lead]

        var sway: [CGFloat] = []
        var stretch: [CGFloat] = []
        var lift: [CGFloat] = []
        var alpha: [CGFloat] = []
        for (index, track) in tracks.enumerated() {
            let angle = 2 * CGFloat.pi * (track + displacements[index])
            let wander = CGFloat(sin(angle))
            sway.append(swayAmplitude * wander)
            stretch.append(1 + 0.05 * wander)
            lift.append(liftAmplitude * wander)
            // The outer ribbons rest slightly quieter than the lead ribbon,
            // and all three swell together on the shared breath.
            let base: CGFloat = [0.85, 0.7, 0.6][index]
            alpha.append(base * (0.85 + 0.15 * breath))
        }

        return FluidAuroraFrame(
            sway: sway,
            stretch: stretch,
            lift: lift,
            alpha: alpha,
            coreScale: 0.9 + 0.1 * core,
            coreBrightness: 0.5 + 0.35 * core,
            halo: 0.4 + 0.3 * halo
        )
    }

    /// The authored still pose — every layer's time-zero keyframe, which is the
    /// silhouette the kernel holds under Reduce Motion rather than a frozen
    /// arbitrary frame. Mirrors `PlasmaTick.still`'s contract: it is exactly
    /// `frame(at: 0)`, by construction.
    static var still: FluidAuroraFrame { frame(at: 0, renderedSize: authoredSize) }
}

// MARK: - Shared easing

/// The breath fold: `(1 - cos(2πφ)) / 2`. Starts at its floor, crests mid-cycle,
/// and is smooth across the wrap — the shape of an inhale, and the reason the
/// still pose rests low rather than at the swing's extreme.
func auroraBreath(_ phase: CGFloat) -> CGFloat {
    var wrapped = phase.truncatingRemainder(dividingBy: 1)
    if wrapped < 0 { wrapped += 1 }
    return (1 - CGFloat(cos(2 * CGFloat.pi * wrapped))) / 2
}

import SwiftUI

// MARK: - Scalar plasma tracks
//
// `PlasmaBlobMotion` carries silhouette + transform. The asset also animates
// things that have no silhouette at all: the aura's brightness, the gateway
// badge orbiting the model orb, the thinking bubbles rising off it, and the
// mascot's eyes. Those live here, transcribed from the same `@keyframes`.
//
// Every track is a pure function of phase, so the curves are unit-testable
// without rendering, and one `TimelineView` can drive many of them at once.

// MARK: Glow breath

/// One frame of `@keyframes plasmaGlowBreath` (4s).
struct PlasmaGlowState: Equatable, Sendable {
    /// Blur radius as a fraction of the orb's size. The asset authors
    /// `blur(10px)` → `blur(15px)` on a 52px orb.
    var blurFraction: CGFloat
    /// CSS `brightness()`. Above 1 the aura is emitting more light than it
    /// receives, which is the whole point of a plasma core.
    var brightness: CGFloat
    var scale: CGFloat
    var opacity: CGFloat

    static let still = PlasmaGlowState(blurFraction: 10.0 / 52, brightness: 1.1, scale: 0.95, opacity: 0.8)

    /// The share of this frame that should paint as additive light.
    ///
    /// SwiftUI has no multiplicative `brightness()` filter — `.brightness(_:)`
    /// is additive and washes a tint toward white. A colour "brighter than
    /// itself" is physically an emissive layer, so the extra stop above 1 is
    /// rendered as a `.plusLighter` pass at this opacity, which brightens on a
    /// dark surface exactly the way the CSS filter does and costs one blend
    /// instead of a colour-matrix pass.
    var emissiveOpacity: CGFloat { max(0, brightness - 1) }
}

enum PlasmaGlowBreath {
    static let duration: Double = 4

    /// `0%,100%: blur(10px) brightness(1.1) scale(.95) opacity(.8)`
    /// `50%:     blur(15px) brightness(1.3) scale(1.15) opacity(.95)`
    static func state(atPhase phase: CGFloat) -> PlasmaGlowState {
        let t = PlasmaBlobMotion.easeInOut(plasmaTriangle(phase))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return PlasmaGlowState(
            blurFraction: mix(10.0 / 52, 15.0 / 52),
            brightness: mix(1.1, 1.3),
            scale: mix(0.95, 1.15),
            opacity: mix(0.8, 0.95)
        )
    }

    static func state(at date: Date, phaseOffset: CGFloat = 0) -> PlasmaGlowState {
        state(atPhase: plasmaPhase(at: date, duration: duration) + phaseOffset)
    }
}

// MARK: Thinking bubbles

/// One rising bubble from `@keyframes riseAndPopBubble1…3`.
struct PlasmaBubbleState: Equatable, Sendable {
    var offset: CGSize
    var scale: CGFloat
    var opacity: CGFloat

    static let hidden = PlasmaBubbleState(offset: .zero, scale: 0.3, opacity: 0)
}

/// The three-particle emitter that only runs while the agent is actually
/// working. It is the asset's answer to a spinner, and it is strictly better:
/// it says "thinking" without stealing a fixed rectangle of chrome.
struct PlasmaThinkingBubble: Sendable {
    struct Stop: Sendable {
        var at: CGFloat
        var offset: CGSize
        var scale: CGFloat
        var opacity: CGFloat
    }

    var stops: [Stop]
    var duration: Double
    /// CSS `animation-delay`, which is what staggers the three particles into a
    /// stream rather than a pulse.
    var delay: Double
    var diameter: CGFloat

    func state(at date: Date) -> PlasmaBubbleState {
        guard duration > 0, !stops.isEmpty else { return .hidden }
        let elapsed = date.timeIntervalSinceReferenceDate - delay
        var raw = elapsed.truncatingRemainder(dividingBy: duration) / duration
        if raw < 0 { raw += 1 }
        let phase = CGFloat(raw)

        var index = 0
        for (offset, stop) in stops.enumerated() where stop.at <= phase {
            index = offset
        }
        guard index + 1 < stops.count else {
            let last = stops[stops.count - 1]
            return PlasmaBubbleState(offset: last.offset, scale: last.scale, opacity: last.opacity)
        }
        let start = stops[index]
        let end = stops[index + 1]
        let span = end.at - start.at
        // These particles are authored `ease-out`: they leap away from the orb
        // and coast as they fade, which is how a bubble leaves water.
        let t = span <= 0 ? 0 : easeOut((phase - start.at) / span)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return PlasmaBubbleState(
            offset: CGSize(
                width: mix(start.offset.width, end.offset.width),
                height: mix(start.offset.height, end.offset.height)
            ),
            scale: mix(start.scale, end.scale),
            opacity: mix(start.opacity, end.opacity)
        )
    }

    private func easeOut(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return 1 - (1 - clamped) * (1 - clamped)
    }

    /// `riseAndPopBubble1` — 6px, 2.4s.
    static let first = PlasmaThinkingBubble(
        stops: [
            Stop(at: 0.00, offset: .zero, scale: 0.3, opacity: 0),
            Stop(at: 0.30, offset: CGSize(width: 3, height: -12), scale: 1.0, opacity: 0.9),
            Stop(at: 0.70, offset: CGSize(width: 6, height: -28), scale: 1.2, opacity: 0.6),
            Stop(at: 1.00, offset: CGSize(width: 9, height: -45), scale: 0.2, opacity: 0)
        ],
        duration: 2.4,
        delay: 0,
        diameter: 6
    )

    /// `riseAndPopBubble2` — 9px, 3.0s, 0.4s behind.
    static let second = PlasmaThinkingBubble(
        stops: [
            Stop(at: 0.00, offset: .zero, scale: 0.3, opacity: 0),
            Stop(at: 0.30, offset: CGSize(width: -2, height: -14), scale: 1.05, opacity: 0.85),
            Stop(at: 0.70, offset: CGSize(width: -5, height: -32), scale: 1.25, opacity: 0.55),
            Stop(at: 1.00, offset: CGSize(width: -8, height: -50), scale: 0.1, opacity: 0)
        ],
        duration: 3.0,
        delay: 0.4,
        diameter: 9
    )

    /// `riseAndPopBubble3` — 5px, 2.6s, 0.9s behind.
    static let third = PlasmaThinkingBubble(
        stops: [
            Stop(at: 0.00, offset: .zero, scale: 0.25, opacity: 0),
            Stop(at: 0.35, offset: CGSize(width: 5, height: -18), scale: 0.95, opacity: 0.95),
            Stop(at: 0.75, offset: CGSize(width: 10, height: -38), scale: 1.15, opacity: 0.5),
            Stop(at: 1.00, offset: CGSize(width: 14, height: -58), scale: 0, opacity: 0)
        ],
        duration: 2.6,
        delay: 0.9,
        diameter: 5
    )

    static let all: [PlasmaThinkingBubble] = [.first, .second, .third]
}

// MARK: Mascot eyes

/// `@keyframes eyeGlance` (5s) and `@keyframes eyeBlink`.
///
/// The glance is what makes the mascot read as alive rather than as a logo: the
/// eyes track slowly around the orb as if watching the room. The blink is a
/// 3%-of-cycle squash — long enough to register, short enough that you are
/// never waiting for the eyes to reopen.
enum PlasmaEyeMotion {
    static let glanceDuration: Double = 5

    /// The asset never declares a blink duration (the keyframes ship in the
    /// stylesheet but the runtime never binds them). 5.9s is deliberately
    /// coprime-ish with the 5s glance so the two never phase-lock into a tic.
    static let blinkDuration: Double = 5.9

    /// `0%,100%: (0,0) · 25%: (-2,-1) · 50%: (0,1) · 75%: (2,-1)`
    static func glance(atPhase phase: CGFloat) -> CGSize {
        let stops: [(CGFloat, CGSize)] = [
            (0.00, .zero),
            (0.25, CGSize(width: -2, height: -1)),
            (0.50, CGSize(width: 0, height: 1)),
            (0.75, CGSize(width: 2, height: -1)),
            (1.00, .zero)
        ]
        var wrapped = phase.truncatingRemainder(dividingBy: 1)
        if wrapped < 0 { wrapped += 1 }
        var index = 0
        for (offset, stop) in stops.enumerated() where stop.0 <= wrapped {
            index = offset
        }
        guard index + 1 < stops.count else { return stops[index].1 }
        let (startAt, startValue) = stops[index]
        let (endAt, endValue) = stops[index + 1]
        let span = endAt - startAt
        let t = span <= 0 ? 0 : PlasmaBlobMotion.easeInOut((wrapped - startAt) / span)
        return CGSize(
            width: startValue.width + (endValue.width - startValue.width) * t,
            height: startValue.height + (endValue.height - startValue.height) * t
        )
    }

    /// `0%,88%,94%,100%: scaleY(1) · 91%: scaleY(0.12)`
    static func blinkScaleY(atPhase phase: CGFloat) -> CGFloat {
        var wrapped = phase.truncatingRemainder(dividingBy: 1)
        if wrapped < 0 { wrapped += 1 }
        guard wrapped > 0.88, wrapped < 0.94 else { return 1 }
        // Linear on the way down and back up; an eased lid reads as sleepy.
        let local = (wrapped - 0.88) / 0.06
        let closing = local < 0.5 ? local * 2 : (1 - local) * 2
        return 1 - closing * (1 - 0.12)
    }

    static func glance(at date: Date, phaseOffset: CGFloat = 0) -> CGSize {
        glance(atPhase: plasmaPhase(at: date, duration: glanceDuration) + phaseOffset)
    }

    static func blinkScaleY(at date: Date, phaseOffset: CGFloat = 0) -> CGFloat {
        blinkScaleY(atPhase: plasmaPhase(at: date, duration: blinkDuration) + phaseOffset)
    }
}

// MARK: Shared helpers

/// Normalized position within a loop of `duration` seconds.
/// The orb aura's breath period.
///
/// Slower than the core's 4s `plasmaGlowBreath`: the aura is a wide soft halo,
/// and matching the core's tempo made the whole orb pump rather than breathe.
let plasmaAuraBreathPeriod: Double = 11

func plasmaPhase(at date: Date, duration: Double) -> CGFloat {
    guard duration > 0 else { return 0 }
    return CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration)
}

/// Folds `0…1` into `0…1…0`, which is how CSS reads a `0%,100% / 50%` pair.
///
/// Shared rather than private: `PlasmaBlobMotion`'s `autoreverses` branch and
/// the orb's aura breath both need exactly this, and three spellings of one
/// function is three chances for them to drift apart.
func plasmaTriangle(_ phase: CGFloat) -> CGFloat {
    var wrapped = phase.truncatingRemainder(dividingBy: 1)
    if wrapped < 0 { wrapped += 1 }
    return wrapped < 0.5 ? wrapped * 2 : (1 - wrapped) * 2
}

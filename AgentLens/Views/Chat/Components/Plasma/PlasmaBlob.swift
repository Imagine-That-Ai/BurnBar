import SwiftUI

// MARK: - Plasma blob geometry
//
// A native port of the "Liquid Plasma Floating Selectors" brand asset
// (`Brand & Assets/PLasma Model Selector/plasma-selectors.css`). The asset's
// orbs and bubble are CSS `border-radius: a% b% c% d% / e% f% g% h%` keyframes:
// four corners, each an *elliptical* quarter arc with an independent horizontal
// and vertical radius. SwiftUI has no such shape, so the corner maths is
// reproduced here rather than approximated with a capsule.
//
// The keyframe tables below are transcribed from the asset verbatim — the same
// percentages, translations, rotations and non-uniform scales — so the Mac
// control breathes on exactly the same curve as the reference demo.

/// One CSS elliptical corner-radius set, as fractions of the shape's width (x)
/// and height (y). Clockwise from the top-leading corner.
struct PlasmaBlobRadii: Equatable, Sendable {
    var topLeadingX: CGFloat
    var topTrailingX: CGFloat
    var bottomTrailingX: CGFloat
    var bottomLeadingX: CGFloat
    var topLeadingY: CGFloat
    var topTrailingY: CGFloat
    var bottomTrailingY: CGFloat
    var bottomLeadingY: CGFloat

    /// `border-radius: 50%` — a plain ellipse.
    static let ellipse = PlasmaBlobRadii(
        topLeadingX: 0.5, topTrailingX: 0.5, bottomTrailingX: 0.5, bottomLeadingX: 0.5,
        topLeadingY: 0.5, topTrailingY: 0.5, bottomTrailingY: 0.5, bottomLeadingY: 0.5
    )

    /// Transcribes the CSS shorthand `border-radius: x1% x2% x3% x4% / y1% y2% y3% y4%`.
    static func css(
        _ x1: CGFloat, _ x2: CGFloat, _ x3: CGFloat, _ x4: CGFloat,
        _ y1: CGFloat, _ y2: CGFloat, _ y3: CGFloat, _ y4: CGFloat
    ) -> PlasmaBlobRadii {
        PlasmaBlobRadii(
            topLeadingX: x1 / 100, topTrailingX: x2 / 100,
            bottomTrailingX: x3 / 100, bottomLeadingX: x4 / 100,
            topLeadingY: y1 / 100, topTrailingY: y2 / 100,
            bottomTrailingY: y3 / 100, bottomLeadingY: y4 / 100
        )
    }

    static func lerp(_ from: PlasmaBlobRadii, _ to: PlasmaBlobRadii, _ t: CGFloat) -> PlasmaBlobRadii {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return PlasmaBlobRadii(
            topLeadingX: mix(from.topLeadingX, to.topLeadingX),
            topTrailingX: mix(from.topTrailingX, to.topTrailingX),
            bottomTrailingX: mix(from.bottomTrailingX, to.bottomTrailingX),
            bottomLeadingX: mix(from.bottomLeadingX, to.bottomLeadingX),
            topLeadingY: mix(from.topLeadingY, to.topLeadingY),
            topTrailingY: mix(from.topTrailingY, to.topTrailingY),
            bottomTrailingY: mix(from.bottomTrailingY, to.bottomTrailingY),
            bottomLeadingY: mix(from.bottomLeadingY, to.bottomLeadingY)
        )
    }
}

/// The resolved transform + silhouette for a single frame of a plasma track.
struct PlasmaBlobState: Equatable, Sendable {
    var radii: PlasmaBlobRadii
    var translation: CGSize
    var rotationDegrees: Double
    var scaleWidth: CGFloat
    var scaleHeight: CGFloat

    static let still = PlasmaBlobState(
        radii: .ellipse,
        translation: .zero,
        rotationDegrees: 0,
        scaleWidth: 1,
        scaleHeight: 1
    )
}

/// A single `@keyframes` stop.
struct PlasmaBlobKeyframe: Equatable, Sendable {
    /// Normalized position in the loop, `0...1`.
    var stop: CGFloat
    var state: PlasmaBlobState

    init(
        _ stop: CGFloat,
        _ radii: PlasmaBlobRadii,
        translate: CGSize = .zero,
        rotate: Double = 0,
        scale: CGSize = CGSize(width: 1, height: 1)
    ) {
        self.stop = stop
        self.state = PlasmaBlobState(
            radii: radii,
            translation: translate,
            rotationDegrees: rotate,
            scaleWidth: scale.width,
            scaleHeight: scale.height
        )
    }
}

/// A looping plasma animation track. `state(atPhase:)` is pure, so the motion
/// curve is unit-testable without rendering a view.
struct PlasmaBlobMotion: Equatable, Sendable {
    var keyframes: [PlasmaBlobKeyframe]
    /// Loop length in seconds, matching the asset's `animation-duration`.
    var duration: Double
    /// The orb tracks are authored against a 52pt orb, so their offsets are
    /// scaled by `renderedSize / authoredSize` — a 14pt inline orb drifts
    /// proportionally instead of flying off its own plate. `nil` means the
    /// offsets are absolute points (the bubble billows the same at any width).
    var authoredSize: CGFloat?
    /// CSS `animation-direction: alternate`. The track plays forwards then
    /// backwards, so one full cycle is `2 * duration`. The constellation drifts
    /// rely on this: it is what keeps a field of orbs from all snapping back to
    /// their start pose on the same frame.
    var autoreverses: Bool = false

    /// Wall-clock length of one complete there-and-back cycle.
    var cycleDuration: Double { autoreverses ? duration * 2 : duration }

    /// Offsets for a track rendered at `size`.
    func translation(_ state: PlasmaBlobState, renderedSize: CGFloat) -> CGSize {
        guard let authoredSize, authoredSize > 0 else { return state.translation }
        let factor = renderedSize / authoredSize
        return CGSize(width: state.translation.width * factor, height: state.translation.height * factor)
    }

    /// Samples the track. `phase` wraps, so callers can hand it raw elapsed
    /// time without bookkeeping.
    func state(atPhase phase: CGFloat) -> PlasmaBlobState {
        guard let first = keyframes.first else { return .still }
        guard keyframes.count > 1 else { return first.state }

        var wrapped = phase.truncatingRemainder(dividingBy: 1)
        if wrapped < 0 { wrapped += 1 }
        // `alternate` folds the cycle into a triangle: the second half replays
        // the table in reverse rather than cutting back to the first stop.
        if autoreverses {
            wrapped = plasmaTriangle(wrapped)
        }

        // `keyframes` is authored in ascending `stop` order and always spans
        // 0...1, so the last frame below `wrapped` is the segment's start.
        var index = 0
        for (offset, frame) in keyframes.enumerated() where frame.stop <= wrapped {
            index = offset
        }
        guard index + 1 < keyframes.count else { return keyframes[index].state }

        let start = keyframes[index]
        let end = keyframes[index + 1]
        let span = end.stop - start.stop
        let t = span <= 0 ? 0 : (wrapped - start.stop) / span
        // CSS keyframe interpolation is `ease-in-out` between stops.
        let eased = PlasmaBlobMotion.easeInOut(t)

        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        return PlasmaBlobState(
            radii: PlasmaBlobRadii.lerp(start.state.radii, end.state.radii, eased),
            translation: CGSize(
                width: mix(start.state.translation.width, end.state.translation.width),
                height: mix(start.state.translation.height, end.state.translation.height)
            ),
            rotationDegrees: Double(mix(
                CGFloat(start.state.rotationDegrees),
                CGFloat(end.state.rotationDegrees)
            )),
            scaleWidth: mix(start.state.scaleWidth, end.state.scaleWidth),
            scaleHeight: mix(start.state.scaleHeight, end.state.scaleHeight)
        )
    }

    /// Samples the track from an absolute timestamp. `phaseOffset` (in turns)
    /// displaces this sampler along the loop, so a field of orbs driven by one
    /// clock still moves independently instead of pulsing in unison.
    func state(at date: Date, phaseOffset: CGFloat = 0) -> PlasmaBlobState {
        // A zero duration would divide into NaN and carry it straight into
        // `Path` control points, which is a crash rather than a still orb.
        let cycle = cycleDuration
        guard cycle > 0 else { return .still }
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        return state(atPhase: CGFloat(elapsed / cycle) + phaseOffset)
    }

    static func easeInOut(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

// MARK: - Transcribed tracks
//
// Every table below is the asset's `@keyframes` block, stop for stop.
//
// Durations come from the shipped runtime (`plasma-selectors.js`), which the
// export calls the identical Grok Bot D engine. The standalone
// `plasma-selectors.css` in the same bundle carries byte-identical keyframe
// *geometry* at slightly different tempos (7.5s / 8.5s / 12s / 3.5s against the
// runtime's 7s / 8s / 11s / 4s). Where the two disagree the runtime wins,
// because the runtime is what the reference demo actually renders.

extension PlasmaBlobMotion {
    /// `@keyframes dynamicPlasmaMotion1` — 7s. The mascot orb.
    static let orbPrimary = PlasmaBlobMotion(
        keyframes: [
            PlasmaBlobKeyframe(0.0, .css(52, 48, 44, 56, 48, 58, 42, 52)),
            PlasmaBlobKeyframe(0.5, .css(44, 56, 58, 42, 56, 44, 54, 46),
                               translate: CGSize(width: 3, height: -3),
                               scale: CGSize(width: 1.05, height: 1.05)),
            PlasmaBlobKeyframe(1.0, .css(52, 48, 44, 56, 48, 58, 42, 52))
        ],
        duration: 7,
        authoredSize: 52
    )

    /// `@keyframes dynamicPlasmaMotion2` — 8s. The model orb, drifting against
    /// its sibling so the pair never pulses in lockstep.
    static let orbSecondary = PlasmaBlobMotion(
        keyframes: [
            PlasmaBlobKeyframe(0.0, .css(46, 54, 58, 42, 54, 44, 56, 46)),
            PlasmaBlobKeyframe(0.5, .css(56, 44, 42, 58, 46, 56, 44, 54),
                               translate: CGSize(width: -3, height: 3),
                               scale: CGSize(width: 1.05, height: 1.05)),
            PlasmaBlobKeyframe(1.0, .css(46, 54, 58, 42, 54, 44, 56, 46))
        ],
        duration: 8,
        authoredSize: 52
    )

    /// `@keyframes ghostlyBubbleMorph` — 11s. The billowing container.
    static let bubble = PlasmaBlobMotion(
        keyframes: [
            PlasmaBlobKeyframe(0.00, .css(42, 58, 62, 38, 45, 42, 58, 55)),
            PlasmaBlobKeyframe(0.20, .css(56, 44, 48, 52, 58, 52, 48, 42),
                               translate: CGSize(width: 2, height: -3), rotate: 1.5,
                               scale: CGSize(width: 1.02, height: 0.98)),
            PlasmaBlobKeyframe(0.40, .css(46, 54, 38, 62, 42, 64, 36, 58),
                               translate: CGSize(width: -3, height: 1), rotate: -1.2,
                               scale: CGSize(width: 0.98, height: 1.03)),
            PlasmaBlobKeyframe(0.65, .css(64, 36, 54, 46, 52, 38, 62, 48),
                               translate: CGSize(width: 3, height: 2), rotate: 1.8,
                               scale: CGSize(width: 1.03, height: 0.97)),
            PlasmaBlobKeyframe(0.85, .css(48, 52, 68, 32, 38, 54, 46, 62),
                               translate: CGSize(width: -2, height: -2), rotate: -0.8,
                               scale: CGSize(width: 0.99, height: 1.01)),
            PlasmaBlobKeyframe(1.00, .css(42, 58, 62, 38, 45, 42, 58, 55))
        ],
        duration: 11,
        authoredSize: nil
    )

    /// `@keyframes liquidDriftA…D` — the constellation's zero-gravity field.
    ///
    /// The asset assigns these by `nth-child(4n+1…4n)`, so four different
    /// periods (8.8s–11.4s) beat against each other and the field never falls
    /// into a visible grid rhythm. All four `alternate`, which is why the drift
    /// eases back through its own path instead of snapping home.
    ///
    /// These tracks carry no silhouette of their own — the orb they move is a
    /// true circle — so every stop holds `border-radius: 50%`.
    static let constellationDriftA = drift(
        duration: 9.2,
        mid: CGSize(width: 2.8, height: -3.8), midRotation: 0.4,
        late: CGSize(width: -3.2, height: 2.2), lateRotation: -0.3
    )

    static let constellationDriftB = drift(
        duration: 10.6,
        mid: CGSize(width: -3.6, height: -2.4), midRotation: -0.5,
        late: CGSize(width: 2.2, height: 3.6), lateRotation: 0.3
    )

    static let constellationDriftC = drift(
        duration: 11.4,
        mid: CGSize(width: 3.2, height: 3.2), midRotation: 0.4,
        late: CGSize(width: -2.8, height: -3.6), lateRotation: -0.4
    )

    static let constellationDriftD = drift(
        duration: 8.8,
        mid: CGSize(width: -2.4, height: 3.6), midRotation: -0.3,
        late: CGSize(width: 3.6, height: -2.4), lateRotation: 0.5
    )

    /// The four drifts share one shape — stops at 0 / 33% / 66% / 100% — so they
    /// are built from one description rather than copied four times.
    private static func drift(
        duration: Double,
        mid: CGSize, midRotation: Double,
        late: CGSize, lateRotation: Double
    ) -> PlasmaBlobMotion {
        PlasmaBlobMotion(
            keyframes: [
                PlasmaBlobKeyframe(0.00, .ellipse),
                PlasmaBlobKeyframe(0.33, .ellipse, translate: mid, rotate: midRotation),
                PlasmaBlobKeyframe(0.66, .ellipse, translate: late, rotate: lateRotation),
                PlasmaBlobKeyframe(1.00, .ellipse)
            ],
            duration: duration,
            authoredSize: 52,
            autoreverses: true
        )
    }

    /// The drift assigned to the orb at `index`, reproducing the asset's
    /// `nth-child(4n+1) … nth-child(4n)` rotation.
    static func constellationDrift(forIndex index: Int) -> PlasmaBlobMotion {
        switch index % 4 {
        case 0: return .constellationDriftA
        case 1: return .constellationDriftB
        case 2: return .constellationDriftC
        default: return .constellationDriftD
        }
    }
}

// MARK: - Shape

/// A rectangle whose four corners are independent quarter-*ellipses* — the
/// SwiftUI equivalent of CSS's two-axis `border-radius`.
struct PlasmaBlobShape: Shape {
    var radii: PlasmaBlobRadii
    /// Ceiling, in points, for every corner radius.
    ///
    /// The asset's bubble is a literal oval (`border-radius: ~50%`) with
    /// `overflow: hidden`, which is gorgeous around five short pills and
    /// merciless around a real model catalog — `claude-sonnet-4-6 · Anthropic`
    /// would be sliced by the curve. Capping keeps the *asymmetric breathing*
    /// (corners still shift against each other, frame by frame) at a radius
    /// that never eats a row. `nil` renders the untamed blob, which is what the
    /// orbs want.
    var cornerCap: CGFloat?
    var insetAmount: CGFloat = 0

    /// Ratio at which a cubic Bézier reproduces a quarter-ellipse to ~0.02%.
    private static let kappa: CGFloat = 0.5522847498307936

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: insetAmount, dy: insetAmount)
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0 else { return Path() }

        // CSS scales every radius down proportionally when a pair overflows its
        // edge. The transcribed tracks always sum to 100%, but a caller-supplied
        // set must not be allowed to tear the path.
        let shrink = min(
            1,
            min(
                overflowScale(radii.topLeadingX + radii.topTrailingX),
                overflowScale(radii.bottomLeadingX + radii.bottomTrailingX),
                min(
                    overflowScale(radii.topLeadingY + radii.bottomLeadingY),
                    overflowScale(radii.topTrailingY + radii.bottomTrailingY)
                )
            )
        )

        let tlx = resolve(radii.topLeadingX, span: w, shrink: shrink)
        let trx = resolve(radii.topTrailingX, span: w, shrink: shrink)
        let brx = resolve(radii.bottomTrailingX, span: w, shrink: shrink)
        let blx = resolve(radii.bottomLeadingX, span: w, shrink: shrink)
        let tly = resolve(radii.topLeadingY, span: h, shrink: shrink)
        let trry = resolve(radii.topTrailingY, span: h, shrink: shrink)
        let bry = resolve(radii.bottomTrailingY, span: h, shrink: shrink)
        let bly = resolve(radii.bottomLeadingY, span: h, shrink: shrink)

        let k = Self.kappa
        var path = Path()
        let x = rect.minX
        let y = rect.minY

        path.move(to: CGPoint(x: x + tlx, y: y))
        path.addLine(to: CGPoint(x: x + w - trx, y: y))
        path.addCurve(
            to: CGPoint(x: x + w, y: y + trry),
            control1: CGPoint(x: x + w - trx + k * trx, y: y),
            control2: CGPoint(x: x + w, y: y + trry - k * trry)
        )
        path.addLine(to: CGPoint(x: x + w, y: y + h - bry))
        path.addCurve(
            to: CGPoint(x: x + w - brx, y: y + h),
            control1: CGPoint(x: x + w, y: y + h - bry + k * bry),
            control2: CGPoint(x: x + w - brx + k * brx, y: y + h)
        )
        path.addLine(to: CGPoint(x: x + blx, y: y + h))
        path.addCurve(
            to: CGPoint(x: x, y: y + h - bly),
            control1: CGPoint(x: x + blx - k * blx, y: y + h),
            control2: CGPoint(x: x, y: y + h - bly + k * bly)
        )
        path.addLine(to: CGPoint(x: x, y: y + tly))
        path.addCurve(
            to: CGPoint(x: x + tlx, y: y),
            control1: CGPoint(x: x, y: y + tly - k * tly),
            control2: CGPoint(x: x + tlx - k * tlx, y: y)
        )
        path.closeSubpath()
        return path
    }

    private func overflowScale(_ sum: CGFloat) -> CGFloat {
        sum <= 1 ? 1 : 1 / sum
    }

    /// Uncapped: the CSS percentage of the edge. Capped: the percentage's
    /// distance from the neutral 50% is amplified 6× and then clamped into
    /// `0.55...1.0 × cap`, so a track that only swings 44%–56% still produces a
    /// visibly uneven, living silhouette at a readable radius.
    private func resolve(_ fraction: CGFloat, span: CGFloat, shrink: CGFloat) -> CGFloat {
        guard let cornerCap else { return fraction * span * shrink }
        let amplified = 1 + (fraction - 0.5) * 6
        return min(max(amplified, 0.55), 1) * min(cornerCap, span / 2)
    }
}

extension PlasmaBlobShape: InsettableShape {
    func inset(by amount: CGFloat) -> PlasmaBlobShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

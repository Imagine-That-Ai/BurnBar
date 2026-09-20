import SwiftUI
import XCTest
@testable import OpenBurnBar

/// The fluid aurora kernel: the palette contract, the motion curves, and the
/// Reduce-Motion still pose. Pure math — every assertion runs without rendering
/// a view, the same seam `BurnBarKernelMath` and the plasma tracks are pinned at.
final class FluidAuroraKernelTests: XCTestCase {

    // MARK: - Palette

    func testPaletteShipsTheFullRampInOrder() {
        // whimsy → mint → lavender → ember. The order is the story: cool house
        // accent first, the mint-lavender ask in the middle, brand ember last as
        // the horizon the cool colours drain into.
        let palette = FluidAuroraKernelPalette.palette(colorScheme: .dark)
        XCTAssertEqual(palette.stops.map(\.id), ["whimsy", "mint", "lavender", "ember"])
        XCTAssertEqual(palette.stops.map(\.position), [0, 0.38, 0.72, 1])
    }

    func testPalettePositionsAreMonotonic() {
        for scheme in [ColorScheme.dark, .light] {
            let positions = FluidAuroraKernelPalette.palette(colorScheme: scheme).stops.map(\.position)
            XCTAssertEqual(positions, positions.sorted(), "\(scheme) ramp must ascend")
        }
    }

    func testLightPaletteIsAQuieterWatermark() {
        // Cream paper has no headroom for a glow: the light palette must emit
        // less and keep more of its ground, or the aurora reads as a smudge.
        let dark = FluidAuroraKernelPalette.palette(colorScheme: .dark)
        let light = FluidAuroraKernelPalette.palette(colorScheme: .light)
        XCTAssertLessThan(light.emission, dark.emission)
        XCTAssertGreaterThan(light.groundVisibility, dark.groundVisibility)
        XCTAssertLessThan(light.coreLift, dark.coreLift)
    }

    func testReduceTransparencySinksTheKernelIntoItsGround() {
        // The ask is less layering, not less colour: emission drops, and the
        // ground share rises so the sheet reads as a printed tint.
        for scheme in [ColorScheme.dark, .light] {
            let plain = FluidAuroraKernelPalette.palette(colorScheme: scheme)
            let reduced = FluidAuroraKernelPalette.palette(colorScheme: scheme, reduceTransparency: true)
            XCTAssertLessThanOrEqual(reduced.emission, plain.emission, "\(scheme)")
            XCTAssertGreaterThanOrEqual(reduced.groundVisibility, plain.groundVisibility, "\(scheme)")
        }
    }

    // MARK: - Motion

    func testStillPoseIsExactlyTheTimeZeroFrame() {
        // Reference-date zero puts every phase at exactly 0, so a still kernel
        // is the authored resting pose — not whichever frame the clock happened
        // to stop on. `still` must be `frame(at: 0)` by construction, which is
        // what makes the Reduce-Motion pose deterministic.
        XCTAssertEqual(
            FluidAuroraMotion.still,
            FluidAuroraMotion.frame(at: 0, renderedSize: FluidAuroraMotion.authoredSize)
        )
        XCTAssertEqual(FluidAuroraMotion.still.sway[0], 0, accuracy: 0.0001, "lead ribbon rests centred")
        XCTAssertGreaterThan(
            abs(FluidAuroraMotion.still.sway[1] - FluidAuroraMotion.still.sway[2]),
            0.5,
            "the displaced ribbons rest fanned apart, so a frozen kernel still reads as three layers of weather"
        )
    }

    func testFrameArraysCarryEveryRibbon() {
        let frame = FluidAuroraMotion.frame(at: 123.456)
        XCTAssertEqual(frame.sway.count, FluidAuroraMotion.ribbonCount)
        XCTAssertEqual(frame.stretch.count, FluidAuroraMotion.ribbonCount)
        XCTAssertEqual(frame.lift.count, FluidAuroraMotion.ribbonCount)
        XCTAssertEqual(frame.alpha.count, FluidAuroraMotion.ribbonCount)
    }

    func testPhasesWrapIntoUnitRange() {
        // Wrapped phases are the whole reason the kernel cannot stutter on a
        // long-lived sheet: precision never degrades no matter the uptime.
        for time in [0.0, 1.0, -1.0, 37.0, 8.5, 123_456.789, -987.6] {
            for period in [
                FluidAuroraMotion.driftPeriod,
                FluidAuroraMotion.counterDriftPeriod,
                FluidAuroraMotion.breathPeriod,
                FluidAuroraMotion.corePeriod,
                FluidAuroraMotion.haloPeriod
            ] {
                let phase = FluidAuroraMotion.phase(at: time, period: period)
                XCTAssertGreaterThanOrEqual(phase, 0)
                XCTAssertLessThan(phase, 1, "time \(time), period \(period)")
            }
        }
    }

    func testPeriodsAreMutuallyIncommensurate() {
        // Two ribbons on commensurate periods beat into a visible grid rhythm
        // and phase-lock. The hazard is a *near-integer* ratio: exactly 2× or
        // 3× means the two tracks realign every short period, and near-integer
        // means they realign almost, producing a slow visible beat. Every pair
        // must stay clear of any integer multiple.
        let periods = [
            FluidAuroraMotion.driftPeriod,
            FluidAuroraMotion.counterDriftPeriod,
            FluidAuroraMotion.breathPeriod,
            FluidAuroraMotion.corePeriod,
            FluidAuroraMotion.haloPeriod
        ]
        XCTAssertEqual(Set(periods).count, periods.count, "periods must be distinct")
        for first in periods {
            for second in periods where first != second {
                let ratio = max(first, second) / min(first, second)
                let nearestInteger = ratio.rounded()
                let distanceFromInteger = abs(ratio - nearestInteger)
                XCTAssertGreaterThan(
                    distanceFromInteger,
                    0.05,
                    "\(first)s and \(second)s are near-commensurate (ratio \(ratio) ≈ \(nearestInteger)×)"
                )
            }
        }
    }

    func testFrameIsContinuousAcrossTheWrap() {
        // A jump at the wrap is a visible pop once per loop. Sampling just
        // before and just after each period boundary must stay close.
        for period in [
            FluidAuroraMotion.driftPeriod,
            FluidAuroraMotion.counterDriftPeriod,
            FluidAuroraMotion.breathPeriod,
            FluidAuroraMotion.corePeriod,
            FluidAuroraMotion.haloPeriod
        ] {
            let before = FluidAuroraMotion.frame(at: period - 0.01)
            let after = FluidAuroraMotion.frame(at: period + 0.01)
            for index in 0..<FluidAuroraMotion.ribbonCount {
                XCTAssertEqual(before.sway[index], after.sway[index], accuracy: 0.35, "sway, period \(period)")
                XCTAssertEqual(before.stretch[index], after.stretch[index], accuracy: 0.05, "stretch, period \(period)")
                XCTAssertEqual(before.lift[index], after.lift[index], accuracy: 0.35, "lift, period \(period)")
                XCTAssertEqual(before.alpha[index], after.alpha[index], accuracy: 0.05, "alpha, period \(period)")
            }
        }
    }

    func testFrameValuesStayInSensibleRanges() {
        // The kernel sits beside a headline for as long as the sheet is open;
        // every sampled value must stay where the renderer expects it.
        for seconds in stride(from: 0.0, through: 90.0, by: 0.7) {
            let frame = FluidAuroraMotion.frame(at: seconds)
            for index in 0..<FluidAuroraMotion.ribbonCount {
                XCTAssertGreaterThanOrEqual(frame.alpha[index], 0)
                XCTAssertLessThanOrEqual(frame.alpha[index], 1)
                XCTAssertGreaterThanOrEqual(frame.stretch[index], 0.9)
                XCTAssertLessThanOrEqual(frame.stretch[index], 1.1)
                XCTAssertLessThanOrEqual(abs(frame.sway[index]), 8)
                XCTAssertLessThanOrEqual(abs(frame.lift[index]), 8)
            }
            XCTAssertGreaterThanOrEqual(frame.coreScale, 0.8)
            XCTAssertLessThanOrEqual(frame.coreScale, 1.05)
            XCTAssertGreaterThanOrEqual(frame.coreBrightness, 0.4)
            XCTAssertLessThanOrEqual(frame.coreBrightness, 0.9)
            XCTAssertGreaterThanOrEqual(frame.halo, 0.3)
            XCTAssertLessThanOrEqual(frame.halo, 0.75)
        }
    }

    func testAmplitudesScaleWithRenderedSize() {
        // A 48pt kernel must drift half as far as a 96pt one, not the same
        // absolute points — otherwise small kernels wobble off their plate.
        let large = FluidAuroraMotion.frame(at: 42.0, renderedSize: 96)
        let small = FluidAuroraMotion.frame(at: 42.0, renderedSize: 48)
        for index in 0..<FluidAuroraMotion.ribbonCount {
            XCTAssertLessThanOrEqual(
                abs(small.sway[index]),
                abs(large.sway[index]) + 0.001,
                "small kernel sways further than the authored-size kernel"
            )
            XCTAssertLessThanOrEqual(
                abs(small.lift[index]),
                abs(large.lift[index]) + 0.001,
                "small kernel lifts further than the authored-size kernel"
            )
        }
    }

    func testMiddleRibbonRunsCounterToItsSiblings() {
        // The counter-drift is one of the two guards against phase-locking (the
        // other being the incommensurate periods). Pin it structurally: the
        // counter ribbon rides the fast 8.5s period against the lead's 37s, so
        // over a shared window it must cross centre far more often, and the two
        // must oppose at least a third of the time — a phase-locked pair would
        // cross together and never oppose.
        var opposingSamples = 0
        var totalSamples = 0
        var leadCrossings = 0
        var counterCrossings = 0
        var previousLead: CGFloat?
        var previousCounter: CGFloat?
        for seconds in stride(from: 0.0, through: 60.0, by: 0.5) {
            let frame = FluidAuroraMotion.frame(at: seconds)
            totalSamples += 1
            if frame.sway[1] * frame.sway[0] < 0 { opposingSamples += 1 }
            if let previous = previousLead,
               (previous < 0) != (frame.sway[0] < 0) { leadCrossings += 1 }
            if let previous = previousCounter,
               (previous < 0) != (frame.sway[1] < 0) { counterCrossings += 1 }
            previousLead = frame.sway[0]
            previousCounter = frame.sway[1]
        }
        XCTAssertGreaterThan(
            opposingSamples,
            totalSamples / 3,
            "counter ribbon never opposes its siblings; the field moves as one blob"
        )
        XCTAssertGreaterThan(
            counterCrossings,
            leadCrossings,
            "counter ribbon (\(counterCrossings) crossings) does not outrun the lead (\(leadCrossings)); the fast counter-period is not wired"
        )
    }
}

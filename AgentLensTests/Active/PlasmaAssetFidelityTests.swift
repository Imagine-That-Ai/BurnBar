import SwiftUI
import XCTest
@testable import OpenBurnBar

/// Locks the port to the brand asset.
///
/// These assert against the *transcribed tables*, not against a screenshot of
/// the result, so a designer retuning `plasma-selectors.js` and a developer
/// re-transcribing it will disagree here loudly rather than drift apart
/// quietly. Every number below is quoted from the shipped runtime.
final class PlasmaAssetFidelityTests: XCTestCase {

    // MARK: Durations

    func testTrackDurationsMatchTheShippedRuntime() {
        XCTAssertEqual(PlasmaBlobMotion.orbPrimary.duration, 7, "dynamicPlasmaMotion1")
        XCTAssertEqual(PlasmaBlobMotion.orbSecondary.duration, 8, "dynamicPlasmaMotion2")
        XCTAssertEqual(PlasmaBlobMotion.bubble.duration, 11, "ghostlyBubbleMorph")
        XCTAssertEqual(PlasmaGlowBreath.duration, 4, "plasmaGlowBreath")
    }

    func testConstellationDriftsUseFourDistinctAlternatingPeriods() {
        let drifts = (0..<4).map { PlasmaBlobMotion.constellationDrift(forIndex: $0) }
        XCTAssertEqual(drifts.map(\.duration), [9.2, 10.6, 11.4, 8.8], "liquidDriftA…D")
        XCTAssertTrue(drifts.allSatisfy(\.autoreverses), "all four are animation-direction: alternate")
        // The beat between periods is what stops the field pulsing as a grid.
        XCTAssertEqual(Set(drifts.map(\.duration)).count, 4)
    }

    func testAlternatingTrackCycleIsTwiceItsDuration() {
        let drift = PlasmaBlobMotion.constellationDriftA
        XCTAssertEqual(drift.cycleDuration, drift.duration * 2)
        XCTAssertEqual(PlasmaBlobMotion.orbPrimary.cycleDuration, 7, "non-alternating tracks loop once")
    }

    func testDriftAssignmentRepeatsEveryFourOrbs() {
        // The asset's `nth-child(4n+1) … nth-child(4n)` rotation.
        for index in 0..<12 {
            XCTAssertEqual(
                PlasmaBlobMotion.constellationDrift(forIndex: index).duration,
                PlasmaBlobMotion.constellationDrift(forIndex: index % 4).duration
            )
        }
    }

    // MARK: Curves

    func testAlternatingTrackReturnsToItsStartPoseAtBothEnds() {
        let drift = PlasmaBlobMotion.constellationDriftA
        let start = drift.state(atPhase: 0)
        let end = drift.state(atPhase: 1)
        XCTAssertEqual(start.translation.width, end.translation.width, accuracy: 0.001)
        XCTAssertEqual(start.translation.height, end.translation.height, accuracy: 0.001)
    }

    func testAlternatingTrackIsSymmetricAboutItsMidpoint() {
        let drift = PlasmaBlobMotion.constellationDriftB
        // `alternate` replays the table backwards, so 0.25 and 0.75 are the
        // same pose reached from opposite directions.
        let rising = drift.state(atPhase: 0.25)
        let falling = drift.state(atPhase: 0.75)
        XCTAssertEqual(rising.translation.width, falling.translation.width, accuracy: 0.001)
        XCTAssertEqual(rising.translation.height, falling.translation.height, accuracy: 0.001)
    }

    func testOrbTracksActuallyMoveAwayFromRest() {
        // A silent regression to a still table would be invisible on screen but
        // would gut the whole control.
        let mid = PlasmaBlobMotion.orbPrimary.state(atPhase: 0.5)
        XCTAssertEqual(mid.translation.width, 3, accuracy: 0.001)
        XCTAssertEqual(mid.translation.height, -3, accuracy: 0.001)
        XCTAssertEqual(mid.scaleWidth, 1.05, accuracy: 0.001)
    }

    func testOrbOffsetsScaleWithRenderedSize() {
        // Tracks are authored against a 52pt orb; a 14pt inline orb must drift
        // proportionally instead of flying off its own plate.
        let track = PlasmaBlobMotion.orbPrimary
        let state = track.state(atPhase: 0.5)
        let authored = track.translation(state, renderedSize: 52)
        let inline = track.translation(state, renderedSize: 13)
        XCTAssertEqual(authored.width, 3, accuracy: 0.001)
        XCTAssertEqual(inline.width, 0.75, accuracy: 0.001)
    }

    func testBubbleOffsetsAreAbsoluteRegardlessOfWidth() {
        let track = PlasmaBlobMotion.bubble
        let state = track.state(atPhase: 0.2)
        XCTAssertEqual(
            track.translation(state, renderedSize: 356).width,
            track.translation(state, renderedSize: 900).width,
            accuracy: 0.001,
            "the bubble billows the same at any width"
        )
    }

    func testZeroDurationTrackYieldsStillPoseRatherThanNaN() {
        // A NaN would reach `Path` control points and crash rather than draw.
        let broken = PlasmaBlobMotion(keyframes: [], duration: 0, authoredSize: nil)
        let state = broken.state(at: Date(timeIntervalSinceReferenceDate: 1234))
        XCTAssertEqual(state.translation.width, 0)
        XCTAssertFalse(state.scaleWidth.isNaN)
    }

    func testPhaseOffsetDesynchronisesOrbsSharingOneClock() {
        let track = PlasmaBlobMotion.orbSecondary
        let date = Date(timeIntervalSinceReferenceDate: 3)
        let lead = track.state(at: date, phaseOffset: 0)
        let follow = track.state(at: date, phaseOffset: 0.37)
        XCTAssertNotEqual(lead.translation.width, follow.translation.width, accuracy: 0.0001)
    }

    // MARK: Glow

    func testGlowBreathPeaksMidCycleAndReturns() {
        let start = PlasmaGlowBreath.state(atPhase: 0)
        let mid = PlasmaGlowBreath.state(atPhase: 0.5)
        let end = PlasmaGlowBreath.state(atPhase: 1)
        XCTAssertGreaterThan(mid.scale, start.scale)
        XCTAssertGreaterThan(mid.opacity, start.opacity)
        XCTAssertEqual(start.scale, end.scale, accuracy: 0.001)
    }

    func testEmissiveOpacityIsZeroAtUnitBrightness() {
        // CSS `brightness(1)` is a no-op; the additive veil that stands in for
        // it must not tint an unlit orb.
        let neutral = PlasmaGlowState(blurFraction: 0.2, brightness: 1, scale: 1, opacity: 1)
        XCTAssertEqual(neutral.emissiveOpacity, 0)
    }

    // MARK: Thinking bubbles

    func testThinkingBubblesUseTheAssetsStaggeredDelays() {
        XCTAssertEqual(PlasmaThinkingBubble.all.map(\.delay), [0, 0.4, 0.9])
        XCTAssertEqual(PlasmaThinkingBubble.all.map(\.duration), [2.4, 3.0, 2.6])
    }

    func testThinkingBubblesAreStaggeredRatherThanPulsingTogether() {
        // The delays phase-shift a continuously looping emitter, so at any
        // instant the three particles are at three different points of their
        // rise. Three bubbles leaving together would read as a pulse, not as a
        // stream, which is the whole difference from a spinner.
        let now = Date(timeIntervalSinceReferenceDate: 12.5)
        let heights = PlasmaThinkingBubble.all.map { $0.state(at: now).offset.height }
        XCTAssertEqual(Set(heights.map { ($0 * 100).rounded() }).count, 3)
    }

    func testEveryThinkingBubbleFullyFadesSomewhereInItsCycle() {
        // A particle that never reaches zero opacity would leave a permanent
        // speck hanging over the orb.
        for bubble in PlasmaThinkingBubble.all {
            let samples = stride(from: 0.0, to: bubble.duration, by: 0.05).map {
                bubble.state(at: Date(timeIntervalSinceReferenceDate: $0)).opacity
            }
            XCTAssertLessThan(samples.min() ?? 1, 0.05, "bubble never clears")
            XCTAssertGreaterThan(samples.max() ?? 0, 0.5, "bubble never appears")
        }
    }

    // MARK: Eyes

    func testGlanceAndBlinkPeriodsDoNotPhaseLock() {
        // Co-prime-ish periods keep the face from settling into a loop the eye
        // can predict, which is what makes it read as alive rather than looped.
        let ratio = PlasmaEyeMotion.blinkDuration / PlasmaEyeMotion.glanceDuration
        XCTAssertNotEqual(ratio, ratio.rounded(), accuracy: 0.05)
    }

    func testBlinkIsClosedOnlyForAnInstant() {
        let samples = stride(from: 0.0, to: PlasmaEyeMotion.blinkDuration, by: 0.05).map {
            PlasmaEyeMotion.blinkScaleY(at: Date(timeIntervalSinceReferenceDate: $0))
        }
        let closed = samples.filter { $0 < 0.35 }
        XCTAssertFalse(closed.isEmpty, "the eye must actually close")
        XCTAssertLessThan(
            Double(closed.count) / Double(samples.count),
            0.12,
            "a face that spends its life mid-blink reads as broken, not sleepy"
        )
    }

    // MARK: Shape

    func testCappedCornersStayWithinTheirCeiling() {
        // The model tray caps the blob so a long model id is never sliced by
        // the curve.
        let shape = PlasmaBlobShape(radii: .css(68, 32, 38, 62, 38, 54, 46, 62), cornerCap: 30)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 300, height: 60))
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.boundingRect.width <= 300.5)
    }

    func testDegenerateSizeYieldsAnEmptyPathRatherThanCrashing() {
        let shape = PlasmaBlobShape(radii: .ellipse, cornerCap: nil)
        XCTAssertTrue(shape.path(in: CGRect(x: 0, y: 0, width: 0, height: 40)).isEmpty)
    }
}

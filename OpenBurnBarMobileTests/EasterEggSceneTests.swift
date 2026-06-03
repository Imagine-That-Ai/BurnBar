import XCTest
import SwiftUI
import OpenBurnBarCore
@testable import OpenBurnBarMobile

// Coverage for the iOS easter-egg FX engine brought up to the website's refined
// spec: the shape-forming glyph sampler, the scene factory for all three event
// flavours, the event durations (5s takeover), and the scroll-reversal trigger
// (>=5 reversals within the window, cooldown, colorScheme routing) that must now
// fire on every scrollable surface — including Streams.

@MainActor
final class EasterEggSceneTests: XCTestCase {

    // MARK: - Glyph → target points (shape forming)

    func testGlyphSamplerProducesPointsForEverySpecShape() {
        for shape in ["$", ":)", "</>", "{ }"] {
            let points = GlyphSampler.points(for: shape)
            XCTAssertFalse(points.isEmpty, "expected sampled points for shape \(shape)")
            // Points are normalised origin-centred, roughly within -0.6...0.6.
            for p in points {
                XCTAssertLessThanOrEqual(abs(p.x), 0.6, "x out of range for \(shape)")
                XCTAssertLessThanOrEqual(abs(p.y), 0.6, "y out of range for \(shape)")
            }
        }
    }

    func testGlyphSamplerIsCachedAndStable() {
        let first = GlyphSampler.points(for: "</>")
        let second = GlyphSampler.points(for: "</>")
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.first, second.first)
    }

    // MARK: - Scene factory

    func testSceneBuildsForLogoStorm() {
        let event = EasterEggEvent(kind: .logoStorm, startedAt: Date())
        let scene = EasterEggScene.make(
            for: event,
            size: CGSize(width: 390, height: 844),
            colorScheme: .dark
        )
        XCTAssertEqual(scene.kind, .logoStorm)
        // Must not crash drawing across the whole 5s takeover, including the
        // fade-out tail and the boundary case (reduce-motion + normal).
        assertDrawsCleanly(scene, size: CGSize(width: 390, height: 844))
    }

    func testSceneBuildsForCloudTokenRain() {
        let event = EasterEggEvent(kind: .cloudTokenRain, startedAt: Date())
        let scene = EasterEggScene.make(
            for: event,
            size: CGSize(width: 834, height: 1194),
            colorScheme: .light
        )
        XCTAssertEqual(scene.kind, .cloudTokenRain)
        assertDrawsCleanly(scene, size: CGSize(width: 834, height: 1194))
    }

    func testSceneBuildsForBoundaryBothEdges() {
        for edge in [EasterEggEdge.top, EasterEggEdge.bottom] {
            let event = EasterEggEvent(kind: .boundary(edge: edge), startedAt: Date())
            let scene = EasterEggScene.make(
                for: event,
                size: CGSize(width: 390, height: 844),
                colorScheme: .dark
            )
            XCTAssertEqual(scene.kind, .boundary(edge: edge))
            assertDrawsCleanly(scene, size: CGSize(width: 390, height: 844))
        }
    }

    // MARK: - Durations (5s takeover spec)

    func testTakeoverDurationsMatchSpec() {
        XCTAssertEqual(EasterEggScene.takeoverDuration, 5.0, accuracy: 0.0001)
        // Storm runs the full FXDUR; rain holds a short settle tail; boundary is
        // the ~0.95s ballistic arc.
        XCTAssertEqual(EasterEggEvent(kind: .logoStorm, startedAt: Date()).duration, 5.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(EasterEggEvent(kind: .cloudTokenRain, startedAt: Date()).duration, 5.0)
        XCTAssertEqual(EasterEggEvent(kind: .boundary(edge: .top), startedAt: Date()).duration, 0.95, accuracy: 0.0001)
    }

    // MARK: - Helpers

    /// Drives the scene's draw across a sweep of elapsed times to make sure the
    /// re-stepped physics never traps (NaN/∞ would surface as a crash in Canvas).
    private func assertDrawsCleanly(_ scene: EasterEggScene, size: CGSize) {
        for ms in stride(from: 0, through: 5800, by: 120) {
            let elapsed = TimeInterval(ms) / 1000.0
            GraphicsContextProbe.render(size: size) { ctx in
                scene.draw(into: ctx, size: size, elapsed: elapsed, reduceMotion: false)
            }
            GraphicsContextProbe.render(size: size) { ctx in
                scene.draw(into: ctx, size: size, elapsed: elapsed, reduceMotion: true)
            }
        }
    }
}

// MARK: - Trigger / routing

@MainActor
final class EasterEggTriggerTests: XCTestCase {

    private func makeController() -> EasterEggController {
        // A fresh, isolated instance (not the shared singleton) so each test's
        // reversal window + cooldown start clean.
        EasterEggController.makeForTesting()
    }

    /// Feed alternating offsets above the min-delta to register one reversal per
    /// direction change. Five changes inside the window must summon.
    func testFiveReversalsSummonStormInDarkMode() {
        let controller = makeController()
        pushReversals(into: controller, tag: "streams", count: 6, isDark: true)
        XCTAssertNotNil(controller.activeEvent)
        XCTAssertEqual(controller.activeEvent?.kind, .logoStorm)
    }

    func testFiveReversalsSummonRainInLightMode() {
        let controller = makeController()
        pushReversals(into: controller, tag: "streams", count: 6, isDark: false)
        XCTAssertNotNil(controller.activeEvent)
        XCTAssertEqual(controller.activeEvent?.kind, .cloudTokenRain)
    }

    func testFewReversalsDoNotSummon() {
        let controller = makeController()
        pushReversals(into: controller, tag: "burn", count: 3, isDark: true)
        XCTAssertNil(controller.activeEvent)
    }

    func testTriggerWorksOnAnySurfaceTagIncludingStreams() {
        for tag in ["streams", "burn", "pulse", "anything"] {
            let controller = makeController()
            pushReversals(into: controller, tag: tag, count: 6, isDark: true)
            XCTAssertNotNil(controller.activeEvent, "summon failed for tag \(tag)")
        }
    }

    func testReducedMotionSuppressesSummon() {
        let controller = makeController()
        pushReversals(into: controller, tag: "streams", count: 8, isDark: true, reduceMotion: true)
        XCTAssertNil(controller.activeEvent)
    }

    func testTopBoundaryFiresOnOverscroll() {
        let controller = makeController()
        // Overscroll past the top (positive offset beyond the threshold).
        controller.registerScrollMetrics(
            tag: "streams", offset: 40, contentHeight: 4000, viewportHeight: 800,
            isDark: false, reduceMotion: false
        )
        XCTAssertEqual(controller.activeEvent?.kind, .boundary(edge: .top))
    }

    func testBottomBoundaryFiresOnOverscroll() {
        let controller = makeController()
        // Overscroll past the bottom: offset below -(scrollable + threshold).
        controller.registerScrollMetrics(
            tag: "streams", offset: -(3200 + 40), contentHeight: 4000, viewportHeight: 800,
            isDark: false, reduceMotion: false
        )
        XCTAssertEqual(controller.activeEvent?.kind, .boundary(edge: .bottom))
    }

    func testBoundarySuppressedUnderReduceMotion() {
        let controller = makeController()
        controller.registerScrollMetrics(
            tag: "streams", offset: 40, contentHeight: 4000, viewportHeight: 800,
            isDark: false, reduceMotion: true
        )
        XCTAssertNil(controller.activeEvent)
    }

    // MARK: Helpers

    private func pushReversals(
        into controller: EasterEggController,
        tag: String,
        count: Int,
        isDark: Bool,
        reduceMotion: Bool = false
    ) {
        // Seed an initial offset + direction.
        var offset: CGFloat = 0
        controller.registerScrollMetrics(
            tag: tag, offset: offset, contentHeight: 4000, viewportHeight: 800,
            isDark: isDark, reduceMotion: reduceMotion
        )
        offset = -20  // establish a "down" direction first
        controller.registerScrollMetrics(
            tag: tag, offset: offset, contentHeight: 4000, viewportHeight: 800,
            isDark: isDark, reduceMotion: reduceMotion
        )
        // Now alternate direction each step to register `count` reversals.
        var goingDown = true
        for _ in 0..<count {
            offset += goingDown ? 30 : -30
            goingDown.toggle()
            controller.registerScrollMetrics(
                tag: tag, offset: offset, contentHeight: 4000, viewportHeight: 800,
                isDark: isDark, reduceMotion: reduceMotion
            )
        }
    }
}

// MARK: - Test seam: render into a throwaway GraphicsContext

/// Renders one frame into an offscreen CoreGraphics-backed context via
/// `ImageRenderer`, which synchronously walks the `Canvas` draw closure once —
/// letting scene drawing be exercised in a unit test without a live UI. A draw
/// that produced NaN/∞ geometry would trap here.
private enum GraphicsContextProbe {
    @MainActor
    static func render(size: CGSize, _ body: @escaping (GraphicsContext) -> Void) {
        let canvas = Canvas { context, _ in body(context) }
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        _ = renderer.uiImage
    }
}

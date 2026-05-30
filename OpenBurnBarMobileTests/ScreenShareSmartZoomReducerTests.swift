#if canImport(UIKit)
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class ScreenShareSmartZoomReducerTests: XCTestCase {

    private let viewport = CGSize(width: 1000, height: 1000)
    private let content = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testReturnsIdleWhenModeOff() {
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: makeTextContext(receivedAt: now),
            mode: .off,
            selectedDisplayId: "display-1",
            manualOverrideUntil: nil,
            now: now
        )
        XCTAssertFalse(decision.isAutoFollowing)
        XCTAssertEqual(decision.scale, 1.0)
    }

    func testReturnsIdleWhenContextIsStale() {
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: makeTextContext(receivedAt: now.addingTimeInterval(-2.0)),
            mode: .smart,
            selectedDisplayId: "display-1",
            manualOverrideUntil: nil,
            now: now
        )
        XCTAssertFalse(decision.isAutoFollowing)
    }

    func testReturnsIdleWhenManualOverrideActive() {
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: makeTextContext(receivedAt: now),
            mode: .smart,
            selectedDisplayId: "display-1",
            manualOverrideUntil: now.addingTimeInterval(2.0),
            now: now
        )
        XCTAssertFalse(decision.isAutoFollowing)
    }

    func testReturnsIdleForDifferentDisplay() {
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: makeTextContext(receivedAt: now, displayId: "display-other"),
            mode: .smart,
            selectedDisplayId: "display-1",
            manualOverrideUntil: nil,
            now: now
        )
        XCTAssertFalse(decision.isAutoFollowing)
    }

    func testTextModeFitsRectInTextScaleRange() {
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: makeTextContext(receivedAt: now),
            mode: .smart,
            selectedDisplayId: "display-1",
            manualOverrideUntil: nil,
            now: now
        )
        XCTAssertTrue(decision.isAutoFollowing)
        XCTAssertTrue(ScreenShareSmartZoomReducer.textScaleRange.contains(decision.scale))
    }

    func testWindowModeFitsRectInWindowScaleRange() {
        let context = ScreenShareSmartZoomContext(
            targetKind: .focusedWindow,
            displayId: "display-1",
            normalizedRect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.6),
            normalizedPoint: nil,
            confidence: 0.7,
            receivedAt: now
        )
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: context,
            mode: .smart,
            selectedDisplayId: "display-1",
            manualOverrideUntil: nil,
            now: now
        )
        XCTAssertTrue(decision.isAutoFollowing)
        XCTAssertTrue(ScreenShareSmartZoomReducer.windowScaleRange.contains(decision.scale))
    }

    func testCursorModeUsesEntryScaleWhenViewportNotZoomed() {
        let context = ScreenShareSmartZoomContext(
            targetKind: .cursor,
            displayId: "display-1",
            normalizedRect: nil,
            normalizedPoint: .init(x: 0.5, y: 0.5),
            confidence: 0.4,
            receivedAt: now
        )
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: context,
            mode: .cursor,
            selectedDisplayId: "display-1",
            manualOverrideUntil: nil,
            now: now
        )
        XCTAssertTrue(decision.isAutoFollowing)
        XCTAssertEqual(decision.scale, ScreenShareSmartZoomReducer.cursorEntryScale, accuracy: 0.001)
    }

    func testCursorModeRejectsTextTarget() {
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: makeTextContext(receivedAt: now),
            mode: .cursor,
            selectedDisplayId: "display-1",
            manualOverrideUntil: nil,
            now: now
        )
        XCTAssertFalse(decision.isAutoFollowing)
    }

    func testClampsOffsetWithinViewport() {
        let context = ScreenShareSmartZoomContext(
            targetKind: .focusedElement,
            displayId: "display-1",
            normalizedRect: .init(x: 0.0, y: 0.0, width: 0.05, height: 0.05),
            normalizedPoint: nil,
            confidence: 0.95,
            receivedAt: now
        )
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: context,
            mode: .smart,
            selectedDisplayId: "display-1",
            manualOverrideUntil: nil,
            now: now
        )
        XCTAssertTrue(decision.isAutoFollowing)
        let limitX = viewport.width * (decision.scale - 1) / 2
        let limitY = viewport.height * (decision.scale - 1) / 2
        XCTAssertLessThanOrEqual(abs(decision.offset.width), limitX + 0.001)
        XCTAssertLessThanOrEqual(abs(decision.offset.height), limitY + 0.001)
    }

    func testAgentWorkspaceFitsRectInAgentScaleRange() {
        let context = ScreenShareSmartZoomContext(
            targetKind: .agentWorkspace,
            displayId: "display-1",
            normalizedRect: .init(x: 0.2, y: 0.2, width: 0.4, height: 0.3),
            normalizedPoint: nil,
            confidence: 0.8,
            receivedAt: now
        )
        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: viewport,
            contentRect: content,
            currentState: .init(),
            context: context,
            mode: .smart,
            selectedDisplayId: "display-1",
            manualOverrideUntil: nil,
            now: now
        )
        XCTAssertTrue(decision.isAutoFollowing)
        XCTAssertTrue(ScreenShareSmartZoomReducer.agentScaleRange.contains(decision.scale))
    }

    func testOffsetForCenterPlacesCenterAtViewportCenter() {
        let viewportSize = CGSize(width: 1000, height: 800)
        let offset = ScreenShareSmartZoomReducer.offsetForCenter(
            centerInContent: CGPoint(x: 500, y: 400),
            scale: 2.0,
            viewportSize: viewportSize
        )
        XCTAssertEqual(offset.width, 0, accuracy: 0.001)
        XCTAssertEqual(offset.height, 0, accuracy: 0.001)
    }

    func testOffsetForCenterClampsAtViewportEdge() {
        let viewportSize = CGSize(width: 1000, height: 1000)
        let offset = ScreenShareSmartZoomReducer.offsetForCenter(
            centerInContent: CGPoint(x: 0, y: 0),
            scale: 2.0,
            viewportSize: viewportSize
        )
        let limit = viewportSize.width * (2.0 - 1.0) / 2.0
        XCTAssertEqual(abs(offset.width), limit, accuracy: 0.001)
        XCTAssertEqual(abs(offset.height), limit, accuracy: 0.001)
    }

    func testNormalizedCenterUsesFocusedRectCenter() {
        let center = ScreenShareSmartZoomReducer.normalizedCenter(
            of: .init(x: 0.1, y: 0.2, width: 0.4, height: 0.1)
        )
        XCTAssertEqual(center.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(center.y, 0.25, accuracy: 0.001)
    }

    func testFocusedRectDecisionPlacesTargetAtVisibleCenterAboveKeyboard() {
        let viewportSize = CGSize(width: 400, height: 900)
        let contentRect = CGRect(x: 0, y: 100, width: 400, height: 225)
        let focusedRect = HermesRealtimeRelayNormalizedRect(x: 0.2, y: 0.4, width: 0.3, height: 0.08)
        let keyboardInset: CGFloat = 330
        let decision = ScreenShareSmartZoomReducer.fitRectDecision(
            normalizedRect: focusedRect,
            viewportSize: viewportSize,
            contentRect: contentRect,
            fillRatio: ScreenShareSmartZoomReducer.textFillRatio,
            scaleRange: ScreenShareSmartZoomReducer.textScaleRange,
            bottomInset: keyboardInset
        )
        let centerInContent = CGPoint(
            x: contentRect.minX + CGFloat(focusedRect.x + focusedRect.width / 2) * contentRect.width,
            y: contentRect.minY + CGFloat(focusedRect.y + focusedRect.height / 2) * contentRect.height
        )
        let projected = CGPoint(
            x: ((centerInContent.x - viewportSize.width / 2) * decision.scale) + viewportSize.width / 2 + decision.offset.width,
            y: ((centerInContent.y - viewportSize.height / 2) * decision.scale) + viewportSize.height / 2 + decision.offset.height
        )
        XCTAssertEqual(projected.x, viewportSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(projected.y, (viewportSize.height - keyboardInset) / 2, accuracy: 0.001)
    }

    func testTargetMatchesRespectsMode() {
        XCTAssertTrue(ScreenShareSmartZoomReducer.targetMatches(mode: .smart, kind: .focusedElement))
        XCTAssertTrue(ScreenShareSmartZoomReducer.targetMatches(mode: .text, kind: .focusedElement))
        XCTAssertFalse(ScreenShareSmartZoomReducer.targetMatches(mode: .text, kind: .focusedWindow))
        XCTAssertTrue(ScreenShareSmartZoomReducer.targetMatches(mode: .window, kind: .focusedWindow))
        XCTAssertFalse(ScreenShareSmartZoomReducer.targetMatches(mode: .cursor, kind: .focusedElement))
        XCTAssertFalse(ScreenShareSmartZoomReducer.targetMatches(mode: .off, kind: .cursor))
    }

    private func makeTextContext(
        receivedAt: Date,
        displayId: String? = "display-1"
    ) -> ScreenShareSmartZoomContext {
        ScreenShareSmartZoomContext(
            targetKind: .focusedElement,
            displayId: displayId,
            normalizedRect: .init(x: 0.4, y: 0.45, width: 0.2, height: 0.05),
            normalizedPoint: nil,
            confidence: 0.95,
            receivedAt: receivedAt
        )
    }
    // MARK: - Letterboxed content rect (CLI inline mirror scenario)

    /// When the content rect is smaller than the viewport (16:9 video in a
    /// portrait phone view), the reducer should still produce correct zoom
    /// that targets the focused rect within the actual video area.
    func testFitRectDecisionWithLetterboxedContentRect() {
        // Simulates a portrait phone: 390w × 700h viewport.
        // A 16:9 Mac screen renders as a 390×219 strip centered at y=240.
        let phoneViewport = CGSize(width: 390, height: 700)
        let letterboxedContent = CGRect(
            x: 0,
            y: (700 - 219.375) / 2,
            width: 390,
            height: 219.375   // 390 / (16/9)
        )

        // Agent workspace covering the right half of the Mac screen.
        let context = ScreenShareSmartZoomContext(
            targetKind: .agentWorkspace,
            displayId: nil,
            normalizedRect: .init(x: 0.5, y: 0.0, width: 0.5, height: 1.0),
            normalizedPoint: nil,
            confidence: 0.9,
            receivedAt: now
        )

        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: phoneViewport,
            contentRect: letterboxedContent,
            currentState: .init(),
            context: context,
            mode: .smart,
            selectedDisplayId: nil,
            manualOverrideUntil: nil,
            now: now
        )

        XCTAssertTrue(decision.isAutoFollowing, "Should auto-follow with letterboxed content")
        // With a 0.5×1.0 target in a 390×219 content, the short axis is
        // 195pt (half width). Fill ratio 0.72 → targetShortAxis = 390 * 0.72 = 281.
        // rawScale = 281 / 195 ≈ 1.44. Must be within agent scale range.
        XCTAssertTrue(
            ScreenShareSmartZoomReducer.agentScaleRange.contains(decision.scale),
            "Scale \(decision.scale) should be in agent range \(ScreenShareSmartZoomReducer.agentScaleRange)"
        )
        // Scale should be > 1 to actually zoom in.
        XCTAssertGreaterThan(decision.scale, 1.0, "Should zoom in for letterboxed content")
    }

    func testFitRectDecisionWithLetterboxedContent_TextFocus() {
        // Portrait phone with 16:9 letterboxed content.
        let phoneViewport = CGSize(width: 390, height: 700)
        let aspectRatio: CGFloat = 16.0 / 9.0
        let contentHeight = 390 / aspectRatio  // ~219
        let letterboxedContent = CGRect(
            x: 0,
            y: (700 - contentHeight) / 2,
            width: 390,
            height: contentHeight
        )

        // Small text field in the center-left of the Mac screen.
        let context = ScreenShareSmartZoomContext(
            targetKind: .focusedElement,
            displayId: nil,
            normalizedRect: .init(x: 0.1, y: 0.4, width: 0.3, height: 0.05),
            normalizedPoint: nil,
            confidence: 0.95,
            receivedAt: now
        )

        let decision = ScreenShareSmartZoomReducer.reduce(
            viewportSize: phoneViewport,
            contentRect: letterboxedContent,
            currentState: .init(),
            context: context,
            mode: .smart,
            selectedDisplayId: nil,
            manualOverrideUntil: nil,
            now: now
        )

        XCTAssertTrue(decision.isAutoFollowing, "Should auto-follow for text focus in letterboxed content")
        XCTAssertTrue(
            ScreenShareSmartZoomReducer.textScaleRange.contains(decision.scale),
            "Scale \(decision.scale) should be in text range \(ScreenShareSmartZoomReducer.textScaleRange)"
        )
        // For a tiny text field, scale should be aggressive.
        XCTAssertGreaterThan(decision.scale, 2.0, "Text field zoom should be significantly zoomed in")
    }

    /// Verifies that the initial auto-zoom scale computation (view height ÷
    /// content height) produces a value that fills the phone screen when
    /// viewing a 16:9 Mac screen in portrait.
    func testInitialZoomScaleForPortraitPhone() {
        let viewHeight: CGFloat = 700
        let viewWidth: CGFloat = 390
        let aspectRatio: CGFloat = 16.0 / 9.0
        let contentHeight = viewWidth / aspectRatio  // ~219

        let expectedScale = ScreenShareViewportState.clampScale(
            viewHeight / max(contentHeight, 1)
        )

        // Should be around 3.19, well within the [1, 4] range.
        XCTAssertGreaterThan(expectedScale, 2.5, "Initial zoom should meaningfully zoom in")
        XCTAssertLessThanOrEqual(expectedScale, 4.0, "Initial zoom should not exceed max scale")

        // The offset should be zero (centered) and clamped correctly.
        let clampedOffset = ScreenShareViewportState.clamp(
            offset: .zero,
            scale: expectedScale,
            in: CGSize(width: viewWidth, height: viewHeight)
        )
        XCTAssertEqual(clampedOffset.width, 0, accuracy: 0.001, "Initial offset should be horizontally centered")
    }

    /// Ultrawide (32:9) Mac screen should clamp to max scale.
    func testInitialZoomScaleForUltrawide() {
        let viewHeight: CGFloat = 700
        let viewWidth: CGFloat = 390
        let aspectRatio: CGFloat = 32.0 / 9.0
        let contentHeight = viewWidth / aspectRatio  // ~110

        let expectedScale = ScreenShareViewportState.clampScale(
            viewHeight / max(contentHeight, 1)
        )

        // ~6.36, clamped to 4.0.
        XCTAssertEqual(expectedScale, ScreenShareViewportState.maximumScale, accuracy: 0.001,
                        "Ultrawide should clamp to max scale")
    }

    /// Standard 4:3 iPad-like screen should produce a moderate zoom.
    func testInitialZoomScaleForStandardDisplay() {
        let viewHeight: CGFloat = 700
        let viewWidth: CGFloat = 390
        let aspectRatio: CGFloat = 4.0 / 3.0
        let contentHeight = viewWidth / aspectRatio  // 292.5

        let expectedScale = ScreenShareViewportState.clampScale(
            viewHeight / max(contentHeight, 1)
        )

        // ~2.39.
        XCTAssertGreaterThan(expectedScale, 2.0, "4:3 display should still zoom in meaningfully")
        XCTAssertLessThan(expectedScale, 3.0, "4:3 display shouldn't zoom as aggressively as 16:9")
    }
}
#endif

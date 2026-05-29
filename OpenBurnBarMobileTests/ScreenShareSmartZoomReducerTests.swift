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
}
#endif

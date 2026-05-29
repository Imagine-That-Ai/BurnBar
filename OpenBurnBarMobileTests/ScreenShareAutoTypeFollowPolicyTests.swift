#if canImport(UIKit)
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class ScreenShareAutoTypeFollowPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testIsActiveTextFocusRequiresFocusedElement() {
        XCTAssertTrue(
            ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: makeTextContext(receivedAt: now),
                selectedDisplayId: "display-1",
                now: now
            )
        )
        XCTAssertFalse(
            ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: makeWindowContext(receivedAt: now),
                selectedDisplayId: "display-1",
                now: now
            )
        )
    }

    func testIsActiveTextFocusRejectsStaleContext() {
        XCTAssertFalse(
            ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: makeTextContext(receivedAt: now.addingTimeInterval(-2.0)),
                selectedDisplayId: "display-1",
                now: now
            )
        )
    }

    func testIsActiveTextFocusRejectsWrongDisplay() {
        XCTAssertFalse(
            ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: makeTextContext(receivedAt: now, displayId: "display-other"),
                selectedDisplayId: "display-1",
                now: now
            )
        )
    }

    func testIsActiveTextFocusAllowsMissingSelectedDisplay() {
        XCTAssertTrue(
            ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: makeTextContext(receivedAt: now, displayId: "display-1"),
                selectedDisplayId: nil,
                now: now
            )
        )
    }

    func testIsActiveTextFocusRejectsLowConfidence() {
        XCTAssertFalse(
            ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: makeTextContext(receivedAt: now, confidence: 0.4),
                selectedDisplayId: "display-1",
                now: now
            )
        )
    }

    func testIsActiveTextFocusAllowsMissingConfidence() {
        XCTAssertTrue(
            ScreenShareAutoTypeFollowPolicy.isActiveTextFocus(
                context: makeTextContext(receivedAt: now, confidence: nil),
                selectedDisplayId: "display-1",
                now: now
            )
        )
    }

    private func makeTextContext(
        receivedAt: Date,
        displayId: String? = "display-1",
        confidence: Double? = 0.95
    ) -> ScreenShareSmartZoomContext {
        ScreenShareSmartZoomContext(
            targetKind: .focusedElement,
            displayId: displayId,
            normalizedRect: .init(x: 0.4, y: 0.45, width: 0.2, height: 0.05),
            normalizedPoint: nil,
            confidence: confidence,
            receivedAt: receivedAt
        )
    }

    private func makeWindowContext(receivedAt: Date) -> ScreenShareSmartZoomContext {
        ScreenShareSmartZoomContext(
            targetKind: .focusedWindow,
            displayId: "display-1",
            normalizedRect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.6),
            normalizedPoint: nil,
            confidence: 0.7,
            receivedAt: receivedAt
        )
    }
}
#endif

#if canImport(UIKit)
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class ScreenShareAutoTypeFollowPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testOpensOnFocusedElementWhenEnabled() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: false,
            context: makeTextContext(receivedAt: now)
        )
        XCTAssertEqual(action, .open)
    }

    func testBlockedWhenPreferenceOff() {
        let action = reduce(
            autoKeyboardEnabled: false,
            isTyping: false,
            context: makeTextContext(receivedAt: now)
        )
        XCTAssertEqual(action, .none)
    }

    func testBlockedWhenContextStale() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: false,
            context: makeTextContext(receivedAt: now.addingTimeInterval(-2.0))
        )
        XCTAssertEqual(action, .none)
    }

    func testBlockedWhenWrongDisplay() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: false,
            context: makeTextContext(receivedAt: now, displayId: "display-other"),
            selectedDisplayId: "display-1"
        )
        XCTAssertEqual(action, .none)
    }

    func testBlockedWhenCoPilotMode() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: false,
            isCoPilotMode: true,
            context: makeTextContext(receivedAt: now)
        )
        XCTAssertEqual(action, .none)
    }

    func testBlockedWhenManualDismissActive() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: false,
            context: makeTextContext(receivedAt: now),
            manualDismissUntil: now.addingTimeInterval(2.0)
        )
        XCTAssertEqual(action, .none)
    }

    func testOpensWhenManualDismissExpired() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: false,
            context: makeTextContext(receivedAt: now),
            manualDismissUntil: now.addingTimeInterval(-1.0)
        )
        XCTAssertEqual(action, .open)
    }

    func testOpensWhenSelectedDisplayMissing() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: false,
            context: makeTextContext(receivedAt: now, displayId: "display-1"),
            selectedDisplayId: nil
        )
        XCTAssertEqual(action, .open)
    }

    func testBlockedWhenAlreadyTyping() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: true,
            context: makeTextContext(receivedAt: now)
        )
        XCTAssertEqual(action, .none)
    }

    func testBlockedWhenControlDisabled() {
        let action = reduce(
            autoKeyboardEnabled: true,
            controlInputEnabled: false,
            isTyping: false,
            context: makeTextContext(receivedAt: now)
        )
        XCTAssertEqual(action, .none)
    }

    func testClosesWhenControlDisabledWhileTyping() {
        let action = reduce(
            autoKeyboardEnabled: true,
            controlInputEnabled: false,
            isTyping: true,
            context: makeTextContext(receivedAt: now)
        )
        XCTAssertEqual(action, .close)
    }

    func testClosesWhenFocusLeavesTextField() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: true,
            context: makeWindowContext(receivedAt: now)
        )
        XCTAssertEqual(action, .close)
    }

    func testClosesWhenContextStaleWhileTyping() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: true,
            context: makeTextContext(receivedAt: now.addingTimeInterval(-2.0))
        )
        XCTAssertEqual(action, .close)
    }

    func testClosesWhenContextMissingWhileTyping() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: true,
            context: nil
        )
        XCTAssertEqual(action, .close)
    }

    func testBlockedWhenConfidenceBelowFloor() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: false,
            context: makeTextContext(receivedAt: now, confidence: 0.4)
        )
        XCTAssertEqual(action, .none)
    }

    func testOpensWhenConfidenceMissing() {
        let action = reduce(
            autoKeyboardEnabled: true,
            isTyping: false,
            context: makeTextContext(receivedAt: now, confidence: nil)
        )
        XCTAssertEqual(action, .open)
    }

    func testEnablingAutoKeyboardMovesViewerIntoDirectControlMode() {
        let mode = ScreenShareSmartTextActivationPolicy.modeAfterAutoKeyboardToggle(
            enabled: true,
            currentMode: .view,
            controlInputEnabled: true
        )

        XCTAssertEqual(mode, .control)
    }

    func testAutoKeyboardTogglePreservesModeWhenControlUnavailableOrDisabling() {
        XCTAssertEqual(
            ScreenShareSmartTextActivationPolicy.modeAfterAutoKeyboardToggle(
                enabled: true,
                currentMode: .view,
                controlInputEnabled: false
            ),
            .view
        )
        XCTAssertEqual(
            ScreenShareSmartTextActivationPolicy.modeAfterAutoKeyboardToggle(
                enabled: false,
                currentMode: .trackpad,
                controlInputEnabled: true
            ),
            .trackpad
        )
    }

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

    private func reduce(
        autoKeyboardEnabled: Bool,
        controlInputEnabled: Bool = true,
        isTyping: Bool,
        isCoPilotMode: Bool = false,
        context: ScreenShareSmartZoomContext?,
        selectedDisplayId: String? = "display-1",
        manualDismissUntil: Date? = nil
    ) -> ScreenShareAutoTypeFollowPolicy.Action {
        ScreenShareAutoTypeFollowPolicy.reduce(
            autoKeyboardEnabled: autoKeyboardEnabled,
            controlInputEnabled: controlInputEnabled,
            isTyping: isTyping,
            isCoPilotMode: isCoPilotMode,
            context: context,
            selectedDisplayId: selectedDisplayId,
            manualDismissUntil: manualDismissUntil,
            now: now
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

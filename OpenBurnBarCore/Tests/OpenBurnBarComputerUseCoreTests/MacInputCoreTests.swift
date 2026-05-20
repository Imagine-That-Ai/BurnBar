import XCTest
@testable import OpenBurnBarComputerUseCore

final class MacInputCoreTests: XCTestCase {
    // MARK: unicode typing plan

    func testUnicodeTypingEventsOnlyCarryTextOnKeyDown() {
        let events = MacInputCore.unicodeTypingEvents(for: "ab")

        XCTAssertEqual(events, [
            .init(text: "a", isKeyDown: true, carriesUnicodeText: true),
            .init(text: "a", isKeyDown: false, carriesUnicodeText: false),
            .init(text: "b", isKeyDown: true, carriesUnicodeText: true),
            .init(text: "b", isKeyDown: false, carriesUnicodeText: false)
        ])
    }

    func testUnicodeTypingEventsPreserveExtendedGraphemeClusters() {
        let events = MacInputCore.unicodeTypingEvents(for: "e\u{301}")

        XCTAssertEqual(events, [
            .init(text: "e\u{301}", isKeyDown: true, carriesUnicodeText: true),
            .init(text: "e\u{301}", isKeyDown: false, carriesUnicodeText: false)
        ])
    }

    // MARK: virtual-key map

    func testVirtualKeyKnownNames() {
        XCTAssertEqual(MacInputCore.virtualKey(for: "Return"), 36)
        XCTAssertEqual(MacInputCore.virtualKey(for: "enter"), 36)
        XCTAssertEqual(MacInputCore.virtualKey(for: "C"), 8)
        XCTAssertEqual(MacInputCore.virtualKey(for: "v"), 9)
        XCTAssertEqual(MacInputCore.virtualKey(for: "Escape"), 53)
        XCTAssertEqual(MacInputCore.virtualKey(for: "ESC"), 53)
        XCTAssertEqual(MacInputCore.virtualKey(for: "Up"), 126)
    }

    func testVirtualKeyUnknownReturnsNil() {
        XCTAssertNil(MacInputCore.virtualKey(for: "F13"))
        XCTAssertNil(MacInputCore.virtualKey(for: ""))
        XCTAssertNil(MacInputCore.virtualKey(for: "🔑"))
    }

    // MARK: modifier parsing

    func testModifiersAccents() {
        XCTAssertEqual(MacInputCore.modifiers(for: ["cmd"]), .command)
        XCTAssertEqual(MacInputCore.modifiers(for: ["⌘"]), .command)
        XCTAssertEqual(MacInputCore.modifiers(for: ["shift", "ctrl"]), [.shift, .control])
        XCTAssertEqual(MacInputCore.modifiers(for: ["⇧", "⌃"]), [.shift, .control])
    }

    func testModifiersIgnoresUnknown() {
        XCTAssertEqual(MacInputCore.modifiers(for: ["cmd", "doesnotexist"]), .command)
        XCTAssertEqual(MacInputCore.modifiers(for: []), [])
    }

    func testModifiersFunction() {
        XCTAssertEqual(MacInputCore.modifiers(for: ["fn"]), .function)
        XCTAssertEqual(MacInputCore.modifiers(for: ["FN", "shift"]), [.function, .shift])
    }

    // MARK: display bounds

    func testContainsPointInsideSingleDisplay() {
        let display = MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1920, height: 1080)
        XCTAssertTrue(MacInputCore.contains(point: (100, 100), displays: [display]))
        XCTAssertTrue(MacInputCore.contains(point: (0, 0), displays: [display]))
        XCTAssertFalse(MacInputCore.contains(point: (1920, 1080), displays: [display]),
            "Right/bottom edges are exclusive — a coordinate exactly at width/height is off-screen.")
    }

    func testContainsPointOutsideAllDisplays() {
        let display = MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1920, height: 1080)
        XCTAssertFalse(MacInputCore.contains(point: (-1, 100), displays: [display]))
        XCTAssertFalse(MacInputCore.contains(point: (5000, 100), displays: [display]))
        XCTAssertFalse(MacInputCore.contains(point: (100, -1), displays: [display]))
    }

    func testContainsPointSpansMultiMonitor() {
        let primary = MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1920, height: 1080)
        let secondary = MacInputCore.DisplayBounds(originX: 1920, originY: 0, width: 1280, height: 800)
        let displays = [primary, secondary]
        XCTAssertTrue(MacInputCore.contains(point: (2500, 400), displays: displays),
            "Point in the secondary display must be accepted.")
        XCTAssertFalse(MacInputCore.contains(point: (3500, 400), displays: displays),
            "Point past the secondary display must be rejected.")
    }

    func testContainsPointEmptyDisplayList() {
        XCTAssertFalse(MacInputCore.contains(point: (100, 100), displays: []),
            "An empty display list means no displays are connected; no point is valid.")
    }

    // MARK: normalized phone coordinates

    func testDenormalizeMapsCenterOfPrimaryDisplay() {
        let display = MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 1920, height: 1080)
        let point = MacInputCore.denormalize(normalizedX: 0.5, normalizedY: 0.5, in: display)
        XCTAssertEqual(point?.x, 960)
        XCTAssertEqual(point?.y, 540)
    }

    func testDenormalizePreservesDisplayOrigin() {
        let display = MacInputCore.DisplayBounds(originX: 1920, originY: 200, width: 1280, height: 800)
        let point = MacInputCore.denormalize(normalizedX: 0.25, normalizedY: 0.75, in: display)
        XCTAssertEqual(point?.x, 2240)
        XCTAssertEqual(point?.y, 800)
    }

    func testDenormalizeClampsRightAndBottomEdgesOnScreen() {
        let display = MacInputCore.DisplayBounds(originX: 10, originY: 20, width: 100, height: 50)
        let point = MacInputCore.denormalize(normalizedX: 1.0, normalizedY: 1.0, in: display)
        XCTAssertEqual(point?.x, 109)
        XCTAssertEqual(point?.y, 69)
    }

    func testDenormalizeRejectsOutOfRangeCoordinates() {
        let display = MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 100, height: 100)
        XCTAssertNil(MacInputCore.denormalize(normalizedX: -0.01, normalizedY: 0.5, in: display))
        XCTAssertNil(MacInputCore.denormalize(normalizedX: 0.5, normalizedY: 1.01, in: display))
        XCTAssertNil(MacInputCore.denormalize(normalizedX: nil, normalizedY: 0.5, in: display))
        XCTAssertNil(MacInputCore.denormalize(normalizedX: 0.5, normalizedY: nil, in: display))
    }

    func testDenormalizeRejectsMissingOrInvalidDisplay() {
        XCTAssertNil(MacInputCore.denormalize(normalizedX: 0.5, normalizedY: 0.5, in: nil))
        XCTAssertNil(MacInputCore.denormalize(
            normalizedX: 0.5,
            normalizedY: 0.5,
            in: MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 0, height: 100)
        ))
        XCTAssertNil(MacInputCore.denormalize(
            normalizedX: 0.5,
            normalizedY: 0.5,
            in: MacInputCore.DisplayBounds(originX: 0, originY: 0, width: 100, height: 0)
        ))
    }
}

import XCTest
@testable import OpenBurnBarComputerUseCore

final class MacInputCoreTests: XCTestCase {
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
}

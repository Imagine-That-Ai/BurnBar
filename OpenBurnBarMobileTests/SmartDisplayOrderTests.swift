import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class SmartDisplayOrderTests: XCTestCase {

    func test_defaultOrderPlacesNestHubBeforePixelClock() {
        let order = SmartDisplayOrder.default
        XCTAssertEqual(order.kinds, [.nestHub, .pixelClock])
    }

    func test_movePixelClockToFrontUpdatesOrder() {
        var order = SmartDisplayOrder.default
        order.move(.pixelClock, to: 0)
        XCTAssertEqual(order.kinds, [.pixelClock, .nestHub])
    }

    func test_moveOutOfRangeClampsToEnds() {
        var order = SmartDisplayOrder.default
        order.move(.nestHub, to: 10)
        XCTAssertEqual(order.kinds, [.pixelClock, .nestHub])
        order.move(.pixelClock, to: -5)
        XCTAssertEqual(order.kinds, [.pixelClock, .nestHub])
    }

    func test_codableRoundTripPreservesOrder() throws {
        var order = SmartDisplayOrder.default
        order.move(.pixelClock, to: 0)

        let data = try JSONEncoder().encode(order)
        let decoded = try JSONDecoder().decode(SmartDisplayOrder.self, from: data)
        XCTAssertEqual(decoded.kinds, [.pixelClock, .nestHub])
    }

    func test_decoderSkipsUnknownRawValues() throws {
        let raw = "[\"nestHub\",\"futurePanel\",\"pixelClock\"]"
        let data = Data(raw.utf8)
        let decoded = try JSONDecoder().decode(SmartDisplayOrder.self, from: data)
        XCTAssertEqual(decoded.kinds, [.nestHub, .pixelClock])
    }

    func test_decoderAppendsMissingCanonicalKinds() throws {
        let raw = "[\"pixelClock\"]"
        let data = Data(raw.utf8)
        let decoded = try JSONDecoder().decode(SmartDisplayOrder.self, from: data)
        XCTAssertEqual(decoded.kinds, [.pixelClock, .nestHub])
    }

    func test_normalizeDropsDuplicates() {
        let order = SmartDisplayOrder(kinds: [.pixelClock, .pixelClock, .nestHub])
        XCTAssertEqual(order.kinds, [.pixelClock, .nestHub])
    }

    func test_offsetsMoveMimicsListOnMoveSemantics() {
        var order = SmartDisplayOrder(kinds: [.nestHub, .pixelClock])
        order.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(order.kinds, [.pixelClock, .nestHub])
    }
}

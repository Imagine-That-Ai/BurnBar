import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - MiniSparkline

@MainActor
final class MiniSparklineTests: XCTestCase {

    func test_rendersWithEmptyData() throws {
        let view = MiniSparkline(data: [])
        XCTAssertNoThrow(try view.inspect())
    }

    func test_rendersWithSinglePoint() throws {
        let view = MiniSparkline(data: [1.0])
        XCTAssertNoThrow(try view.inspect())
    }

    func test_rendersWithMultiplePoints() throws {
        let view = MiniSparkline(data: [1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertNoThrow(try view.inspect())
    }

    func test_respectsCustomDimensions() throws {
        let view = MiniSparkline(data: [1.0], width: 100, height: 50)
        XCTAssertEqual(view.width, 100)
        XCTAssertEqual(view.height, 50)
    }

    func test_respectsDefaultDimensions() throws {
        let view = MiniSparkline(data: [1.0])
        XCTAssertEqual(view.width, 60)
        XCTAssertEqual(view.height, 20)
    }
}

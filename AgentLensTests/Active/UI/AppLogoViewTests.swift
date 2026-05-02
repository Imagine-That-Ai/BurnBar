import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - AppLogoView

@MainActor
final class AppLogoViewTests: XCTestCase {

    func test_rendersWithDefaultSize() throws {
        let view = AppLogoView()
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(ViewType.Image.self))
    }

    func test_rendersWithCustomSize() throws {
        let view = AppLogoView(size: 48)
        XCTAssertEqual(view.size, 48)
    }

    func test_defaultSizeIs24() throws {
        let view = AppLogoView()
        XCTAssertEqual(view.size, 24)
    }
}

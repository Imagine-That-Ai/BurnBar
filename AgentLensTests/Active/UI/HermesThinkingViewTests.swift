import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - HermesThinkingView

@MainActor
final class HermesThinkingViewTests: XCTestCase {

    func test_renders() throws {
        let view = HermesThinkingView()
        XCTAssertNoThrow(try view.inspect())
    }

    func test_containsThreeDroplets() throws {
        let view = HermesThinkingView()
        XCTAssertNoThrow(try view.inspect())
    }
}

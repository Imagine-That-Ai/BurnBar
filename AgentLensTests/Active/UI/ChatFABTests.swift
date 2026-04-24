import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - ChatFAB

@MainActor
final class ChatFABTests: XCTestCase {

    func test_renders() throws {
        let view = ChatFAB(hasNewInsights: false, action: {})
        XCTAssertNoThrow(try view.inspect())
    }

    func test_rendersWithInsights() throws {
        let view = ChatFAB(hasNewInsights: true, action: {})
        XCTAssertNoThrow(try view.inspect())
    }

    func test_actionCallbackFires() throws {
        var actionFired = false
        let view = ChatFAB(hasNewInsights: false) {
            actionFired = true
        }
        let sut = try view.inspect()
        try sut.find(ViewType.Button.self).tap()
        XCTAssertTrue(actionFired)
    }

    func test_showsSparklesIcon() throws {
        let view = ChatFAB(hasNewInsights: false, action: {})
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(ViewType.Image.self), "ChatFAB should contain sparkles icon")
    }
}

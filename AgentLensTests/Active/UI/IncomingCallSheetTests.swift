import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - IncomingCallSheet identity privacy

/// Covers the Mercury incoming-mirror/call sheet identity glyph. Inbound
/// approval prompts intentionally avoid profile-image loading because this path
/// has no verified requester-avatar source and must not display the local
/// signed-in account avatar as a stand-in for the requester.
@MainActor
final class IncomingCallSheetTests: XCTestCase {

    private func makeSheet(initial: String = "Q") -> IncomingCallSheet {
        IncomingCallSheet(
            pairedDeviceName: "Test iPhone",
            initial: initial,
            subtitle: "Screen mirror request",
            actionNoun: "mirror request",
            onAccept: {},
            onDecline: {}
        )
    }

    func test_rendersMonogramWithoutNetworkAvatarLoader() throws {
        let view = makeSheet()
        XCTAssertNoThrow(try view.inspect())
        XCTAssertNoThrow(try view.inspect().find(text: "Q"))
        XCTAssertThrowsError(try view.inspect().find(ViewType.AsyncImage.self))
    }

    func test_rendersPersonGlyphWhenNoInitial() throws {
        let view = makeSheet(initial: "   ")
        XCTAssertNoThrow(try view.inspect())
        XCTAssertNoThrow(try view.inspect().find(ViewType.Image.self))
        XCTAssertThrowsError(try view.inspect().find(ViewType.AsyncImage.self))
    }
}

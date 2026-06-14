import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - IncomingCallSheet avatar

/// Covers the Mercury incoming-mirror/call sheet avatar: the requesting
/// account's profile photo fills the circle when present, and the view falls
/// back to the monogram (`initial`) when no photo URL is supplied.
@MainActor
final class IncomingCallSheetTests: XCTestCase {

    private func makeSheet(avatarURL: URL?) -> IncomingCallSheet {
        IncomingCallSheet(
            pairedDeviceName: "Test iPhone",
            initial: "Q",
            avatarURL: avatarURL,
            subtitle: "Screen mirror request",
            actionNoun: "mirror request",
            onAccept: {},
            onDecline: {}
        )
    }

    func test_storesAvatarURLFromInit() {
        let url = URL(string: "https://example.com/avatar.png")!
        XCTAssertEqual(makeSheet(avatarURL: url).avatarURL, url)
    }

    func test_avatarURLDefaultsToNil() {
        let sheet = IncomingCallSheet(
            pairedDeviceName: "Test iPhone",
            initial: "Q",
            onAccept: {},
            onDecline: {}
        )
        XCTAssertNil(sheet.avatarURL)
    }

    func test_rendersMonogramWhenNoAvatar() throws {
        let view = makeSheet(avatarURL: nil)
        XCTAssertNoThrow(try view.inspect())
        // The monogram Text(initial) renders when there is no photo to show.
        XCTAssertNoThrow(try view.inspect().find(text: "Q"))
    }

    func test_rendersWithAvatarURL() throws {
        let url = URL(string: "https://example.com/avatar.png")!
        let view = makeSheet(avatarURL: url)
        XCTAssertNoThrow(try view.inspect())
    }
}

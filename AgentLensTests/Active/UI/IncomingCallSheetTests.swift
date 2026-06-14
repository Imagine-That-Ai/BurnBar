import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - IncomingCallSheet avatar

/// Covers the Mercury incoming-mirror/call sheet avatar: the requesting
/// account's profile photo fills the circle when present; otherwise the view
/// falls back to the monogram (`initial`) or, when no usable name was supplied,
/// a generic person glyph.
@MainActor
final class IncomingCallSheetTests: XCTestCase {

    private func makeSheet(initial: String = "Q", avatarURL: URL?) -> IncomingCallSheet {
        IncomingCallSheet(
            pairedDeviceName: "Test iPhone",
            initial: initial,
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
        // The monogram Text(initial) renders directly when there is no photo.
        XCTAssertNoThrow(try view.inspect().find(text: "Q"))
        // No AsyncImage is created at all.
        XCTAssertThrowsError(try view.inspect().find(ViewType.AsyncImage.self))
    }

    func test_rendersPhotoBranchWhenAvatarURLProvided() throws {
        let url = URL(string: "https://example.com/avatar.png")!
        let view = makeSheet(avatarURL: url)
        // A photo URL drives the avatar through an AsyncImage. (It shows the
        // monogram only as its loading/failure fallback, exercised above.)
        XCTAssertNoThrow(try view.inspect().find(ViewType.AsyncImage.self))
    }

    func test_rendersPersonGlyphWhenNoInitialAndNoAvatar() throws {
        // Whitespace-only name means no usable monogram and no photo.
        let view = makeSheet(initial: "   ", avatarURL: nil)
        XCTAssertNoThrow(try view.inspect())
        // Falls back to the SF Symbol person glyph rather than an empty disc.
        XCTAssertNoThrow(try view.inspect().find(ViewType.Image.self))
    }
}

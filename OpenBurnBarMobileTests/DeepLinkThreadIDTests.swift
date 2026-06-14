import XCTest
@testable import OpenBurnBarMobile

// MARK: - Deep-link threadId sanitization (T-IOS-07)
//
// Locks the contract that a burnbar:// deep-link threadId is validated before it
// can scope a Firestore query / document path. Fail-closed: anything malformed
// becomes nil (open the chat tab unscoped).

final class DeepLinkThreadIDTests: XCTestCase {

    func testAcceptsPlainID() {
        XCTAssertEqual(DeepLinkThreadID.sanitize("thread_abc-123"), "thread_abc-123")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(DeepLinkThreadID.sanitize("  abc  "), "abc")
    }

    func testRejectsNilAndEmpty() {
        XCTAssertNil(DeepLinkThreadID.sanitize(nil))
        XCTAssertNil(DeepLinkThreadID.sanitize(""))
        XCTAssertNil(DeepLinkThreadID.sanitize("   "))
    }

    func testRejectsPathSeparators() {
        XCTAssertNil(DeepLinkThreadID.sanitize("users/victim/threads/1"))
        XCTAssertNil(DeepLinkThreadID.sanitize("a/b"))
    }

    func testRejectsRelativePathTokens() {
        XCTAssertNil(DeepLinkThreadID.sanitize("."))
        XCTAssertNil(DeepLinkThreadID.sanitize(".."))
    }

    func testRejectsFirestoreReservedIDs() {
        XCTAssertNil(DeepLinkThreadID.sanitize("__name__"))
        XCTAssertNil(DeepLinkThreadID.sanitize("__id__"))
    }

    func testRejectsDisallowedCharacters() {
        XCTAssertNil(DeepLinkThreadID.sanitize("abc def"))   // space
        XCTAssertNil(DeepLinkThreadID.sanitize("abc<script>"))
        XCTAssertNil(DeepLinkThreadID.sanitize("abc%2F"))    // encoded slash
        XCTAssertNil(DeepLinkThreadID.sanitize("emoji😀"))
    }

    func testRejectsOverlongID() {
        let long = String(repeating: "a", count: DeepLinkThreadID.maxLength + 1)
        XCTAssertNil(DeepLinkThreadID.sanitize(long))
    }

    func testAcceptsAtMaxLength() {
        let atMax = String(repeating: "a", count: DeepLinkThreadID.maxLength)
        XCTAssertEqual(DeepLinkThreadID.sanitize(atMax), atMax)
    }
}

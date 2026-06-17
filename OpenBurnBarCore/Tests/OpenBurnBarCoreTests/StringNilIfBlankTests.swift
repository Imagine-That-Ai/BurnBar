import XCTest
@testable import OpenBurnBarCore

final class StringNilIfBlankTests: XCTestCase {
    func testStringNilIfBlankTrimsWhitespace() {
        XCTAssertEqual("  model-id\n".nilIfBlank, "model-id")
    }

    func testStringNilIfBlankReturnsNilForBlankString() {
        XCTAssertNil(" \n\t ".nilIfBlank)
    }

    func testOptionalStringNilIfBlankTrimsWrappedValue() {
        let value: String? = "  display name  "

        XCTAssertEqual(value.nilIfBlank, "display name")
    }

    func testOptionalStringNilIfBlankReturnsNilForNilOrBlankValue() {
        let absent: String? = nil
        let blank: String? = "   "

        XCTAssertNil(absent.nilIfBlank)
        XCTAssertNil(blank.nilIfBlank)
    }
}

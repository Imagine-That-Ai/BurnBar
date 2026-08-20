import XCTest
@testable import OpenBurnBarMedia

final class ContentBlake3KATTests: XCTestCase {
    func testOfficialEmptyAndAbcVectors() {
        XCTAssertEqual(
            ContentBlake3.hash(Data()),
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        )
        XCTAssertEqual(
            ContentBlake3.hash(Data("abc".utf8)),
            "6437b3ac38465133ffb63b75273a8db548ba6158e3c9183084760a73c7ed31c0"
        )
    }

    func testTicketsAreNotHashes() {
        XCTAssertThrowsError(try ContentBlake3.parse("blob1faketicket"))
        XCTAssertThrowsError(try ContentBlake3.parse("ticket.hash()"))
    }

    func testHashFileMatchesHash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try ContentBlake3.hashFile(at: url), ContentBlake3.hash(Data("abc".utf8)))
    }
}

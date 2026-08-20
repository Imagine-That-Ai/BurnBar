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
            "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
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

    func testParseBlake3PrefixAndMultiChunkInput() throws {
        let digest = ContentBlake3.hash(Data("abc".utf8))
        XCTAssertEqual(try ContentBlake3.parse("blake3:" + digest), digest)
        XCTAssertEqual(try ContentBlake3.parse(digest.uppercased()), digest)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try ContentBlake3.hashFile(at: missing))
        let chunked = Data(repeating: 0x61, count: 2500)
        let fromMemory = ContentBlake3.hash(chunked)
        XCTAssertEqual(fromMemory.count, 64)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try chunked.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try ContentBlake3.hashFile(at: url), fromMemory)
    }
}

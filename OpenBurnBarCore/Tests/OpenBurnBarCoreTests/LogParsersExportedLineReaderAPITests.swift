import Foundation
import OpenBurnBarLogParsers
import XCTest

final class LogParsersExportedLineReaderAPITests: XCTestCase {
    func testLineReaderAPIIsVisibleThroughLogParsersProduct() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("first\nsecond\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let lines: BufferedLineSequence = handle.readAllUTF8Lines()
        XCTAssertEqual(Array(lines), ["first", "second"])
    }
}

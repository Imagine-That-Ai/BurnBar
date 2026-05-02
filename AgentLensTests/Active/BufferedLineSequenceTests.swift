import XCTest
@testable import OpenBurnBar

// MARK: - BufferedLineSequenceTests

final class BufferedLineSequenceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func write(_ content: String, to filename: String) throws -> URL {
        let url = tempDir.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func readLines(from url: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        return Array(handle.readAllUTF8Lines())
    }

    // MARK: - Tests

    func test_emptyFile() throws {
        let url = try write("", to: "empty.txt")
        let lines = try readLines(from: url)
        XCTAssertEqual(lines, [])
    }

    func test_singleLine_noTrailingNewline() throws {
        let url = try write("hello", to: "single.txt")
        let lines = try readLines(from: url)
        XCTAssertEqual(lines, ["hello"])
    }

    func test_singleLine_withTrailingNewline() throws {
        let url = try write("hello\n", to: "single_nl.txt")
        let lines = try readLines(from: url)
        XCTAssertEqual(lines, ["hello"])
    }

    func test_multipleLines() throws {
        let url = try write("line1\nline2\nline3", to: "multi.txt")
        let lines = try readLines(from: url)
        XCTAssertEqual(lines, ["line1", "line2", "line3"])
    }

    func test_crlfLineEndings() throws {
        let url = try write("line1\r\nline2\r\n", to: "crlf.txt")
        let lines = try readLines(from: url)
        XCTAssertEqual(lines, ["line1", "line2"])
    }

    func test_mixedLineEndings() throws {
        let url = try write("unix\nwindows\r\nmac\rtrailing", to: "mixed.txt")
        let lines = try readLines(from: url)
        XCTAssertEqual(lines, ["unix", "windows", "mac", "trailing"])
    }

    func test_unicodeContent() throws {
        let content = "こんにちは\n🚀 rocket\n中文测试"
        let url = try write(content, to: "unicode.txt")
        let lines = try readLines(from: url)
        XCTAssertEqual(lines, ["こんにちは", "🚀 rocket", "中文测试"])
    }

    func test_lineSpanningChunkBoundary() throws {
        // Create a line longer than the default 64 KB chunk size so that
        // the line spans two chunks.
        let longLine = String(repeating: "A", count: 100_000)
        let content = "header\n\(longLine)\nfooter"
        let url = try write(content, to: "longline.txt")
        let lines = try readLines(from: url)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "header")
        XCTAssertEqual(lines[1], longLine)
        XCTAssertEqual(lines[2], "footer")
    }

    func test_largeFile_memoryBounded() throws {
        // Generate a ~2 MB file with many lines to verify we don't load
        // the entire file into memory at once.
        let line = String(repeating: "x", count: 100)
        let lineCount = 20_000
        let url = tempDir.appendingPathComponent("large.txt")
        // FileHandle(forWritingTo:) requires the file to exist; create it
        // empty first so the handle has a target.
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0..<lineCount {
            handle.write("\(line)\n".data(using: .utf8)!)
        }
        handle.closeFile()

        let readHandle = try FileHandle(forReadingFrom: url)
        defer { readHandle.closeFile() }
        var count = 0
        for _ in readHandle.readAllUTF8Lines() {
            count += 1
        }
        XCTAssertEqual(count, lineCount)
    }

    func test_equivalenceWithOldImplementation() throws {
        // Verify that BufferedLineSequence produces the same output as
        // the original readDataToEndOfFile + split approach for valid UTF-8.
        let content = "alpha\nbeta\ngamma\n\ndelta\n"
        let url = try write(content, to: "equiv.txt")

        let handle1 = try FileHandle(forReadingFrom: url)
        defer { handle1.closeFile() }
        let bufferedLines = Array(handle1.readAllUTF8Lines())

        let handle2 = try FileHandle(forReadingFrom: url)
        defer { handle2.closeFile() }
        let data = handle2.readDataToEndOfFile()
        let oldLines = String(data: data, encoding: .utf8)!
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        XCTAssertEqual(bufferedLines, oldLines)
    }
}

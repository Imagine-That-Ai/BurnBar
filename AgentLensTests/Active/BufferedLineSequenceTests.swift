import OpenBurnBarCore
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

    // MARK: - Round-4 perf sweep: oversized line guard

    func test_oversizedLine_isSkipped() throws {
        // Create a file with a line that exceeds maxLineBytes.
        // maxLineBytes = 100, chunkSize = 32.
        let oversized = String(repeating: "B", count: 500)
        let content = "before\n\(oversized)\nafter"
        let url = try write(content, to: "oversized.txt")

        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let seq = BufferedLineSequence(fileHandle: handle, chunkSize: 32, maxLineBytes: 100)
        let lines = Array(seq)

        // The oversized line should be skipped; "before" and "after" remain.
        XCTAssertEqual(lines, ["before", "after"])
    }

    func test_oversizedLine_atEOF_isSkipped() throws {
        // Oversized line is the last line (no trailing newline).
        let oversized = String(repeating: "C", count: 500)
        let content = "ok\n\(oversized)"
        let url = try write(content, to: "oversized_eof.txt")

        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let seq = BufferedLineSequence(fileHandle: handle, chunkSize: 32, maxLineBytes: 100)
        let lines = Array(seq)

        XCTAssertEqual(lines, ["ok"])
    }

    func test_oversizedLine_remainsMemoryBoundedWhileSkipping() throws {
        let oversized = String(repeating: "D", count: 20_000)
        let content = "before\n\(oversized)\nafter"
        let url = try write(content, to: "oversized_bounded.txt")

        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let seq = BufferedLineSequence(fileHandle: handle, chunkSize: 512, maxLineBytes: 1_024)
        let lines = Array(seq)

        XCTAssertEqual(lines, ["before", "after"])
    }

    func test_normalLines_unaffectedByMaxLineBytes() throws {
        // Verify that normal-sized lines are not affected by the guard.
        let content = "line1\nline2\nline3\n"
        let url = try write(content, to: "normal.txt")

        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let seq = BufferedLineSequence(fileHandle: handle, chunkSize: 16, maxLineBytes: 100)
        let lines = Array(seq)

        XCTAssertEqual(lines, ["line1", "line2", "line3"])
    }

    // MARK: - BufferedLineReader (offset-aware engine for incremental scanners)

    /// Drains a reader into `(text, isTerminated, endOffset)` tuples.
    private func drain(_ reader: BufferedLineReader) -> [(text: String, isTerminated: Bool, endOffset: Int64)] {
        var lines: [(String, Bool, Int64)] = []
        while let line = reader.nextLine() {
            lines.append((line.text, line.isTerminated, line.endOffset))
        }
        return lines
    }

    private func makeReader(
        for url: URL,
        startOffset: Int64 = 0,
        chunkSize: Int = 8,
        maxLineBytes: Int = 16 * 1024 * 1024
    ) throws -> (handle: FileHandle, reader: BufferedLineReader) {
        let handle = try FileHandle(forReadingFrom: url)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }
        let reader = BufferedLineReader(
            fileHandle: handle,
            startOffset: startOffset,
            chunkSize: chunkSize,
            maxLineBytes: maxLineBytes
        )
        return (handle, reader)
    }

    func test_reader_terminatedLineEndOffsets_acrossChunkBoundaries() throws {
        // Byte layout: "ab\n" ends at 3, "cdef\n" ends at 8, "ghij\n" ends at 13.
        // chunkSize 8 forces "cdef\n" to span the first chunk boundary.
        let url = try write("ab\ncdef\nghij\n", to: "reader_offsets.txt")

        let (handle, reader) = try makeReader(for: url, chunkSize: 8)
        defer { handle.closeFile() }
        let lines = drain(reader)

        XCTAssertEqual(lines.map(\.text), ["ab", "cdef", "ghij"])
        XCTAssertEqual(lines.map(\.isTerminated), [true, true, true])
        XCTAssertEqual(lines.map(\.endOffset), [3, 8, 13])
    }

    func test_reader_crlf_fullyBuffered_endOffsetPastLineFeed() throws {
        // With a chunk large enough to hold the whole file, a \r\n pair is
        // consumed as one separator: "a\r\n" ends at 3, "b\n" ends at 5.
        let url = try write("a\r\nb\n", to: "reader_crlf.txt")

        let (handle, reader) = try makeReader(for: url, chunkSize: 1024)
        defer { handle.closeFile() }
        let lines = drain(reader)

        XCTAssertEqual(lines.map(\.text), ["a", "b"])
        XCTAssertEqual(lines.map(\.endOffset), [3, 5])
    }

    func test_reader_crlfSplitAcrossChunkBoundary_isResumeSafe() throws {
        // chunkSize 4 splits each \r\n pair across a chunk boundary:
        //   bytes: a b c \r | \n d e f | \r \n X
        // The reader must yield exactly ["abc", "def", "X"] (no phantom empty
        // lines), and resuming from every terminated endOffset must reproduce
        // exactly the remaining lines (the incremental-scan contract).
        let content = "abc\r\ndef\r\nX"
        let url = try write(content, to: "reader_crlf_split.txt")

        let (handle, reader) = try makeReader(for: url, chunkSize: 4)
        defer { handle.closeFile() }
        let lines = drain(reader)

        XCTAssertEqual(lines.map(\.text), ["abc", "def", "X"])
        XCTAssertEqual(lines.map(\.isTerminated), [true, true, false])
        XCTAssertEqual(lines.last?.endOffset, Int64(content.utf8.count))

        // Resume from each terminated line's endOffset: the tail must match.
        for (index, line) in lines.enumerated() where line.isTerminated {
            let (resumedHandle, resumedReader) = try makeReader(
                for: url,
                startOffset: line.endOffset,
                chunkSize: 4
            )
            defer { resumedHandle.closeFile() }
            let resumed = drain(resumedReader)
            let expected = Array(lines.suffix(from: index + 1))
            XCTAssertEqual(resumed.map(\.text), expected.map(\.text), "resume after line \(index)")
            XCTAssertEqual(resumed.map(\.endOffset), expected.map(\.endOffset), "resume after line \(index)")
        }
    }

    func test_reader_unterminatedFinalLine_flagsAndFileSizeOffset() throws {
        let content = "one\ntwo"
        let url = try write(content, to: "reader_unterminated.txt")

        let (handle, reader) = try makeReader(for: url, chunkSize: 8)
        defer { handle.closeFile() }
        let lines = drain(reader)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "one")
        XCTAssertTrue(lines[0].isTerminated)
        XCTAssertEqual(lines[0].endOffset, 4)
        XCTAssertEqual(lines[1].text, "two")
        XCTAssertFalse(lines[1].isTerminated)
        XCTAssertEqual(lines[1].endOffset, Int64(content.utf8.count))
        XCTAssertNil(reader.nextLine())
    }

    func test_reader_oversizedLineSkip_keepsSubsequentOffsetsCorrect() throws {
        // "ok\n" ends at 3; the oversized run (25×Z + \n) ends at 29;
        // "tail\n" ends at 34. maxLineBytes 10 < chunkSize forces the
        // mid-line buffer-overflow skip path (buffer > max with no separator).
        let oversized = String(repeating: "Z", count: 25)
        let content = "ok\n\(oversized)\ntail\n"
        let url = try write(content, to: "reader_oversized_offsets.txt")

        let (handle, reader) = try makeReader(for: url, chunkSize: 8, maxLineBytes: 10)
        defer { handle.closeFile() }
        let lines = drain(reader)

        XCTAssertEqual(lines.map(\.text), ["ok", "tail"])
        XCTAssertEqual(lines.map(\.endOffset), [3, 34])

        // Resuming from the line before the oversized run must skip it again
        // and land on "tail" with the same absolute endOffset.
        let (resumedHandle, resumedReader) = try makeReader(
            for: url,
            startOffset: 3,
            chunkSize: 8,
            maxLineBytes: 10
        )
        defer { resumedHandle.closeFile() }
        let resumed = drain(resumedReader)
        XCTAssertEqual(resumed.map(\.text), ["tail"])
        XCTAssertEqual(resumed.map(\.endOffset), [34])
    }

    func test_reader_bufferedOversizedLine_isSkippedWithCorrectFollowingOffset() throws {
        // Oversized line fully buffered in one chunk (chunk > line > max):
        // "abcdefgh\n" (9 bytes) skipped, "xy\n" ends at 12.
        let url = try write("abcdefgh\nxy\n", to: "reader_oversized_buffered.txt")

        let (handle, reader) = try makeReader(for: url, chunkSize: 1024, maxLineBytes: 5)
        defer { handle.closeFile() }
        let lines = drain(reader)

        XCTAssertEqual(lines.map(\.text), ["xy"])
        XCTAssertEqual(lines.map(\.endOffset), [12])
    }

    func test_reader_skipsEmptyLines_offsetsStillAbsolute() throws {
        // "a\n" ends at 2; two empty lines are skipped; "b\n" ends at 6.
        let url = try write("a\n\n\nb\n", to: "reader_empty_lines.txt")

        let (handle, reader) = try makeReader(for: url, chunkSize: 8)
        defer { handle.closeFile() }
        let lines = drain(reader)

        XCTAssertEqual(lines.map(\.text), ["a", "b"])
        XCTAssertEqual(lines.map(\.endOffset), [2, 6])
    }

    func test_reader_resumeFromPreviousEndOffset_matchesRemainingLines() throws {
        // The incremental-scanner resume contract: seek a fresh handle to a
        // previously returned endOffset, construct a reader with the same
        // startOffset, and the remaining lines (text + offsets) must match
        // the tail of a full scan exactly.
        let content = "alpha\nbeta\ngamma\ndelta\n"
        let url = try write(content, to: "reader_resume.txt")

        let (fullHandle, fullReader) = try makeReader(for: url, chunkSize: 8)
        defer { fullHandle.closeFile() }
        let fullLines = drain(fullReader)
        XCTAssertEqual(fullLines.map(\.text), ["alpha", "beta", "gamma", "delta"])

        let resumePoint = fullLines[1] // "beta"
        let (resumedHandle, resumedReader) = try makeReader(
            for: url,
            startOffset: resumePoint.endOffset,
            chunkSize: 8
        )
        defer { resumedHandle.closeFile() }
        let resumedLines = drain(resumedReader)

        XCTAssertEqual(resumedLines.map(\.text), ["gamma", "delta"])
        XCTAssertEqual(
            resumedLines.map(\.endOffset),
            Array(fullLines.suffix(2)).map(\.endOffset)
        )

        // Resuming from the final endOffset yields nothing.
        let (eofHandle, eofReader) = try makeReader(
            for: url,
            startOffset: fullLines.last!.endOffset,
            chunkSize: 8
        )
        defer { eofHandle.closeFile() }
        XCTAssertNil(eofReader.nextLine())
    }
}

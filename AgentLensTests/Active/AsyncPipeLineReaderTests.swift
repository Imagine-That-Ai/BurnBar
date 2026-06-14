import XCTest
@testable import OpenBurnBar

/// Direct coverage for `AsyncPipeLineReader` — the non-blocking `Pipe` line
/// reader whose `ReaderState` was converted from a hand-rolled `NSLock` to a
/// `Locked<BufferState>` box for genuine `Sendable` conformance. These tests
/// prove the conversion preserved behaviour: full-line draining at scale across
/// many dispatch-source read events, line reassembly across split writes, and
/// the trailing-partial-line flush at EOF.
final class AsyncPipeLineReaderTests: XCTestCase {
    /// 8 000 newline-delimited lines (~80 KB, far larger than the 8 KB read
    /// buffer) plus a trailing partial line — proves every line is yielded once,
    /// in order, across many read events, and the partial tail is flushed on EOF.
    func test_drainsAllLinesInOrderAcrossManyReadEvents() async throws {
        let pipe = Pipe()
        let reader = AsyncPipeLineReader(pipe: pipe)
        let writeHandle = pipe.fileHandleForWriting

        let lineCount = 8_000
        // Writer runs concurrently so the reader drains as the pipe fills
        // (avoids the OS pipe-buffer back-pressure deadlock).
        Task.detached {
            for index in 0..<lineCount {
                try? writeHandle.write(contentsOf: Data("line-\(index)\n".utf8))
            }
            // No trailing newline → exercises `flushRemaining` at EOF.
            try? writeHandle.write(contentsOf: Data("partial-tail-no-newline".utf8))
            try? writeHandle.close()
        }

        var received: [String] = []
        for try await line in reader.lines() {
            received.append(line)
        }

        XCTAssertEqual(received.count, lineCount + 1, "all full lines plus the flushed partial tail")
        XCTAssertEqual(received.first, "line-0")
        XCTAssertEqual(received[lineCount / 2], "line-\(lineCount / 2)")
        XCTAssertEqual(received[lineCount - 1], "line-\(lineCount - 1)")
        XCTAssertEqual(received.last, "partial-tail-no-newline")
    }

    /// A logical line split across multiple writes (no newline in the first
    /// chunk) must be reassembled — guards the buffer-accumulation path.
    func test_reassemblesLineSplitAcrossWrites() async throws {
        let pipe = Pipe()
        let reader = AsyncPipeLineReader(pipe: pipe)
        let writeHandle = pipe.fileHandleForWriting

        Task.detached {
            try? writeHandle.write(contentsOf: Data("hello, ".utf8))   // no newline yet
            try? writeHandle.write(contentsOf: Data("world\n".utf8))    // completes line 1
            try? writeHandle.write(contentsOf: Data("second\n".utf8))
            try? writeHandle.close()
        }

        var received: [String] = []
        for try await line in reader.lines() {
            received.append(line)
        }

        XCTAssertEqual(received, ["hello, world", "second"])
    }

    /// Trailing `\r\n` (CRLF) and bare `\n` are both stripped — the reader
    /// promises CR/LF-trimmed lines.
    func test_stripsTrailingCarriageReturnAndNewline() async throws {
        let pipe = Pipe()
        let reader = AsyncPipeLineReader(pipe: pipe)
        let writeHandle = pipe.fileHandleForWriting

        Task.detached {
            try? writeHandle.write(contentsOf: Data("crlf-line\r\n".utf8))
            try? writeHandle.write(contentsOf: Data("lf-line\n".utf8))
            try? writeHandle.close()
        }

        var received: [String] = []
        for try await line in reader.lines() {
            received.append(line)
        }

        XCTAssertEqual(received, ["crlf-line", "lf-line"])
    }
}

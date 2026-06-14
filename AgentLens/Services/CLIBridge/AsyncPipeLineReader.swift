import Foundation
import OpenBurnBarCore

/// Asynchronous, non-blocking line reader for `Pipe` stdout/stderr.
///
/// Replaces the synchronous `FileHandle.readLine()` byte-at-a-time loop that
/// blocks the cooperative thread pool and prevents Swift cancellation from
/// being checked. Uses a GCD dispatch read source so data arrives
/// asynchronously; partial lines are buffered internally until a newline
/// arrives. Lines are yielded to an `AsyncThrowingStream` that can be
/// iterated with `for try await`, giving cooperative cancellation a chance
/// to run between lines.
///
/// The read source delivers data in chunks (up to `bufferSize` bytes per
/// event), avoiding the 1-byte-per-syscall overhead of the old
/// `FileHandle.readLine()` implementation. This is especially important for
/// Claude Code's `stream-json --verbose` mode, which emits 8+ KB init lines.
final class AsyncPipeLineReader: Sendable {
    private let pipe: Pipe
    private let fd: Int32

    init(pipe: Pipe) {
        self.pipe = pipe
        self.fd = pipe.fileHandleForReading.fileDescriptor
    }

    /// Returns an async stream of newline-delimited UTF-8 lines.
    /// Lines have trailing `\r` and `\n` stripped. The stream finishes
    /// when the pipe reaches EOF or the stream consumer cancels iteration.
    func lines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let state = ReaderState()

            let queue = DispatchQueue(label: "com.openburnbar.asynclinereader.\(self.fd)", qos: .userInitiated)
            let source = DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: queue)

            // 8 KB read buffer — comfortably fits Claude's large NDJSON init
            // lines (typically 6-10 KB) in a single read syscall.
            let bufferSize = 8192

            source.setEventHandler { [state, fd] in
                var readBuffer = [UInt8](repeating: 0, count: bufferSize)
                let bytesRead = readBuffer.withUnsafeMutableBytes { ptr in
                    read(fd, ptr.baseAddress, bufferSize)
                }

                guard bytesRead > 0 else {
                    // 0 = EOF, -1 = error. Either way, stop reading.
                    source.cancel()
                    return
                }

                state.appendAndYieldLines(Data(readBuffer[0..<bytesRead]), continuation: continuation)
            }

            source.setCancelHandler { [state, pipe] in
                // Flush remaining buffer as final line if non-empty.
                state.flushRemaining(into: continuation)
                try? pipe.fileHandleForReading.close() // try?-ok(handle teardown)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                source.cancel()
            }

            source.resume()
        }
    }
}

// MARK: - Thread-safe buffer state

private final class ReaderState: Sendable {
    /// Mutable buffer state held in a `Sendable` lock box. This is the genuine
    /// `Sendable` conformance (no `@unchecked`): the buffer and its scan offset
    /// are only ever touched under `Locked`, which the compiler can verify.
    private struct BufferState: Sendable {
        var buffer = Data()
        /// Tracks the search start offset so we don't re-scan bytes we've
        /// already confirmed don't contain a newline.
        var searchOffset = 0
    }

    private let state = Locked(BufferState())

    /// Appends raw bytes and yields all complete lines found in the buffer.
    /// Called serially from the GCD dispatch source event handler. Lines are
    /// extracted under the lock and yielded *after* releasing it, so the
    /// continuation never runs while the lock is held.
    func appendAndYieldLines(_ data: Data, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let lines = state.withLock { state -> [String] in
            state.buffer.append(data)
            var extracted: [String] = []
            while true {
                let searchRange = state.searchOffset..<state.buffer.count
                guard let offset = state.buffer.range(of: Data([0x0A]), options: [], in: searchRange)?.lowerBound else {
                    state.searchOffset = state.buffer.count
                    break
                }
                let lineData = state.buffer.subdata(in: 0..<offset)
                state.buffer.removeFirst(offset + 1)
                state.searchOffset = 0
                if let line = String(data: lineData, encoding: .utf8) {
                    extracted.append(line.trimmingCharacters(in: .newlines))
                }
            }
            return extracted
        }

        for line in lines {
            continuation.yield(line)
        }
    }

    /// Flushes remaining buffered data as a final line. Called from the
    /// cancel handler, which runs after the source is fully cancelled.
    func flushRemaining(into continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let remaining = state.withLock { state -> Data in
            let remaining = state.buffer
            state.buffer.removeAll()
            state.searchOffset = 0
            return remaining
        }

        if !remaining.isEmpty, let line = String(data: remaining, encoding: .utf8) {
            let stripped = line.trimmingCharacters(in: .newlines)
            if !stripped.isEmpty {
                continuation.yield(stripped)
            }
        }
    }
}

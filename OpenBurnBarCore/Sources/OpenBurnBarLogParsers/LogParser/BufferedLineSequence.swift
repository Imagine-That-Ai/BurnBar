import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(CRT)
import CRT
#endif

// MARK: - Buffered Line Reader

/// An offset-aware, chunked line reader over a `FileHandle`.
///
/// This is the engine behind `BufferedLineSequence` (the `for line in …` API
/// used by log parsers) and the incremental scanners that resume large
/// append-only JSONL files from a saved byte offset.
///
/// Peak memory is bounded to ~chunk size + longest line. Consumption is
/// cursor-based: the buffer is compacted once per chunk refill instead of
/// memmoved once per line, and separators are located with `memchr`, so
/// throughput stays flat on multi-gigabyte logs (the previous per-line
/// `removeSubrange` made scanning quadratic in the buffered span and was
/// measured at single-digit MB/s on real Codex rollouts).
///
/// Line strings are decoded with `String(decoding:as:)` — pure Swift, lossy on
/// invalid UTF-8 (byte-identical results to the previous
/// `String(data:encoding:)`-with-fallback path) and, importantly, free of
/// autoreleased `NSString` bridging: parsers iterate millions of lines inside
/// one dispatch block, where autoreleased per-line garbage is never drained.
///
/// `maxLineBytes` guards against pathological single-line inputs (e.g., a
/// 100MB line with no newline). When a line exceeds the limit, the reader
/// skips to the next line boundary and drops the oversized line, preventing
/// unbounded buffer growth.
public final class BufferedLineReader {

    /// One decoded line plus the bookkeeping incremental scanners need.
    public struct Line {
        public let text: String
        /// `true` when the line ended with a separator; `false` only for a
        /// trailing unterminated line at EOF (e.g. a JSONL record still being
        /// appended by a live writer).
        public let isTerminated: Bool
        /// Absolute file offset immediately after this line's separator (or
        /// after its last byte when unterminated). Resuming a scan from the
        /// `endOffset` of the last *terminated* line re-reads nothing and
        /// misses nothing.
        public let endOffset: Int64
    }

    private let fileHandle: FileHandle
    private let chunkSize: Int
    private let maxLineBytes: Int
    private var buffer: Data
    /// Index of the first unconsumed byte in `buffer`.
    private var cursor: Int
    /// Absolute file offset of `buffer`'s first byte.
    private var baseOffset: Int64
    private var reachedEOF: Bool
    private var skippingOversizedLine: Bool

    /// - Parameter startOffset: absolute file offset the handle is already
    ///   positioned at. The reader does not seek; callers resuming mid-file
    ///   must `seek(toOffset:)` first and pass the same value here.
    public init(
        fileHandle: FileHandle,
        startOffset: Int64 = 0,
        chunkSize: Int = 256 * 1024,
        maxLineBytes: Int = 16 * 1024 * 1024
    ) {
        self.fileHandle = fileHandle
        self.chunkSize = chunkSize
        self.maxLineBytes = maxLineBytes
        self.buffer = Data()
        self.cursor = 0
        self.baseOffset = startOffset
        self.reachedEOF = false
        self.skippingOversizedLine = false
    }

    /// Returns the next non-empty line, or `nil` at end of input.
    public func nextLine() -> Line? {
        while true {
            if let separatorIndex = findSeparatorIndex() {
                let separator = buffer[separatorIndex]
                var consumeEnd = separatorIndex + 1
                if separator == 0x0D, consumeEnd < buffer.count, buffer[consumeEnd] == 0x0A {
                    consumeEnd += 1
                }
                let lineStart = cursor
                let lineLength = separatorIndex - lineStart
                let endOffset = baseOffset + Int64(consumeEnd)
                let wasSkippingOversized = skippingOversizedLine
                skippingOversizedLine = false
                cursor = consumeEnd

                // The bytes before this separator are the tail of an
                // oversized line — discard them and resume normal processing.
                if wasSkippingOversized { continue }
                guard lineLength > 0, lineLength <= maxLineBytes else { continue }

                let text = decode(range: lineStart..<separatorIndex)
                return Line(text: text, isTerminated: true, endOffset: endOffset)
            }

            if reachedEOF {
                // Yield any remaining bytes as the final (unterminated) line.
                let remaining = buffer.count - cursor
                guard remaining > 0 else { return nil }
                let lineStart = cursor
                let endOffset = baseOffset + Int64(buffer.count)
                cursor = buffer.count

                if skippingOversizedLine || remaining > maxLineBytes {
                    skippingOversizedLine = false
                    return nil // Skip the oversized final line
                }
                let text = decode(range: lineStart..<lineStart + remaining)
                return Line(text: text, isTerminated: false, endOffset: endOffset)
            }

            // No complete line buffered — compact once, then read a chunk.
            if cursor > 0 {
                buffer.removeSubrange(0..<cursor)
                baseOffset += Int64(cursor)
                cursor = 0
            }
            // `readData(ofLength:)` returns an autoreleased NSData-backed
            // Data, and `Data.append(_: Data)` on an emptied buffer ADOPTS
            // that backing instead of copying (measured: one live 256KB
            // NSData per chunk for the whole scan — footprint equal to total
            // bytes read). Copy the raw bytes explicitly so no NSData
            // representation ever outlives this pool.
            let readCount = parserAutoReleasePool { () -> Int in
                let chunk = fileHandle.readData(ofLength: chunkSize)
                chunk.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, !raw.isEmpty else { return }
                    buffer.append(base.assumingMemoryBound(to: UInt8.self), count: raw.count)
                }
                return chunk.count
            }
            if readCount == 0 {
                reachedEOF = true
                continue
            }

            // Guard against pathological single-line inputs: if the buffer
            // exceeds maxLineBytes with no separator in sight, drop it and
            // skip until the next line boundary.
            if !skippingOversizedLine, buffer.count > maxLineBytes, findSeparatorIndex() == nil {
                skippingOversizedLine = true
                baseOffset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                cursor = 0
            }
        }
    }

    /// Index of the first `\n` or `\r` at or after `cursor`, via `memchr`.
    private func findSeparatorIndex() -> Int? {
        let count = buffer.count
        guard cursor < count else { return nil }
        let searchStart = cursor
        return buffer.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress else { return nil }
            let start = base + searchStart
            let length = count - searchStart
            let newline = memchr(start, 0x0A, length).map { UnsafeRawPointer($0) }
            let carriageReturn = memchr(start, 0x0D, length).map { UnsafeRawPointer($0) }
            let found: UnsafeRawPointer?
            switch (newline, carriageReturn) {
            case (nil, nil):
                found = nil
            case let (match?, nil):
                found = match
            case let (nil, match?):
                found = match
            case let (newlineMatch?, carriageMatch?):
                found = min(newlineMatch, carriageMatch)
            }
            guard let found else { return nil }
            return searchStart + (found - start)
        }
    }

    private func decode(range: Range<Int>) -> String {
        // Decode straight out of the buffer: `subdata(in:)` would mint an
        // autoreleased NSData copy per line, which never drains in the
        // contexts parsers run in (sum over a scan ≈ every byte read).
        buffer.withUnsafeBytes { raw in
            String(decoding: UnsafeRawBufferPointer(rebasing: raw[range]), as: UTF8.self)
        }
    }
}

// MARK: - Buffered Line Sequence

/// A lazy line iterator over a `FileHandle` that reads in fixed-size chunks
/// rather than loading the entire file into memory.
///
/// This is a drop-in replacement for eagerly splitting whole files, for
/// large log files. It preserves the `for line in …` syntax while keeping
/// peak memory bounded to ~chunk size + longest line. See
/// `BufferedLineReader` for the underlying engine and its performance notes.
public struct BufferedLineSequence: Sequence {
    private let fileHandle: FileHandle
    private let chunkSize: Int
    private let maxLineBytes: Int

    public init(fileHandle: FileHandle, chunkSize: Int = 256 * 1024, maxLineBytes: Int = 16 * 1024 * 1024) {
        self.fileHandle = fileHandle
        self.chunkSize = chunkSize
        self.maxLineBytes = maxLineBytes
    }

    public func makeIterator() -> Iterator {
        Iterator(
            reader: BufferedLineReader(
                fileHandle: fileHandle,
                chunkSize: chunkSize,
                maxLineBytes: maxLineBytes
            )
        )
    }
}

// MARK: - Iterator

extension BufferedLineSequence {
    public struct Iterator: IteratorProtocol {
        private let reader: BufferedLineReader

        init(reader: BufferedLineReader) {
            self.reader = reader
        }

        public mutating func next() -> String? {
            reader.nextLine()?.text
        }
    }
}

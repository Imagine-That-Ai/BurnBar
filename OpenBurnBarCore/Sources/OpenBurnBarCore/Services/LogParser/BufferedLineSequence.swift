import Foundation

// MARK: - Buffered Line Sequence

/// A lazy line iterator over a `FileHandle` that reads in fixed-size chunks
/// rather than loading the entire file into memory.
///
/// This is a drop-in replacement for `FileHandle.readAllUTF8Lines()` for
/// large log files. It preserves the `for line in …` syntax while keeping
/// peak memory bounded to ~chunk size + longest line.
///
/// Round-4 perf sweep: `maxLineBytes` guards against pathological single-line
/// inputs (e.g., a 100MB line with no newline). When a line exceeds the limit,
/// the iterator skips to the next line boundary and returns `nil` for the
/// oversized line, preventing unbounded buffer growth.
public struct BufferedLineSequence: Sequence {
    private let fileHandle: FileHandle
    private let chunkSize: Int
    private let maxLineBytes: Int

    public init(fileHandle: FileHandle, chunkSize: Int = 64 * 1024, maxLineBytes: Int = 16 * 1024 * 1024) {
        self.fileHandle = fileHandle
        self.chunkSize = chunkSize
        self.maxLineBytes = maxLineBytes
    }

    public func makeIterator() -> Iterator {
        Iterator(fileHandle: fileHandle, chunkSize: chunkSize, maxLineBytes: maxLineBytes)
    }
}

// MARK: - Iterator

extension BufferedLineSequence {
    public struct Iterator: IteratorProtocol {
        private let fileHandle: FileHandle
        private let chunkSize: Int
        private let maxLineBytes: Int
        private var buffer: Data
        private var reachedEOF: Bool
        private var skippingOversizedLine: Bool

        init(fileHandle: FileHandle, chunkSize: Int, maxLineBytes: Int) {
            self.fileHandle = fileHandle
            self.chunkSize = chunkSize
            self.maxLineBytes = maxLineBytes
            self.buffer = Data()
            self.reachedEOF = false
            self.skippingOversizedLine = false
        }

        public mutating func next() -> String? {
            while true {
                // UTF-8 guarantees that ASCII line separators never appear
                // inside a multi-byte character, so byte splitting is safe and
                // avoids Swift.Character scanning over huge logs.
                if let separatorIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let separator = buffer[separatorIndex]
                    let lineData = buffer.prefix(upTo: separatorIndex)
                    var removeEnd = buffer.index(after: separatorIndex)
                    if separator == 0x0D,
                       removeEnd < buffer.endIndex,
                       buffer[removeEnd] == 0x0A {
                        removeEnd = buffer.index(after: removeEnd)
                    }
                    buffer.removeSubrange(..<removeEnd)

                    if skippingOversizedLine {
                        // We were skipping an oversized line. The lineData
                        // before this newline is the tail of the oversized
                        // line — discard it and resume normal processing.
                        skippingOversizedLine = false
                        continue
                    }

                    guard lineData.count <= maxLineBytes else { continue }
                    guard !lineData.isEmpty else { continue }
                    return Self.decode(lineData)
                }

                // No complete line in buffer — read the next chunk.
                if reachedEOF {
                    // Yield any remaining bytes as the final line.
                    guard !buffer.isEmpty else { return nil }
                    let finalData = buffer
                    buffer.removeAll()

                    if skippingOversizedLine || finalData.count > maxLineBytes {
                        skippingOversizedLine = false
                        return nil // Skip the oversized final line
                    }

                    return Self.decode(finalData)
                }

                let chunk = fileHandle.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    reachedEOF = true
                    continue
                }
                buffer.append(chunk)

                // Round-4 perf sweep: guard against pathological single-line
                // inputs. If the buffer exceeds maxLineBytes and no newline
                // has been found, skip the oversized line.
                if buffer.count > maxLineBytes,
                   !buffer.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
                    skippingOversizedLine = true
                    // Discard the buffer; we'll skip until the next newline.
                    buffer.removeAll()
                }
            }
        }

        private static func decode<T: Collection>(_ bytes: T) -> String where T.Element == UInt8 {
            let data = Data(bytes)
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
    }
}

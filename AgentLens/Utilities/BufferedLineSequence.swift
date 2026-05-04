import Foundation

// MARK: - Buffered Line Sequence

/// A lazy line iterator over a `FileHandle` that reads in fixed-size chunks
/// rather than loading the entire file into memory.
///
/// This is a drop-in replacement for `FileHandle.readAllUTF8Lines()` for
/// large log files. It preserves the `for line in …` syntax while keeping
/// peak memory bounded to ~chunk size + longest line.
struct BufferedLineSequence: Sequence {
    private let fileHandle: FileHandle
    private let chunkSize: Int

    init(fileHandle: FileHandle, chunkSize: Int = 64 * 1024) {
        self.fileHandle = fileHandle
        self.chunkSize = chunkSize
    }

    func makeIterator() -> Iterator {
        Iterator(fileHandle: fileHandle, chunkSize: chunkSize)
    }
}

// MARK: - Iterator

extension BufferedLineSequence {
    struct Iterator: IteratorProtocol {
        private let fileHandle: FileHandle
        private let chunkSize: Int
        private var buffer: Data
        private var reachedEOF: Bool

        init(fileHandle: FileHandle, chunkSize: Int) {
            self.fileHandle = fileHandle
            self.chunkSize = chunkSize
            self.buffer = Data()
            self.reachedEOF = false
        }

        mutating func next() -> String? {
            while true {
                // Search for a newline (0x0A) in the buffer.
                // UTF-8 guarantees that 0x0A never appears inside a multi-byte
                // character, so splitting on this byte is always safe.
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: newlineIndex)
                    buffer.removeSubrange(..<(newlineIndex + 1))

                    var line = String(data: Data(lineData), encoding: .utf8)
                        ?? String(decoding: Data(lineData), as: UTF8.self)

                    // Strip a trailing CR for \r\n compatibility.
                    if line.hasSuffix("\r") {
                        line.removeLast()
                    }

                    return line
                }

                // No complete line in buffer — read the next chunk.
                if reachedEOF {
                    // Yield any remaining bytes as the final line.
                    guard !buffer.isEmpty else { return nil }
                    let finalData = buffer
                    buffer.removeAll()
                    var line = String(data: finalData, encoding: .utf8)
                        ?? String(decoding: finalData, as: UTF8.self)
                    if line.hasSuffix("\r") {
                        line.removeLast()
                    }
                    return line
                }

                let chunk = fileHandle.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    reachedEOF = true
                    continue
                }
                buffer.append(chunk)
            }
        }
    }
}

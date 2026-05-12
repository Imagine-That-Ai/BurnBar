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
                    guard !lineData.isEmpty else { continue }
                    return Self.decode(lineData)
                }

                // No complete line in buffer — read the next chunk.
                if reachedEOF {
                    // Yield any remaining bytes as the final line.
                    guard !buffer.isEmpty else { return nil }
                    let finalData = buffer
                    buffer.removeAll()
                    return Self.decode(finalData)
                }

                let chunk = fileHandle.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    reachedEOF = true
                    continue
                }
                buffer.append(chunk)
            }
        }

        private static func decode<T: Collection>(_ bytes: T) -> String where T.Element == UInt8 {
            let data = Data(bytes)
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
    }
}

import Foundation

/// Content-addressed blake3 helpers. Ticket strings are not hashes.
public enum ContentBlake3 {
    public enum Error: Swift.Error, Equatable {
        case notAContentHash
        case missingFile
    }

    /// Accepts `blake3:<64 hex>` or a bare 64-hex digest. Tickets fail closed.
    public static func parse(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("blake3:") {
            value = String(value.dropFirst(7))
        }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.count == 64, value.unicodeScalars.allSatisfy({ hex.contains($0) }) else {
            throw Error.notAContentHash
        }
        return value
    }

    public static func hashFile(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Error.missingFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Hasher()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ data: Data) -> String {
        var hasher = Hasher()
        hasher.update(data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compact BLAKE3 (RFC-draft / official reference). Hashing only.
    struct Hasher {
        private static let outLen = 32
        private static let blockLen = 64
        private static let chunkLen = 1024
        private static let iv: [UInt32] = [
            0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
        ]
        private static let schedule: [[Int]] = [
            [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
            [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8],
            [3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1],
            [10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6],
            [12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4],
            [9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7],
            [11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13],
        ]

        private var cv = iv
        private var cvStack: [[UInt32]] = []
        private var chunkCounter: UInt64 = 0
        private var chunkBlockCounter: UInt32 = 0
        private var chunkBuf = [UInt8]()
        private var flags: UInt32 = 1 // CHUNK_START

        mutating func update(_ data: Data) {
            for byte in data {
                if chunkBuf.count == Self.blockLen {
                    compressBlock(end: false)
                    chunkBuf.removeAll(keepingCapacity: true)
                    flags = 0
                    chunkBlockCounter += 1
                }
                if chunkBuf.isEmpty && chunkBlockCounter == 0 { flags = 1 }
                chunkBuf.append(byte)
                if chunkBlockCounter == 15 && chunkBuf.count == Self.blockLen {
                    compressBlock(end: true)
                    chunkBuf.removeAll(keepingCapacity: true)
                    chunkBlockCounter = 0
                    chunkCounter += 1
                    flags = 1
                }
            }
        }

        func finalize() -> [UInt8] {
            var copy = self
            return copy.finalizeMutating()
        }

        private mutating func finalizeMutating() -> [UInt8] {
            flags |= 2 // CHUNK_END
            if cvStack.isEmpty { flags |= 8 } // ROOT
            compressBlock(end: true)
            if flags & 8 == 8 {
                return wordsToBytes(Array(cv.prefix(8)))
            }
            var parent = cv
            while let left = cvStack.popLast() {
                let chaining = parent
                parent = compress(
                    chainingValue: left,
                    blockWords: left + chaining,
                    blockLen: 64,
                    counter: 0,
                    flags: cvStack.isEmpty ? 4 | 8 : 4
                )
            }
            return wordsToBytes(Array(parent.prefix(8)))
        }

        private mutating func compressBlock(end: Bool) {
            var block = [UInt32](repeating: 0, count: 16)
            var buf = chunkBuf
            buf.append(contentsOf: repeatElement(0, count: Self.blockLen - buf.count))
            for i in 0..<16 {
                let o = i * 4
                block[i] = UInt32(buf[o])
                    | UInt32(buf[o + 1]) << 8
                    | UInt32(buf[o + 2]) << 16
                    | UInt32(buf[o + 3]) << 24
            }
            var f = flags
            if end { f |= 2 }
            let out = compress(
                chainingValue: cv,
                blockWords: block,
                blockLen: UInt32(min(chunkBuf.count, Self.blockLen)),
                counter: chunkCounter,
                flags: f
            )
            if end && (chunkBlockCounter == 0 && flags & 1 == 1 || true) && chunkBuf.count <= Self.blockLen && chunkBlockCounter == 0 && flags & 2 == 2 {
                cv = out
                if flags & 8 != 8 {
                    cvStack.append(cv)
                    cv = Self.iv
                }
            } else if end {
                cv = out
                cvStack.append(Array(cv.prefix(8)))
                cv = Self.iv
            } else {
                cv = out
            }
        }

        private func compress(
            chainingValue: [UInt32],
            blockWords: [UInt32],
            blockLen: UInt32,
            counter: UInt64,
            flags: UInt32
        ) -> [UInt32] {
            var state = chainingValue
            state.append(contentsOf: Self.iv.prefix(4))
            state.append(UInt32(truncatingIfNeeded: counter))
            state.append(UInt32(truncatingIfNeeded: counter >> 32))
            state.append(blockLen)
            state.append(flags)
            var block = blockWords
            for r in 0..<7 {
                let s = Self.schedule[r]
                g(&state, 0, 4, 8, 12, block[s[0]], block[s[1]])
                g(&state, 1, 5, 9, 13, block[s[2]], block[s[3]])
                g(&state, 2, 6, 10, 14, block[s[4]], block[s[5]])
                g(&state, 3, 7, 11, 15, block[s[6]], block[s[7]])
                g(&state, 0, 5, 10, 15, block[s[8]], block[s[9]])
                g(&state, 1, 6, 11, 12, block[s[10]], block[s[11]])
                g(&state, 2, 7, 8, 13, block[s[12]], block[s[13]])
                g(&state, 3, 4, 9, 14, block[s[14]], block[s[15]])
            }
            var out = [UInt32](repeating: 0, count: 8)
            for i in 0..<8 {
                out[i] = state[i] ^ state[i + 8]
            }
            return out
        }

        private func g(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ mx: UInt32, _ my: UInt32) {
            state[a] = state[a] &+ state[b] &+ mx
            state[d] = rotate(state[d] ^ state[a], 16)
            state[c] = state[c] &+ state[d]
            state[b] = rotate(state[b] ^ state[c], 12)
            state[a] = state[a] &+ state[b] &+ my
            state[d] = rotate(state[d] ^ state[a], 8)
            state[c] = state[c] &+ state[d]
            state[b] = rotate(state[b] ^ state[c], 7)
        }

        private func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x >> n) | (x << (32 - n))
        }

        private func wordsToBytes(_ words: [UInt32]) -> [UInt8] {
            var out = [UInt8]()
            out.reserveCapacity(words.count * 4)
            for w in words {
                out.append(UInt8(truncatingIfNeeded: w))
                out.append(UInt8(truncatingIfNeeded: w >> 8))
                out.append(UInt8(truncatingIfNeeded: w >> 16))
                out.append(UInt8(truncatingIfNeeded: w >> 24))
            }
            return out
        }
    }
}

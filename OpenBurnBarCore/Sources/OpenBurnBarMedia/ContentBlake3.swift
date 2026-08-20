import Foundation

/// Content-addressed BLAKE3. Ticket strings are not hashes.
/// P2P publish/land uses iroh `ticket.hash()` / `stats.blake3Hash`.
/// Cloud FileSeal hashes opened plaintext with this official-reference hasher.
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
        return hasher.finalizeHex()
    }

    public static func hash(_ data: Data) -> String {
        var hasher = Hasher()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    /// Official BLAKE3 reference (hashing only).
    /// https://github.com/BLAKE3-team/BLAKE3/blob/master/reference_impl/reference_impl.rs
    public struct Hasher {
        static let outLen = 32
        static let blockLen = 64
        static let chunkLen = 1024
        static let chunkStart: UInt32 = 1 << 0
        static let chunkEnd: UInt32 = 1 << 1
        static let parent: UInt32 = 1 << 2
        static let root: UInt32 = 1 << 3
        static let iv: [UInt32] = [
            0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
        ]
        static let msgPermutation: [Int] = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

        private var chunkState: ChunkState
        private var keyWords: [UInt32]
        private var cvStack: [[UInt32]] = []
        private var flags: UInt32 = 0

        public init() {
            keyWords = Self.iv
            chunkState = ChunkState(keyWords: Self.iv, chunkCounter: 0, flags: 0)
        }

        public mutating func update(_ data: Data) {
            var input = [UInt8](data)
            while !input.isEmpty {
                if chunkState.len == Self.chunkLen {
                    let chunkCV = chunkState.output().chainingValue()
                    let totalChunks = chunkState.chunkCounter + 1
                    addChunkChainingValue(chunkCV, totalChunks: totalChunks)
                    chunkState = ChunkState(keyWords: keyWords, chunkCounter: totalChunks, flags: flags)
                }
                let want = Self.chunkLen - chunkState.len
                let take = min(want, input.count)
                chunkState.update(Array(input.prefix(take)))
                input.removeFirst(take)
            }
        }

        public func finalizeHex() -> String {
            finalize().map { String(format: "%02x", $0) }.joined()
        }

        public func finalize() -> [UInt8] {
            var output = chunkState.output()
            var remaining = cvStack.count
            while remaining > 0 {
                remaining -= 1
                output = Self.parentOutput(
                    left: cvStack[remaining],
                    right: output.chainingValue(),
                    keyWords: keyWords,
                    flags: flags
                )
            }
            return output.rootOutputBytes()
        }

        private mutating func addChunkChainingValue(_ newCV: [UInt32], totalChunks: UInt64) {
            var cv = newCV
            var total = totalChunks
            while total & 1 == 0 {
                guard let left = cvStack.popLast() else { break }
                cv = Self.parentOutput(left: left, right: cv, keyWords: keyWords, flags: flags).chainingValue()
                total >>= 1
            }
            cvStack.append(cv)
        }

        private struct ChunkState {
            var chainingValue: [UInt32]
            var chunkCounter: UInt64
            var block: [UInt8]
            var blockLen: Int
            var blocksCompressed: Int
            var flags: UInt32

            init(keyWords: [UInt32], chunkCounter: UInt64, flags: UInt32) {
                self.chainingValue = keyWords
                self.chunkCounter = chunkCounter
                self.block = [UInt8](repeating: 0, count: Hasher.blockLen)
                self.blockLen = 0
                self.blocksCompressed = 0
                self.flags = flags
            }

            var len: Int { Hasher.blockLen * blocksCompressed + blockLen }

            var startFlag: UInt32 { blocksCompressed == 0 ? Hasher.chunkStart : 0 }

            mutating func update(_ input: [UInt8]) {
                var remaining = input
                while !remaining.isEmpty {
                    if blockLen == Hasher.blockLen {
                        chainingValue = Hasher.first8(
                            Hasher.compress(
                                chainingValue: chainingValue,
                                blockWords: Hasher.wordsFrom(block),
                                counter: chunkCounter,
                                blockLen: UInt32(Hasher.blockLen),
                                flags: flags | startFlag
                            )
                        )
                        blocksCompressed += 1
                        block = [UInt8](repeating: 0, count: Hasher.blockLen)
                        blockLen = 0
                    }
                    let take = min(Hasher.blockLen - blockLen, remaining.count)
                    for i in 0..<take {
                        block[blockLen + i] = remaining[i]
                    }
                    blockLen += take
                    remaining.removeFirst(take)
                }
            }

            func output() -> Output {
                Output(
                    inputChainingValue: chainingValue,
                    blockWords: Hasher.wordsFrom(block),
                    counter: chunkCounter,
                    blockLen: UInt32(blockLen),
                    flags: flags | startFlag | Hasher.chunkEnd
                )
            }
        }

        private struct Output {
            var inputChainingValue: [UInt32]
            var blockWords: [UInt32]
            var counter: UInt64
            var blockLen: UInt32
            var flags: UInt32

            func chainingValue() -> [UInt32] {
                Hasher.first8(
                    Hasher.compress(
                        chainingValue: inputChainingValue,
                        blockWords: blockWords,
                        counter: counter,
                        blockLen: blockLen,
                        flags: flags
                    )
                )
            }

            func rootOutputBytes() -> [UInt8] {
                let words = Hasher.compress(
                    chainingValue: inputChainingValue,
                    blockWords: blockWords,
                    counter: 0,
                    blockLen: blockLen,
                    flags: flags | Hasher.root
                )
                return Hasher.wordsToBytes(Array(words.prefix(8)))
            }
        }

        private static func parentOutput(
            left: [UInt32],
            right: [UInt32],
            keyWords: [UInt32],
            flags: UInt32
        ) -> Output {
            var block = left
            block.append(contentsOf: right)
            while block.count < 16 { block.append(0) }
            return Output(
                inputChainingValue: keyWords,
                blockWords: block,
                counter: 0,
                blockLen: UInt32(blockLen),
                flags: flags | parent
            )
        }

        private static func first8(_ words: [UInt32]) -> [UInt32] {
            Array(words.prefix(8))
        }

        private static func wordsFrom(_ bytes: [UInt8]) -> [UInt32] {
            var block = bytes
            if block.count < blockLen {
                block.append(contentsOf: repeatElement(0, count: blockLen - block.count))
            }
            var words = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = i * 4
                words[i] = UInt32(block[o])
                    | UInt32(block[o + 1]) << 8
                    | UInt32(block[o + 2]) << 16
                    | UInt32(block[o + 3]) << 24
            }
            return words
        }

        private static func wordsToBytes(_ words: [UInt32]) -> [UInt8] {
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

        private static func compress(
            chainingValue: [UInt32],
            blockWords: [UInt32],
            counter: UInt64,
            blockLen: UInt32,
            flags: UInt32
        ) -> [UInt32] {
            var state = [UInt32](repeating: 0, count: 16)
            for i in 0..<8 { state[i] = chainingValue[i] }
            for i in 0..<4 { state[8 + i] = iv[i] }
            state[12] = UInt32(truncatingIfNeeded: counter)
            state[13] = UInt32(truncatingIfNeeded: counter >> 32)
            state[14] = blockLen
            state[15] = flags
            var block = blockWords
            if block.count < 16 {
                block.append(contentsOf: repeatElement(0, count: 16 - block.count))
            }
            for _ in 0..<7 {
                round(&state, block)
                permute(&block)
            }
            for i in 0..<8 {
                state[i] ^= state[i + 8]
                state[i + 8] ^= chainingValue[i]
            }
            return state
        }

        private static func round(_ state: inout [UInt32], _ m: [UInt32]) {
            g(&state, 0, 4, 8, 12, m[0], m[1])
            g(&state, 1, 5, 9, 13, m[2], m[3])
            g(&state, 2, 6, 10, 14, m[4], m[5])
            g(&state, 3, 7, 11, 15, m[6], m[7])
            g(&state, 0, 5, 10, 15, m[8], m[9])
            g(&state, 1, 6, 11, 12, m[10], m[11])
            g(&state, 2, 7, 8, 13, m[12], m[13])
            g(&state, 3, 4, 9, 14, m[14], m[15])
        }

        private static func permute(_ m: inout [UInt32]) {
            var next = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 { next[i] = m[msgPermutation[i]] }
            m = next
        }

        private static func g(
            _ state: inout [UInt32],
            _ a: Int,
            _ b: Int,
            _ c: Int,
            _ d: Int,
            _ mx: UInt32,
            _ my: UInt32
        ) {
            state[a] = state[a] &+ state[b] &+ mx
            state[d] = rotateRight(state[d] ^ state[a], 16)
            state[c] = state[c] &+ state[d]
            state[b] = rotateRight(state[b] ^ state[c], 12)
            state[a] = state[a] &+ state[b] &+ my
            state[d] = rotateRight(state[d] ^ state[a], 8)
            state[c] = state[c] &+ state[d]
            state[b] = rotateRight(state[b] ^ state[c], 7)
        }

        private static func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x >> n) | (x << (32 - n))
        }
    }
}

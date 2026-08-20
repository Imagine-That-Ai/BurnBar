package com.openburnbar.data.media

import java.io.File
import java.io.FileInputStream

/** Content-addressed BLAKE3. Ticket strings are not hashes. */
object ContentBlake3 {
    fun parse(raw: String): String {
        var value = raw.trim().lowercase()
        if (value.startsWith("blake3:")) value = value.removePrefix("blake3:")
        require(value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }) {
            "blobHash must be a 64-hex blake3 digest, not a ticket"
        }
        return value
    }

    fun hash(data: ByteArray): String = Hasher().update(data).finalizeHex()

    fun hashFile(file: File): String {
        require(file.isFile) { "missing file for content hash" }
        val hasher = Hasher()
        FileInputStream(file).use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                hasher.update(buf.copyOf(n))
            }
        }
        return hasher.finalizeHex()
    }

    /** Hash opened plaintext. Never treat an iroh ticket as blake3. */
    fun parseOrHash(ticketOrHash: String, file: File): String {
        return runCatching { parse(ticketOrHash) }.getOrElse { hashFile(file) }
    }

    /** Official BLAKE3 reference (hashing only). */
    class Hasher {
        private var chunkState = ChunkState(IV.copyOf(), 0u, 0u)
        private val keyWords = IV.copyOf()
        private val cvStack = ArrayDeque<UIntArray>()
        private val flags = 0u

        fun update(data: ByteArray): Hasher {
            var offset = 0
            while (offset < data.size) {
                if (chunkState.len() == CHUNK_LEN) {
                    val chunkCv = chunkState.output().chainingValue()
                    val totalChunks = chunkState.chunkCounter + 1u
                    addChunkChainingValue(chunkCv, totalChunks)
                    chunkState = ChunkState(keyWords.copyOf(), totalChunks, flags)
                }
                val want = CHUNK_LEN - chunkState.len()
                val take = minOf(want, data.size - offset)
                chunkState.update(data.copyOfRange(offset, offset + take))
                offset += take
            }
            return this
        }

        fun finalizeHex(): String = finalize().joinToString("") { "%02x".format(it.toInt() and 0xff) }

        fun finalize(): ByteArray {
            var output = chunkState.output()
            var remaining = cvStack.size
            while (remaining > 0) {
                remaining -= 1
                output = parentOutput(cvStack.elementAt(remaining), output.chainingValue(), keyWords, flags)
            }
            return output.rootOutputBytes()
        }

        private fun addChunkChainingValue(newCv: UIntArray, totalChunks: UInt) {
            var cv = newCv
            var total = totalChunks
            while (total and 1u == 0u) {
                val left = cvStack.removeLast()
                cv = parentOutput(left, cv, keyWords, flags).chainingValue()
                total = total shr 1
            }
            cvStack.addLast(cv)
        }

        private class ChunkState(
            var chainingValue: UIntArray,
            var chunkCounter: UInt,
            var flags: UInt,
        ) {
            var block = ByteArray(BLOCK_LEN)
            var blockLen = 0
            var blocksCompressed = 0

            fun len(): Int = BLOCK_LEN * blocksCompressed + blockLen

            private fun startFlag(): UInt = if (blocksCompressed == 0) CHUNK_START else 0u

            fun update(input: ByteArray) {
                var remaining = input
                while (remaining.isNotEmpty()) {
                    if (blockLen == BLOCK_LEN) {
                        chainingValue = first8(
                            compress(
                                chainingValue,
                                wordsFrom(block),
                                chunkCounter,
                                BLOCK_LEN.toUInt(),
                                flags or startFlag(),
                            ),
                        )
                        blocksCompressed += 1
                        block = ByteArray(BLOCK_LEN)
                        blockLen = 0
                    }
                    val take = minOf(BLOCK_LEN - blockLen, remaining.size)
                    remaining.copyInto(block, blockLen, 0, take)
                    blockLen += take
                    remaining = remaining.copyOfRange(take, remaining.size)
                }
            }

            fun output(): Output = Output(
                chainingValue.copyOf(),
                wordsFrom(block),
                chunkCounter,
                blockLen.toUInt(),
                flags or startFlag() or CHUNK_END,
            )
        }

        private class Output(
            val inputChainingValue: UIntArray,
            val blockWords: UIntArray,
            val counter: UInt,
            val blockLen: UInt,
            val flags: UInt,
        ) {
            fun chainingValue(): UIntArray = first8(compress(inputChainingValue, blockWords, counter, blockLen, flags))

            fun rootOutputBytes(): ByteArray {
                val words = compress(inputChainingValue, blockWords, 0u, blockLen, flags or ROOT)
                return wordsToBytes(first8(words))
            }
        }

        companion object {
            private const val BLOCK_LEN = 64
            private const val CHUNK_LEN = 1024
            private val CHUNK_START = 1u shl 0
            private val CHUNK_END = 1u shl 1
            private val PARENT = 1u shl 2
            private val ROOT = 1u shl 3
            private val IV =
                uintArrayOf(
                    0x6A09E667u,
                    0xBB67AE85u,
                    0x3C6EF372u,
                    0xA54FF53Au,
                    0x510E527Fu,
                    0x9B05688Cu,
                    0x1F83D9ABu,
                    0x5BE0CD19u,
                )
            private val MSG_PERMUTATION = intArrayOf(2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8)

            private fun parentOutput(left: UIntArray, right: UIntArray, keyWords: UIntArray, flags: UInt): Output {
                val block = UIntArray(16)
                left.copyInto(block, 0, 0, 8)
                right.copyInto(block, 8, 0, 8)
                return Output(keyWords.copyOf(), block, 0u, BLOCK_LEN.toUInt(), flags or PARENT)
            }

            private fun first8(words: UIntArray): UIntArray = words.copyOfRange(0, 8)

            private fun wordsFrom(bytes: ByteArray): UIntArray {
                val block = ByteArray(BLOCK_LEN)
                bytes.copyInto(block, 0, 0, minOf(bytes.size, BLOCK_LEN))
                val words = UIntArray(16)
                for (i in 0 until 16) {
                    val o = i * 4
                    words[i] =
                        (block[o].toUInt() and 0xffu) or
                        ((block[o + 1].toUInt() and 0xffu) shl 8) or
                        ((block[o + 2].toUInt() and 0xffu) shl 16) or
                        ((block[o + 3].toUInt() and 0xffu) shl 24)
                }
                return words
            }

            private fun wordsToBytes(words: UIntArray): ByteArray {
                val out = ByteArray(words.size * 4)
                var i = 0
                for (w in words) {
                    out[i++] = (w and 0xffu).toByte()
                    out[i++] = ((w shr 8) and 0xffu).toByte()
                    out[i++] = ((w shr 16) and 0xffu).toByte()
                    out[i++] = ((w shr 24) and 0xffu).toByte()
                }
                return out
            }

            private fun compress(chainingValue: UIntArray, blockWords: UIntArray, counter: UInt, blockLen: UInt, flags: UInt): UIntArray {
                val state = UIntArray(16)
                for (i in 0 until 8) state[i] = chainingValue[i]
                for (i in 0 until 4) state[8 + i] = IV[i]
                state[12] = counter
                state[13] = 0u
                state[14] = blockLen
                state[15] = flags
                val block = blockWords.copyOf(16)
                repeat(7) {
                    round(state, block)
                    permute(block)
                }
                for (i in 0 until 8) {
                    state[i] = state[i] xor state[i + 8]
                    state[i + 8] = state[i + 8] xor chainingValue[i]
                }
                return state
            }

            private fun round(state: UIntArray, m: UIntArray) {
                g(state, 0, 4, 8, 12, m[0], m[1])
                g(state, 1, 5, 9, 13, m[2], m[3])
                g(state, 2, 6, 10, 14, m[4], m[5])
                g(state, 3, 7, 11, 15, m[6], m[7])
                g(state, 0, 5, 10, 15, m[8], m[9])
                g(state, 1, 6, 11, 12, m[10], m[11])
                g(state, 2, 7, 8, 13, m[12], m[13])
                g(state, 3, 4, 9, 14, m[14], m[15])
            }

            private fun permute(m: UIntArray) {
                val next = UIntArray(16)
                for (i in 0 until 16) next[i] = m[MSG_PERMUTATION[i]]
                next.copyInto(m)
            }

            private fun g(state: UIntArray, a: Int, b: Int, c: Int, d: Int, mx: UInt, my: UInt) {
                state[a] = state[a] + state[b] + mx
                state[d] = rotateRight(state[d] xor state[a], 16)
                state[c] = state[c] + state[d]
                state[b] = rotateRight(state[b] xor state[c], 12)
                state[a] = state[a] + state[b] + my
                state[d] = rotateRight(state[d] xor state[a], 8)
                state[c] = state[c] + state[d]
                state[b] = rotateRight(state[b] xor state[c], 7)
            }

            private fun rotateRight(x: UInt, n: Int): UInt = (x shr n) or (x shl (32 - n))
        }
    }
}

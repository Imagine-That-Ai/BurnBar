package com.openburnbar.data.media

import java.io.File
import java.io.FileInputStream

/** Content-addressed BLAKE3. Ticket strings are not hashes. */
object ContentBlake3 {
    private const val DIGEST_HEX_LENGTH = 64
    private const val FILE_READ_BUFFER_BYTES = 64 * 1024

    fun parse(raw: String): String {
        var value = raw.trim().lowercase()
        if (value.startsWith("blake3:")) value = value.removePrefix("blake3:")
        require(value.length == DIGEST_HEX_LENGTH && value.all { it in '0'..'9' || it in 'a'..'f' }) {
            "blobHash must be a 64-hex blake3 digest, not a ticket"
        }
        return value
    }

    fun hash(data: ByteArray): String = Hasher().update(data).finalizeHex()

    fun hashFile(file: File): String {
        require(file.isFile) { "missing file for content hash" }
        val hasher = Hasher()
        FileInputStream(file).use { input ->
            val buf = ByteArray(FILE_READ_BUFFER_BYTES)
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

        fun finalizeHex(): String = finalize().joinToString("") { "%02x".format(it.toInt() and BYTE_MASK) }

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
            private const val STATE_WORDS = 16
            private const val CV_WORDS = 8
            private const val IV_MIX_WORDS = 4
            private const val ROUNDS = 7
            private const val BYTE_MASK = 0xff
            private const val BYTE_MASK_U = 0xffu
            private const val STATE_COUNTER_LOW = 12
            private const val STATE_COUNTER_HIGH = 13
            private const val STATE_BLOCK_LEN = 14
            private const val STATE_FLAGS = 15
            private const val G_ROT_FIRST = 16
            private const val G_ROT_SECOND = 12
            private const val G_ROT_THIRD = 8
            private const val G_ROT_FOURTH = 7
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
                val block = UIntArray(STATE_WORDS)
                left.copyInto(block, 0, 0, CV_WORDS)
                right.copyInto(block, CV_WORDS, 0, CV_WORDS)
                return Output(keyWords.copyOf(), block, 0u, BLOCK_LEN.toUInt(), flags or PARENT)
            }

            private fun first8(words: UIntArray): UIntArray = words.copyOfRange(0, CV_WORDS)

            private fun wordsFrom(bytes: ByteArray): UIntArray {
                val block = ByteArray(BLOCK_LEN)
                bytes.copyInto(block, 0, 0, minOf(bytes.size, BLOCK_LEN))
                val words = UIntArray(STATE_WORDS)
                for (i in words.indices) {
                    var word = 0u
                    for (byteIndex in 0 until UInt.SIZE_BYTES) {
                        val byte = block[i * UInt.SIZE_BYTES + byteIndex].toUInt() and BYTE_MASK_U
                        word = word or (byte shl (byteIndex * Byte.SIZE_BITS))
                    }
                    words[i] = word
                }
                return words
            }

            private fun wordsToBytes(words: UIntArray): ByteArray {
                val out = ByteArray(words.size * UInt.SIZE_BYTES)
                var i = 0
                for (w in words) {
                    for (byteIndex in 0 until UInt.SIZE_BYTES) {
                        out[i++] = ((w shr (byteIndex * Byte.SIZE_BITS)) and BYTE_MASK_U).toByte()
                    }
                }
                return out
            }

            private fun compress(chainingValue: UIntArray, blockWords: UIntArray, counter: UInt, blockLen: UInt, flags: UInt): UIntArray {
                val state = UIntArray(STATE_WORDS)
                chainingValue.copyInto(state, 0, 0, CV_WORDS)
                IV.copyInto(state, CV_WORDS, 0, IV_MIX_WORDS)
                state[STATE_COUNTER_LOW] = counter
                state[STATE_COUNTER_HIGH] = 0u
                state[STATE_BLOCK_LEN] = blockLen
                state[STATE_FLAGS] = flags
                val block = blockWords.copyOf(STATE_WORDS)
                repeat(ROUNDS) {
                    round(state, block)
                    permute(block)
                }
                for (i in 0 until CV_WORDS) {
                    state[i] = state[i] xor state[i + CV_WORDS]
                    state[i + CV_WORDS] = state[i + CV_WORDS] xor chainingValue[i]
                }
                return state
            }

            // Column mixes then diagonal mixes, unrolled in spec order so the hot
            // per-block loop keeps compile-time-constant indices (no per-round
            // iterator or table indirection).
            @Suppress("MagicNumber") // reason: BLAKE3 §2.2 round schedule; the literal indices ARE the spec and are pinned by the official KATs.
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
                val next = UIntArray(STATE_WORDS)
                for (i in next.indices) next[i] = m[MSG_PERMUTATION[i]]
                next.copyInto(m)
            }

            private fun g(state: UIntArray, a: Int, b: Int, c: Int, d: Int, mx: UInt, my: UInt) {
                state[a] = state[a] + state[b] + mx
                state[d] = (state[d] xor state[a]).rotateRight(G_ROT_FIRST)
                state[c] = state[c] + state[d]
                state[b] = (state[b] xor state[c]).rotateRight(G_ROT_SECOND)
                state[a] = state[a] + state[b] + my
                state[d] = (state[d] xor state[a]).rotateRight(G_ROT_THIRD)
                state[c] = state[c] + state[d]
                state[b] = (state[b] xor state[c]).rotateRight(G_ROT_FOURTH)
            }
        }
    }
}

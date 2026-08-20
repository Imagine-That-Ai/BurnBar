package com.openburnbar.data.media

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object FileSealAEAD {
    const val CHUNK_PLAINTEXT_BYTES = 32 * 1024 * 1024
    const val NONCE_SIZE = 12
    const val TAG_SIZE = 16
    const val MAX_PLAINTEXT_BYTES = 10L * 1024L * 1024L * 1024L

    private const val CONTENT_KEY_BYTES = 32
    private const val TAG_SIZE_BITS = TAG_SIZE * Byte.SIZE_BITS

    /** AAD suffix after the attachment id: chunkIndex + totalChunks + plaintextSize, all big-endian longs. */
    private const val AAD_SUFFIX_BYTES = 3 * Long.SIZE_BYTES

    data class Header(
        val attachmentId: String,
        val totalChunks: Int,
        val plaintextSize: Long,
        val contentBlake3: String,
    )

    fun mintContentKey(): ByteArray = ByteArray(CONTENT_KEY_BYTES).also { SecureRandom().nextBytes(it) }

    fun mintNonce(): ByteArray = ByteArray(NONCE_SIZE).also { SecureRandom().nextBytes(it) }

    fun aad(header: Header, chunkIndex: Long): ByteArray {
        val id = header.attachmentId.toByteArray(Charsets.UTF_8)
        val buf = ByteBuffer.allocate(id.size + AAD_SUFFIX_BYTES).order(ByteOrder.BIG_ENDIAN)
        buf.put(id)
        buf.putLong(chunkIndex)
        buf.putLong(header.totalChunks.toLong())
        buf.putLong(header.plaintextSize)
        return buf.array()
    }

    fun sealChunk(plaintext: ByteArray, contentKey: ByteArray, header: Header, chunkIndex: Long, nonce: ByteArray): Pair<ByteArray, ByteArray> {
        require(nonce.size == NONCE_SIZE)
        require(contentKey.size == CONTENT_KEY_BYTES)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(contentKey, "AES"), GCMParameterSpec(TAG_SIZE_BITS, nonce))
        cipher.updateAAD(aad(header, chunkIndex))
        val combined = cipher.doFinal(plaintext)
        val ciphertext = combined.copyOfRange(0, combined.size - TAG_SIZE)
        val tag = combined.copyOfRange(combined.size - TAG_SIZE, combined.size)
        return ciphertext to tag
    }

    fun openChunk(ciphertext: ByteArray, tag: ByteArray, contentKey: ByteArray, header: Header, chunkIndex: Long, nonce: ByteArray): ByteArray {
        require(nonce.size == NONCE_SIZE)
        require(contentKey.size == CONTENT_KEY_BYTES)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(contentKey, "AES"), GCMParameterSpec(TAG_SIZE_BITS, nonce))
        cipher.updateAAD(aad(header, chunkIndex))
        return cipher.doFinal(ciphertext + tag)
    }

    fun sealFile(source: File, destination: File, contentKey: ByteArray, header: Header) {
        require(header.plaintextSize <= MAX_PLAINTEXT_BYTES)
        FileInputStream(source).use { input ->
            FileOutputStream(destination).use { output ->
                val buf = ByteArray(CHUNK_PLAINTEXT_BYTES)
                var index = 0L
                while (true) {
                    val read = input.read(buf)
                    if (read <= 0) break
                    val chunk = buf.copyOf(read)
                    val nonce = mintNonce()
                    val sealed = sealChunk(chunk, contentKey, header, index, nonce)
                    output.write(nonce)
                    output.write(sealed.first)
                    output.write(sealed.second)
                    index += 1
                }
                require(index.toInt() == header.totalChunks)
            }
        }
    }

    fun openFile(source: File, destination: File, contentKey: ByteArray, header: Header) {
        FileInputStream(source).use { input ->
            FileOutputStream(destination).use { output ->
                var remaining = header.plaintextSize
                for (index in 0 until header.totalChunks) {
                    val plaintextLen = minOf(CHUNK_PLAINTEXT_BYTES.toLong(), remaining).toInt()
                    val wireLen = NONCE_SIZE + plaintextLen + TAG_SIZE
                    val wire = ByteArray(wireLen)
                    val read = input.read(wire)
                    require(read == wireLen)
                    val nonce = wire.copyOfRange(0, NONCE_SIZE)
                    val ciphertext = wire.copyOfRange(NONCE_SIZE, wireLen - TAG_SIZE)
                    val tag = wire.copyOfRange(wireLen - TAG_SIZE, wireLen)
                    val plain = openChunk(ciphertext, tag, contentKey, header, index.toLong(), nonce)
                    output.write(plain)
                    remaining -= plain.size
                }
                require(remaining == 0L)
            }
        }
    }
}

package com.openburnbar.data.media

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private const val VAL_4 = 4

@JvmInline
value class MediaFrameV2Kind(val rawValue: Byte) {
    companion object {
        val VIDEO_NAL = MediaFrameV2Kind(0x01)
        val AUDIO_OPUS = MediaFrameV2Kind(0x02)
        val VIDEO_DATAGRAM = MediaFrameV2Kind(0x03)
        val RTC_SENDER_REPORT = MediaFrameV2Kind(0x11)
        val RTC_RECEIVER_REPORT = MediaFrameV2Kind(0x12)
        val RPS_RECOVERY_REQUEST = MediaFrameV2Kind(0x13)
        val CODEC_NEGOTIATION = MediaFrameV2Kind(0x14)
    }
}

data class MediaFrameV2(
    val kind: MediaFrameV2Kind,
    val flags: UShort = 0u,
    val gopID: UInt = 0u,
    val frameIndex: UInt = 0u,
    val presentationTimestampMillis: ULong = 0uL,
    val metadata: ByteArray = ByteArray(0),
    val payload: ByteArray = ByteArray(0),
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MediaFrameV2) return false
        return kind == other.kind &&
            flags == other.flags &&
            gopID == other.gopID &&
            frameIndex == other.frameIndex &&
            presentationTimestampMillis == other.presentationTimestampMillis &&
            metadata.contentEquals(other.metadata) &&
            payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int {
        var result = kind.hashCode()
        result = 31 * result + flags.hashCode()
        result = 31 * result + gopID.hashCode()
        result = 31 * result + frameIndex.hashCode()
        result = 31 * result + presentationTimestampMillis.hashCode()
        result = 31 * result + metadata.contentHashCode()
        result = 31 * result + payload.contentHashCode()
        return result
    }
}

@Serializable
data class MediaFrameV2LongTermReferenceToken(
    val value: Long,
)

@Serializable
data class MediaFrameV2Metadata(
    val codec: String? = null,
    val longTermReferenceToken: MediaFrameV2LongTermReferenceToken? = null,
) {
    fun encode(): ByteArray = json.encodeToString(MediaFrameV2Metadata.serializer(), this).encodeToByteArray()

    companion object {
        private val json =
            Json {
                ignoreUnknownKeys = true
                encodeDefaults = false
            }

        fun decode(bytes: ByteArray): MediaFrameV2Metadata {
            if (bytes.isEmpty()) return MediaFrameV2Metadata()
            return json.decodeFromString(MediaFrameV2Metadata.serializer(), bytes.decodeToString())
        }
    }
}

class MediaFrameV2Codec(
    val maxPayloadBytes: Int = DEFAULT_MAX_PAYLOAD_BYTES,
) {
    sealed class CodecError(message: String) : RuntimeException(message) {
        object NotNegotiated : CodecError("MediaFrame v2 was not negotiated")

        object EnvelopeTooShort : CodecError("envelope too short")

        object InvalidMagic : CodecError("invalid MediaFrame v2 magic")

        data class UnsupportedVersion(val version: Byte) : CodecError("unsupported MediaFrame v2 version: $version")

        data class PayloadTooLarge(val actual: Int, val max: Int) : CodecError("payload too large: $actual > $max")

        object HeaderTruncated : CodecError("header truncated")
    }

    data class Decoded(val frame: MediaFrameV2, val consumed: Int)

    fun encode(frame: MediaFrameV2, negotiatedVersion: MercuryMediaFrameWireVersion): ByteArray {
        if (negotiatedVersion != MercuryMediaFrameWireVersion.V2) {
            throw CodecError.NotNegotiated
        }
        val totalPayloadCount = FIXED_HEADER_BYTE_COUNT + frame.metadata.size + frame.payload.size
        if (totalPayloadCount > maxPayloadBytes) {
            throw CodecError.PayloadTooLarge(totalPayloadCount, maxPayloadBytes)
        }
        return ByteBuffer.allocate(VAL_4 + totalPayloadCount)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(totalPayloadCount)
            .put(MAGIC)
            .put(VERSION)
            .put(frame.kind.rawValue)
            .putShort(frame.flags.toShort())
            .putInt(frame.gopID.toInt())
            .putInt(frame.frameIndex.toInt())
            .putLong(frame.presentationTimestampMillis.toLong())
            .putInt(frame.metadata.size)
            .putInt(frame.payload.size)
            .put(frame.metadata)
            .put(frame.payload)
            .array()
    }

    fun decode(envelope: ByteArray): Decoded {
        val header = decodeEnvelopeHeader(envelope)
        val buffer = header.buffer
        validateMagicAndVersion(buffer)

        val kind = MediaFrameV2Kind(buffer.get())
        val flags = buffer.short.toUShort()
        val gopID = buffer.int.toUInt()
        val frameIndex = buffer.int.toUInt()
        val pts = buffer.long.toULong()
        val metadataLength = buffer.int
        val payloadLength = buffer.int
        validatePayloadBounds(metadataLength, payloadLength, buffer, header.totalEnvelopeBytes)
        val metadata = ByteArray(metadataLength)
        buffer.get(metadata)
        val payload = ByteArray(payloadLength)
        buffer.get(payload)
        return Decoded(
            frame =
            MediaFrameV2(
                kind = kind,
                flags = flags,
                gopID = gopID,
                frameIndex = frameIndex,
                presentationTimestampMillis = pts,
                metadata = metadata,
                payload = payload,
            ),
            consumed = header.totalEnvelopeBytes,
        )
    }

    private data class EnvelopeHeader(
        val buffer: ByteBuffer,
        val totalEnvelopeBytes: Int,
    )

    private fun decodeEnvelopeHeader(envelope: ByteArray): EnvelopeHeader {
        val lengthPrefixBytes = VAL_4
        if (envelope.size < lengthPrefixBytes + FIXED_HEADER_BYTE_COUNT) {
            throw CodecError.EnvelopeTooShort
        }
        val buffer = ByteBuffer.wrap(envelope).order(ByteOrder.BIG_ENDIAN)
        val totalPayloadCount = buffer.int
        val envelopeBoundsError: CodecError? =
            when {
                totalPayloadCount > maxPayloadBytes ->
                    CodecError.PayloadTooLarge(totalPayloadCount, maxPayloadBytes)
                envelope.size < lengthPrefixBytes + totalPayloadCount -> CodecError.HeaderTruncated
                else -> null
            }
        if (envelopeBoundsError != null) throw envelopeBoundsError
        return EnvelopeHeader(buffer = buffer, totalEnvelopeBytes = lengthPrefixBytes + totalPayloadCount)
    }

    private fun validateMagicAndVersion(buffer: ByteBuffer) {
        val magic = ByteArray(MAGIC.size)
        buffer.get(magic)
        if (!magic.contentEquals(MAGIC)) throw CodecError.InvalidMagic
        val version = buffer.get()
        if (version != VERSION) throw CodecError.UnsupportedVersion(version)
    }

    private fun validatePayloadBounds(
        metadataLength: Int,
        payloadLength: Int,
        buffer: ByteBuffer,
        totalEnvelopeBytes: Int,
    ) {
        val payloadEnd = buffer.position() + metadataLength + payloadLength
        val hasInvalidPayloadBounds =
            metadataLength < 0 || payloadLength < 0 || payloadEnd > totalEnvelopeBytes
        if (hasInvalidPayloadBounds) {
            throw CodecError.HeaderTruncated
        }
    }

    companion object {
        val MAGIC = byteArrayOf(0x4F, 0x42, 0x4D, 0x46, 0x56, 0x32) // OBMFV2
        const val VERSION: Byte = 2
        const val FIXED_HEADER_BYTE_COUNT: Int = 34
        const val DEFAULT_MAX_PAYLOAD_BYTES: Int = 2 * 1024 * 1024

        fun isEncodedEnvelope(envelope: ByteArray): Boolean {
            val headerStart = VAL_4
            if (envelope.size < headerStart + MAGIC.size) return false
            return MAGIC.indices.all { index -> envelope[headerStart + index] == MAGIC[index] }
        }
    }
}

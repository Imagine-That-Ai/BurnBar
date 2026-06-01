package com.openburnbar.data.media

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Wire-format constants for OBVCFG1 decoder configuration payloads and Annex-B normalization. */
private object VideoDecoderWireFormat {
    const val BITS_PER_BYTE = 8
    const val BYTE_MASK = 0xFF
    const val INT32_BYTE_1_SHIFT = 24
    const val INT32_BYTE_2_SHIFT = 16
    const val INT32_BYTE_3_SHIFT = 8
    const val INT32_BYTE_4_INDEX = 3
    const val UINT16_LENGTH_BYTES = 2
    const val INT32_LENGTH_BYTES = 4
    const val MIN_LENGTH_PREFIXED_PAYLOAD_BYTES = 5
    const val ANNEX_B_SHORT_START_CODE_INDEX = 2
    const val ANNEX_B_LONG_START_CODE_INDEX = 3
}

/**
 * Android port of the Mac/iOS `VideoDecoderConfigurationPayload`.
 *
 * VideoToolbox emits length-prefixed H.264/HEVC NAL units. The Mac sender wraps
 * keyframes with codec parameter sets (`OBVCFG1`) so receivers can bootstrap a
 * hardware decoder. Android `MediaCodec` ByteBuffer input is most reliable with
 * Annex-B start-code delimited access units, so the receive path unwraps this
 * payload and normalizes all length-prefixed NAL units before queueing them.
 */
internal data class VideoDecoderConfigurationPayload(
    val codec: Codec,
    val parameterSets: List<ByteArray>,
    val samplePayload: ByteArray,
) {
    enum class Codec(val rawValue: Byte) {
        HEVC(1),
        H264(2),
        ;

        companion object {
            fun from(rawValue: Byte): Codec? = entries.firstOrNull { it.rawValue == rawValue }
        }
    }

    fun encoded(): ByteArray {
        require(parameterSets.isNotEmpty()) { "parameter sets cannot be empty" }
        val payloadSize =
            MAGIC.size +
                1 +
                1 +
                parameterSets.sumOf { VideoDecoderWireFormat.UINT16_LENGTH_BYTES + it.size } +
                VideoDecoderWireFormat.INT32_LENGTH_BYTES +
                samplePayload.size
        val buffer = ByteBuffer.allocate(payloadSize).order(ByteOrder.BIG_ENDIAN)
        buffer.put(MAGIC)
        buffer.put(codec.rawValue)
        buffer.put(parameterSets.size.coerceAtMost(VideoDecoderWireFormat.BYTE_MASK).toByte())
        parameterSets.take(VideoDecoderWireFormat.BYTE_MASK).forEach { parameterSet ->
            require(parameterSet.size <= UShort.MAX_VALUE.toInt()) { "parameter set too large" }
            buffer.putShort(parameterSet.size.toShort())
            buffer.put(parameterSet)
        }
        buffer.putInt(samplePayload.size)
        buffer.put(samplePayload)
        return buffer.array()
    }

    companion object {
        val MAGIC = byteArrayOf(0x4F, 0x42, 0x56, 0x43, 0x46, 0x47, 0x31) // OBVCFG1

        fun decodeIfPresent(data: ByteArray): VideoDecoderConfigurationPayload? {
            if (data.size < MAGIC.size || !data.startsWith(MAGIC)) return null
            var offset = MAGIC.size
            if (data.size < offset + 2) require(false) { "truncated video decoder config" }
            val codec =
                Codec.from(data[offset++])
                    ?: require(false) { "unknown video decoder config codec" }
            val count = data[offset++].toInt() and VideoDecoderWireFormat.BYTE_MASK
            if (count <= 0) require(false) { "empty video decoder parameter sets" }

            val parameterSets = mutableListOf<ByteArray>()
            repeat(count) {
                if (data.size < offset + VideoDecoderWireFormat.UINT16_LENGTH_BYTES) {
                    require(false) { "truncated video decoder parameter set length" }
                }
                val length = readUInt16(data, offset)
                offset += VideoDecoderWireFormat.UINT16_LENGTH_BYTES
                if (data.size < offset + length) require(false) { "truncated video decoder parameter set" }
                parameterSets += data.copyOfRange(offset, offset + length)
                offset += length
            }

            if (data.size < offset + VideoDecoderWireFormat.INT32_LENGTH_BYTES) {
                require(false) { "truncated video decoder sample length" }
            }
            val sampleLength = readInt32(data, offset)
            offset += VideoDecoderWireFormat.INT32_LENGTH_BYTES
            if (sampleLength < 0 || data.size < offset + sampleLength) {
                require(false) { "truncated video decoder sample payload" }
            }
            return VideoDecoderConfigurationPayload(
                codec = codec,
                parameterSets = parameterSets,
                samplePayload = data.copyOfRange(offset, offset + sampleLength),
            )
        }

        private fun ByteArray.startsWith(prefix: ByteArray): Boolean = size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }

        private fun readUInt16(data: ByteArray, offset: Int): Int =
            data[offset].toInt() and VideoDecoderWireFormat.BYTE_MASK shl VideoDecoderWireFormat.BITS_PER_BYTE or
                data[offset + 1].toInt() and VideoDecoderWireFormat.BYTE_MASK

        private fun readInt32(data: ByteArray, offset: Int): Int =
            data[offset].toInt() and VideoDecoderWireFormat.BYTE_MASK shl VideoDecoderWireFormat.INT32_BYTE_1_SHIFT or
                (data[offset + 1].toInt() and VideoDecoderWireFormat.BYTE_MASK shl VideoDecoderWireFormat.INT32_BYTE_2_SHIFT) or
                (data[offset + 2].toInt() and VideoDecoderWireFormat.BYTE_MASK shl VideoDecoderWireFormat.INT32_BYTE_3_SHIFT) or
                (data[offset + VideoDecoderWireFormat.INT32_BYTE_4_INDEX].toInt() and VideoDecoderWireFormat.BYTE_MASK)
    }
}

internal object VideoPayloadNormalizer {
    private val START_CODE = byteArrayOf(0x00, 0x00, 0x00, 0x01)

    fun normalizeForMediaCodec(payload: ByteArray): ByteArray {
        val decoderConfig = VideoDecoderConfigurationPayload.decodeIfPresent(payload)
        if (decoderConfig != null) {
            val normalizedParameterSets = decoderConfig.parameterSets.flatMapToByteArray { withStartCode(it) }
            val normalizedSample = lengthPrefixedNalUnitsToAnnexBOrOriginal(decoderConfig.samplePayload)
            return normalizedParameterSets + normalizedSample
        }
        return lengthPrefixedNalUnitsToAnnexBOrOriginal(payload)
    }

    private fun lengthPrefixedNalUnitsToAnnexBOrOriginal(payload: ByteArray): ByteArray {
        if (payload.hasAnnexBStartCode()) return payload
        val nalUnits = splitLengthPrefixedNalUnits(payload) ?: return payload
        return nalUnits.flatMapToByteArray { withStartCode(it) }
    }

    private fun splitLengthPrefixedNalUnits(payload: ByteArray): List<ByteArray>? {
        if (payload.size < VideoDecoderWireFormat.MIN_LENGTH_PREFIXED_PAYLOAD_BYTES) return null
        val units = mutableListOf<ByteArray>()
        var offset = 0
        while (offset < payload.size) {
            if (payload.size - offset < VideoDecoderWireFormat.INT32_LENGTH_BYTES) return null
            val length =
                payload[offset].toInt() and VideoDecoderWireFormat.BYTE_MASK shl VideoDecoderWireFormat.INT32_BYTE_1_SHIFT or
                    (payload[offset + 1].toInt() and VideoDecoderWireFormat.BYTE_MASK shl VideoDecoderWireFormat.INT32_BYTE_2_SHIFT) or
                    (payload[offset + 2].toInt() and VideoDecoderWireFormat.BYTE_MASK shl VideoDecoderWireFormat.INT32_BYTE_3_SHIFT) or
                    (payload[offset + VideoDecoderWireFormat.INT32_BYTE_4_INDEX].toInt() and VideoDecoderWireFormat.BYTE_MASK)
            offset += VideoDecoderWireFormat.INT32_LENGTH_BYTES
            if (length <= 0 || payload.size - offset < length) return null
            units += payload.copyOfRange(offset, offset + length)
            offset += length
        }
        return units.takeIf { it.isNotEmpty() }
    }

    private fun ByteArray.hasAnnexBStartCode(): Boolean = size >= VideoDecoderWireFormat.INT32_LENGTH_BYTES &&
        this[0] == 0.toByte() &&
        this[1] == 0.toByte() &&
        (
            this[VideoDecoderWireFormat.ANNEX_B_SHORT_START_CODE_INDEX] == 1.toByte() ||
                this[VideoDecoderWireFormat.ANNEX_B_SHORT_START_CODE_INDEX] == 0.toByte() &&
                this[VideoDecoderWireFormat.ANNEX_B_LONG_START_CODE_INDEX] == 1.toByte()
            )

    private fun withStartCode(nal: ByteArray): ByteArray = START_CODE + nal

    private inline fun List<ByteArray>.flatMapToByteArray(transform: (ByteArray) -> ByteArray): ByteArray {
        val transformed = map(transform)
        val totalSize = transformed.sumOf { it.size }
        val output = ByteArray(totalSize)
        var offset = 0
        transformed.forEach { bytes ->
            bytes.copyInto(output, offset)
            offset += bytes.size
        }
        return output
    }
}

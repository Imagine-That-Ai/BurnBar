@file:Suppress("MagicNumber", "ThrowsCount", "UnnecessaryParentheses")
// Wire-format NAL/codec byte layout literals; named constants obscure OBVCFG1 parsing.

package com.openburnbar.data.media

import java.nio.ByteBuffer
import java.nio.ByteOrder

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
        H264(2);

        companion object {
            fun from(rawValue: Byte): Codec? = entries.firstOrNull { it.rawValue == rawValue }
        }
    }

    fun encoded(): ByteArray {
        require(parameterSets.isNotEmpty()) { "parameter sets cannot be empty" }
        val payloadSize = MAGIC.size +
            1 +
            1 +
            parameterSets.sumOf { 2 + it.size } +
            4 +
            samplePayload.size
        val buffer = ByteBuffer.allocate(payloadSize).order(ByteOrder.BIG_ENDIAN)
        buffer.put(MAGIC)
        buffer.put(codec.rawValue)
        buffer.put(parameterSets.size.coerceAtMost(255).toByte())
        parameterSets.take(255).forEach { parameterSet ->
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
            require(data.size >= offset + 2) { "truncated video decoder config" }
            val codec = Codec.from(data[offset++])
                ?: throw IllegalArgumentException("unknown video decoder config codec")
            val count = data[offset++].toInt() and 0xFF
            require(count > 0) { "empty video decoder parameter sets" }

            val parameterSets = mutableListOf<ByteArray>()
            repeat(count) {
                require(data.size >= offset + 2) { "truncated video decoder parameter set length" }
                val length = readUInt16(data, offset)
                offset += 2
                require(data.size >= offset + length) { "truncated video decoder parameter set" }
                parameterSets += data.copyOfRange(offset, offset + length)
                offset += length
            }

            require(data.size >= offset + 4) { "truncated video decoder sample length" }
            val sampleLength = readInt32(data, offset)
            offset += 4
            require(sampleLength >= 0 && data.size >= offset + sampleLength) {
                "truncated video decoder sample payload"
            }
            return VideoDecoderConfigurationPayload(
                codec = codec,
                parameterSets = parameterSets,
                samplePayload = data.copyOfRange(offset, offset + sampleLength),
            )
        }

        private fun ByteArray.startsWith(prefix: ByteArray): Boolean =
            size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }

        private fun readUInt16(data: ByteArray, offset: Int): Int =
            (data[offset].toInt() and 0xFF shl 8) or
                (data[offset + 1].toInt() and 0xFF)

        private fun readInt32(data: ByteArray, offset: Int): Int =
            (data[offset].toInt() and 0xFF shl 24) or
                (data[offset + 1].toInt() and 0xFF shl 16) or
                (data[offset + 2].toInt() and 0xFF shl 8) or
                (data[offset + 3].toInt() and 0xFF)
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
        if (payload.size < 5) return null
        val units = mutableListOf<ByteArray>()
        var offset = 0
        while (offset < payload.size) {
            if (payload.size - offset < 4) return null
            val length = (payload[offset].toInt() and 0xFF shl 24) or
                (payload[offset + 1].toInt() and 0xFF shl 16) or
                (payload[offset + 2].toInt() and 0xFF shl 8) or
                (payload[offset + 3].toInt() and 0xFF)
            offset += 4
            if (length <= 0 || payload.size - offset < length) return null
            units += payload.copyOfRange(offset, offset + length)
            offset += length
        }
        return units.takeIf { it.isNotEmpty() }
    }

    private fun ByteArray.hasAnnexBStartCode(): Boolean =
        size >= 4 && this[0] == 0.toByte() && this[1] == 0.toByte() &&
            (this[2] == 1.toByte() || this[2] == 0.toByte() && this[3] == 1.toByte())

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

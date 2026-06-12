
package com.openburnbar.data.media

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

private const val BITS_PER_BYTE = 8

class VideoDecoderConfigurationPayloadTest {
    @Test
    fun decoderConfigurationPayloadRoundTripsParameterSetsAndSamplePayload() {
        val payload =
            VideoDecoderConfigurationPayload(
                codec = VideoDecoderConfigurationPayload.Codec.HEVC,
                parameterSets = listOf(byteArrayOf(0x40.toByte(), 0x01), byteArrayOf(0x42.toByte(), 0x01, 0x02)),
                samplePayload = lengthPrefixed(byteArrayOf(0x26.toByte(), 0x01, 0x02)),
            )

        val decoded = VideoDecoderConfigurationPayload.decodeIfPresent(payload.encoded())

        requireNotNull(decoded)
        assertEquals(VideoDecoderConfigurationPayload.Codec.HEVC, decoded.codec)
        assertArrayEquals(payload.parameterSets[0], decoded.parameterSets[0])
        assertArrayEquals(payload.parameterSets[1], decoded.parameterSets[1])
        assertArrayEquals(payload.samplePayload, decoded.samplePayload)
    }

    @Test
    fun normalizerUnwrapsDecoderConfigurationAndConvertsLengthPrefixedNalsToAnnexB() {
        val payload =
            VideoDecoderConfigurationPayload(
                codec = VideoDecoderConfigurationPayload.Codec.HEVC,
                parameterSets = listOf(byteArrayOf(0x40.toByte()), byteArrayOf(0x42.toByte())),
                samplePayload = lengthPrefixed(byteArrayOf(0x26.toByte(), 0x01), byteArrayOf(0x02, 0x03.toByte())),
            )

        val normalized = VideoPayloadNormalizer.normalizeForMediaCodec(payload.encoded())

        assertArrayEquals(
            byteArrayOf(
                0x00, 0x00, 0x00, 0x01, 0x40.toByte(),
                0x00, 0x00, 0x00, 0x01, 0x42.toByte(),
                0x00, 0x00, 0x00, 0x01, 0x26.toByte(), 0x01,
                0x00, 0x00, 0x00, 0x01, 0x02, 0x03.toByte(),
            ),
            normalized,
        )
    }

    @Test
    fun normalizerLeavesExistingAnnexBPayloadsUnchanged() {
        val annexB = byteArrayOf(0x00, 0x00, 0x00, 0x01, 0x26.toByte(), 0x01)

        assertArrayEquals(annexB, VideoPayloadNormalizer.normalizeForMediaCodec(annexB))
    }

    private fun lengthPrefixed(vararg nals: ByteArray): ByteArray {
        val output = ByteArray(nals.sumOf { 4 + it.size })
        var offset = 0
        nals.forEach { nal ->
            val length = nal.size
            output[offset++] = (length ushr 24 and 0xFF).toByte()
            output[offset++] = (length ushr 16 and 0xFF).toByte()
            output[offset++] = (length ushr BITS_PER_BYTE and 0xFF).toByte()
            output[offset++] = (length and 0xFF).toByte()
            nal.copyInto(output, offset)
            offset += nal.size
        }
        return output
    }
}

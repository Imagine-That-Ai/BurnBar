
package com.openburnbar.data.media

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MediaFrameV2CodecTest {
    @Test
    fun round_trip_separates_metadata_from_payload_with_explicit_lengths() {
        val codec = MediaFrameV2Codec()
        val metadata =
            MediaFrameV2Metadata(
                codec = "hevc",
                longTermReferenceToken = MediaFrameV2LongTermReferenceToken(value = 9001L),
            ).encode()
        val frame =
            MediaFrameV2(
                kind = MediaFrameV2Kind.VIDEO_DATAGRAM,
                flags = 0x0003u,
                gopID = 99u,
                frameIndex = 7u,
                presentationTimestampMillis = 1_777_777uL,
                metadata = metadata,
                payload = byteArrayOf(0x7A.toByte(), 0x7B.toByte(), 0x7C.toByte()),
            )

        val encoded = codec.encode(frame, MercuryMediaFrameWireVersion.V2)
        val decoded = codec.decode(encoded)

        assertEquals(encoded.size, decoded.consumed)
        assertEquals(frame, decoded.frame)
        assertArrayEquals(frame.metadata, decoded.frame.metadata)
        assertArrayEquals(frame.payload, decoded.frame.payload)
        val decodedMetadata = MediaFrameV2Metadata.decode(decoded.frame.metadata)
        assertEquals("hevc", decodedMetadata.codec)
        assertEquals(9001L, decodedMetadata.longTermReferenceToken?.value)
    }

    @Test
    fun empty_metadata_decodes_to_empty_metadata_model() {
        val metadata = MediaFrameV2Metadata.decode(ByteArray(0))

        assertEquals(null, metadata.codec)
        assertEquals(null, metadata.longTermReferenceToken)
    }

    @Test
    fun encode_requires_v2_negotiation() {
        val codec = MediaFrameV2Codec()
        val frame =
            MediaFrameV2(
                kind = MediaFrameV2Kind.RTC_RECEIVER_REPORT,
                metadata = byteArrayOf(0x01),
                payload = byteArrayOf(0x02),
            )

        assertThrows(MediaFrameV2Codec.CodecError.NotNegotiated::class.java) {
            codec.encode(frame, MercuryMediaFrameWireVersion.V1)
        }
    }

    @Test
    fun encoded_envelope_detection_uses_length_prefixed_magic() {
        val v2 =
            MediaFrameV2Codec().encode(
                MediaFrameV2(
                    kind = MediaFrameV2Kind.VIDEO_DATAGRAM,
                    metadata = byteArrayOf(0x01),
                    payload = byteArrayOf(0x02),
                ),
                MercuryMediaFrameWireVersion.V2,
            )
        val v1 =
            MediaPacketCodec().encode(
                MediaFrame(
                    kind = MediaFrame.Kind.VIDEO_NAL,
                    gopID = 1u,
                    frameIndex = 2u,
                    payload = byteArrayOf(0x03.toByte()),
                ),
            )

        assertEquals(true, MediaFrameV2Codec.isEncodedEnvelope(v2))
        assertEquals(false, MediaFrameV2Codec.isEncodedEnvelope(v1))
        assertEquals(false, MediaFrameV2Codec.isEncodedEnvelope(MediaFrameV2Codec.MAGIC.take(3).toByteArray()))
    }

    @Test
    fun v1_codec_rejects_v2_envelope_rather_than_misparsing_known_frame() {
        val v2 =
            MediaFrameV2Codec().encode(
                MediaFrameV2(
                    kind = MediaFrameV2Kind.VIDEO_DATAGRAM,
                    metadata = byteArrayOf(0x01),
                    payload = byteArrayOf(0x02),
                ),
                MercuryMediaFrameWireVersion.V2,
            )

        assertThrows(MediaPacketCodec.CodecError.UnknownKind::class.java) {
            MediaPacketCodec().decode(v2)
        }
    }

    @Test
    fun metadata_length_mismatch_is_rejected() {
        val encoded =
            MediaFrameV2Codec().encode(
                MediaFrameV2(
                    kind = MediaFrameV2Kind.CODEC_NEGOTIATION,
                    metadata = byteArrayOf(0x01, 0x02),
                    payload = byteArrayOf(0x03.toByte()),
                ),
                MercuryMediaFrameWireVersion.V2,
            )
        // Corrupt metadata length to claim more bytes than the envelope carries.
        encoded[30] = 0x00
        encoded[31] = 0x00
        encoded[32] = 0x00
        encoded[33] = 0x7F

        assertThrows(MediaFrameV2Codec.CodecError.HeaderTruncated::class.java) {
            MediaFrameV2Codec().decode(encoded)
        }
    }
}

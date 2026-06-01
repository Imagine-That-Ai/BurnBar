@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.media

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

private const val VAL_0X03 = 0x03
private const val VAL_0X7A = 0x7A
private const val VAL_0X7B = 0x7B
private const val VAL_0X7C = 0x7C
private const val VAL_3 = 3
private const val VAL_30 = 30
private const val VAL_31 = 31
private const val VAL_32 = 32
private const val VAL_33 = 33
private const val VAL_9001_L = 9001L

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
                payload = byteArrayOf(VAL_0X7A, VAL_0X7B, VAL_0X7C),
            )

        val encoded = codec.encode(frame, MercuryMediaFrameWireVersion.V2)
        val decoded = codec.decode(encoded)

        assertEquals(encoded.size, decoded.consumed)
        assertEquals(frame, decoded.frame)
        assertArrayEquals(frame.metadata, decoded.frame.metadata)
        assertArrayEquals(frame.payload, decoded.frame.payload)
        val decodedMetadata = MediaFrameV2Metadata.decode(decoded.frame.metadata)
        assertEquals("hevc", decodedMetadata.codec)
        assertEquals(VAL_9001_L, decodedMetadata.longTermReferenceToken?.value)
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
                    payload = byteArrayOf(VAL_0X03),
                ),
            )

        assertEquals(true, MediaFrameV2Codec.isEncodedEnvelope(v2))
        assertEquals(false, MediaFrameV2Codec.isEncodedEnvelope(v1))
        assertEquals(false, MediaFrameV2Codec.isEncodedEnvelope(MediaFrameV2Codec.MAGIC.take(VAL_3).toByteArray()))
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
                    payload = byteArrayOf(VAL_0X03),
                ),
                MercuryMediaFrameWireVersion.V2,
            )
        // Corrupt metadata length to claim more bytes than the envelope carries.
        encoded[VAL_30] = 0x00
        encoded[VAL_31] = 0x00
        encoded[VAL_32] = 0x00
        encoded[VAL_33] = 0x7F

        assertThrows(MediaFrameV2Codec.CodecError.HeaderTruncated::class.java) {
            MediaFrameV2Codec().decode(encoded)
        }
    }
}

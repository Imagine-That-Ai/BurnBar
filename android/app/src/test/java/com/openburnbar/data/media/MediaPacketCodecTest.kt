package com.openburnbar.data.media

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MediaPacketCodecTest {

    @Test
    fun round_trip_preserves_header_and_payload() {
        val codec = MediaPacketCodec()
        val frame = MediaFrame(
            kind = MediaFrame.Kind.VIDEO_NAL,
            flags = MediaFrame.Flags.KEYFRAME.or(MediaFrame.Flags.END_OF_GROUP),
            gopID = 42u,
            frameIndex = 7u,
            presentationTimestampMillis = 123_456_789uL,
            payload = byteArrayOf(0x10, 0x20, 0x30, 0x40),
        )
        val envelope = codec.encode(frame)
        val decoded = codec.decode(envelope)
        assertEquals(frame, decoded.frame)
        assertEquals(envelope.size, decoded.consumed)
        assertArrayEquals(envelope, codec.encode(decoded.frame))
    }

    @Test
    fun encode_rejects_payload_exceeding_max() {
        val codec = MediaPacketCodec(maxPayloadBytes = MediaFrame.HEADER_BYTE_COUNT + 8)
        val frame = MediaFrame(
            kind = MediaFrame.Kind.VIDEO_NAL,
            payload = ByteArray(64) { 0 },
        )
        assertThrows(MediaPacketCodec.CodecError.PayloadTooLarge::class.java) {
            codec.encode(frame)
        }
    }

    @Test
    fun decode_rejects_truncated_envelope() {
        val codec = MediaPacketCodec()
        // 4-byte length prefix + half a header is not enough.
        val truncated = ByteArray(4 + MediaFrame.HEADER_BYTE_COUNT - 3)
        assertThrows(MediaPacketCodec.CodecError.EnvelopeTooShort::class.java) {
            codec.decode(truncated)
        }
    }

    @Test
    fun decode_rejects_unknown_frame_kind() {
        val codec = MediaPacketCodec()
        // Build a valid envelope and corrupt the first byte after prefix.
        val frame = MediaFrame(kind = MediaFrame.Kind.AUDIO_OPUS, payload = byteArrayOf(0x01))
        val envelope = codec.encode(frame)
        envelope[4] = 0x7F.toByte() // overwrite the kind byte
        assertThrows(MediaPacketCodec.CodecError.UnknownKind::class.java) {
            codec.decode(envelope)
        }
    }

    @Test
    fun decode_rejects_oversize_declared_length() {
        val codec = MediaPacketCodec(maxPayloadBytes = 64)
        val envelope = ByteArray(4 + 128)
        envelope[3] = 128.toByte()
        assertThrows(MediaPacketCodec.CodecError.PayloadTooLarge::class.java) {
            codec.decode(envelope)
        }
    }
}

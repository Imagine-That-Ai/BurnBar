package com.openburnbar.data.media

/**
 * Binary media frame envelope used by per-GOP video / per-packet audio
 * stream classes. 1:1 port of `MediaFrame.swift`. Header layout:
 *
 * |  0 .. 0  | frame type    (u8)
 * |  1 .. 1  | flags         (u8)         bit 0: keyframe; bit 1: end-of-GOP; bit 2: muted; bit 3: cursor
 * |  2 .. 5  | gop id        (u32 BE)
 * |  6 .. 9  | frame index   (u32 BE)
 * | 10 .. 17 | presentation timestamp ms  (u64 BE)
 * | 18 .. 21 | optional cursor i16 x/y, present only when bit 3 is set
 * | .. ...   | encoded payload (NAL units, Opus frame, etc.)
 */
data class MediaFrame(
    val kind: Kind,
    val flags: Flags = Flags.NONE,
    val gopID: UInt = 0u,
    val frameIndex: UInt = 0u,
    val presentationTimestampMillis: ULong = 0uL,
    val cursor: CursorMetadata? = null,
    val payload: ByteArray = ByteArray(0),
) {
    data class CursorMetadata(val x: Short, val y: Short)

    enum class Kind(val rawValue: Byte) {
        VIDEO_NAL(0x01),
        AUDIO_OPUS(0x02),
        BWE_FEEDBACK(0x10),
        SESSION_CONTROL(0x20);

        companion object {
            fun fromRaw(raw: Byte): Kind? = values().firstOrNull { it.rawValue == raw }
        }
    }

    @JvmInline
    value class Flags(val rawValue: Byte) {
        operator fun contains(other: Flags): Boolean =
            (rawValue.toInt() and other.rawValue.toInt()) == other.rawValue.toInt()

        fun or(other: Flags): Flags = Flags((rawValue.toInt() or other.rawValue.toInt()).toByte())

        companion object {
            val NONE = Flags(0)
            val KEYFRAME = Flags(0x01)
            val END_OF_GROUP = Flags(0x02)
            val MUTED = Flags(0x04)
            val HAS_CURSOR_METADATA = Flags(0x08)
        }
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MediaFrame) return false
        return kind == other.kind &&
            flags == other.flags &&
            gopID == other.gopID &&
            frameIndex == other.frameIndex &&
            presentationTimestampMillis == other.presentationTimestampMillis &&
            cursor == other.cursor &&
            payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int {
        var h = kind.hashCode()
        h = 31 * h + flags.hashCode()
        h = 31 * h + gopID.hashCode()
        h = 31 * h + frameIndex.hashCode()
        h = 31 * h + presentationTimestampMillis.hashCode()
        h = 31 * h + cursor.hashCode()
        h = 31 * h + payload.contentHashCode()
        return h
    }

    companion object {
        /** Fixed header size in bytes. Pinned in `MediaPacketCodec`. */
        const val HEADER_BYTE_COUNT: Int = 18

        /** Two big-endian i16 values appended after the fixed header. */
        const val CURSOR_METADATA_BYTE_COUNT: Int = 4
    }
}

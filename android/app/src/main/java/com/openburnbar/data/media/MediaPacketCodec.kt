package com.openburnbar.data.media

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Length-prefixed binary codec for Mercury media frames. 1:1 port of
 * `MediaPacketCodec.swift`. Same outer layout as `IrohRelayFrameCodec`
 * so an audit reader can locate frame boundaries without knowing
 * whether the payload is JSON chat or a binary media frame.
 *
 * ```
 * [ u32 BE total payload length ][ MediaFrame.HEADER_BYTE_COUNT header ][ optional cursor ][ payload ]
 * ```
 */
class MediaPacketCodec(
    val maxPayloadBytes: Int = DEFAULT_MAX_PAYLOAD_BYTES,
) {
    sealed class CodecError(message: String) : RuntimeException(message) {
        object EnvelopeTooShort : CodecError("envelope too short")
        data class PayloadTooLarge(val actual: Int, val max: Int) :
            CodecError("payload too large: $actual > $max")
        object HeaderTruncated : CodecError("header truncated")
        data class UnknownKind(val raw: Byte) : CodecError("unknown frame kind: $raw")
        object CursorTruncated : CodecError("cursor metadata truncated")
    }

    data class Decoded(val frame: MediaFrame, val consumed: Int)

    fun encode(frame: MediaFrame): ByteArray {
        val cursorByteCount = if (frame.flags.contains(MediaFrame.Flags.HAS_CURSOR_METADATA)) {
            MediaFrame.CURSOR_METADATA_BYTE_COUNT
        } else {
            0
        }
        val totalPayloadCount = MediaFrame.HEADER_BYTE_COUNT + cursorByteCount + frame.payload.size
        if (totalPayloadCount > maxPayloadBytes) {
            throw CodecError.PayloadTooLarge(totalPayloadCount, maxPayloadBytes)
        }
        val buffer = ByteBuffer.allocate(4 + totalPayloadCount).order(ByteOrder.BIG_ENDIAN)
        buffer.putInt(totalPayloadCount)
        buffer.put(frame.kind.rawValue)
        buffer.put(frame.flags.rawValue)
        buffer.putInt(frame.gopID.toInt())
        buffer.putInt(frame.frameIndex.toInt())
        buffer.putLong(frame.presentationTimestampMillis.toLong())
        if (frame.flags.contains(MediaFrame.Flags.HAS_CURSOR_METADATA)) {
            val cursor = frame.cursor ?: MediaFrame.CursorMetadata(0, 0)
            buffer.putShort(cursor.x)
            buffer.putShort(cursor.y)
        }
        buffer.put(frame.payload)
        return buffer.array()
    }

    fun decode(envelope: ByteArray): Decoded {
        val lengthPrefixBytes = 4
        if (envelope.size < lengthPrefixBytes + MediaFrame.HEADER_BYTE_COUNT) {
            throw CodecError.EnvelopeTooShort
        }
        val buffer = ByteBuffer.wrap(envelope).order(ByteOrder.BIG_ENDIAN)
        val totalPayloadCount = buffer.int
        if (totalPayloadCount > maxPayloadBytes) {
            throw CodecError.PayloadTooLarge(totalPayloadCount, maxPayloadBytes)
        }
        val totalEnvelopeBytes = lengthPrefixBytes + totalPayloadCount
        if (envelope.size < totalEnvelopeBytes) {
            throw CodecError.HeaderTruncated
        }
        val kindByte = buffer.get()
        val kind = MediaFrame.Kind.fromRaw(kindByte) ?: throw CodecError.UnknownKind(kindByte)
        val flagsByte = buffer.get()
        val gopID = buffer.int.toUInt()
        val frameIndex = buffer.int.toUInt()
        val pts = buffer.long.toULong()

        var payloadStart = lengthPrefixBytes + MediaFrame.HEADER_BYTE_COUNT
        val cursor = if (MediaFrame.Flags(flagsByte).contains(MediaFrame.Flags.HAS_CURSOR_METADATA)) {
            val cursorEnd = payloadStart + MediaFrame.CURSOR_METADATA_BYTE_COUNT
            if (cursorEnd > lengthPrefixBytes + totalPayloadCount) {
                throw CodecError.CursorTruncated
            }
            val x = buffer.short
            val y = buffer.short
            payloadStart = cursorEnd
            MediaFrame.CursorMetadata(x, y)
        } else {
            null
        }
        val payloadEnd = lengthPrefixBytes + totalPayloadCount
        val payload = envelope.copyOfRange(payloadStart, payloadEnd)

        return Decoded(
            frame = MediaFrame(
                kind = kind,
                flags = MediaFrame.Flags(flagsByte),
                gopID = gopID,
                frameIndex = frameIndex,
                presentationTimestampMillis = pts,
                cursor = cursor,
                payload = payload,
            ),
            consumed = totalEnvelopeBytes,
        )
    }

    companion object {
        /** Hard ceiling on a single media frame. Matches iroh-blobs default chunk size. */
        const val DEFAULT_MAX_PAYLOAD_BYTES: Int = 256 * 1024
    }
}

using System;
using System.Buffers.Binary;

namespace OpenBurnBar.Integrations.Mercury.Wire;

/// <summary>
/// Length-prefixed binary codec for Mercury media frames. Byte-exact port of
/// <c>OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaPacketCodec.swift</c>.
///
/// Outer layout (same 4-byte big-endian length prefix as the iroh relay frame
/// codec, so an audit reader can locate frame boundaries without knowing the
/// payload kind):
/// <code>
/// [ u32 BE total payload length ][ MediaFrame header (18) ][ optional cursor (4) ][ payload ]
/// </code>
/// where <c>total payload length = 18 + cursorBytes + payload.Length</c>.
/// </summary>
public sealed class MediaPacketCodec
{
    /// <summary>
    /// Hard ceiling on a single media frame. Matches the iroh-blobs default
    /// chunk size (256 KiB) so a packet that exceeds it is almost certainly a
    /// producer bug or a hostile peer.
    /// </summary>
    public const int DefaultMaxPayloadBytes = 256 * 1024;

    private const int LengthPrefixBytes = 4;

    public int MaxPayloadBytes { get; }

    public MediaPacketCodec(int maxPayloadBytes = DefaultMaxPayloadBytes)
    {
        MaxPayloadBytes = maxPayloadBytes;
    }

    /// <summary>Encode a frame into a length-prefixed envelope.</summary>
    public byte[] Encode(MediaFrame frame)
    {
        if (frame is null)
        {
            throw new ArgumentNullException(nameof(frame));
        }

        var cursorBytes = frame.Flags.HasFlag(MediaFrameFlags.HasCursorMetadata)
            ? MediaFrame.CursorMetadataByteCount
            : 0;
        var totalPayloadCount = MediaFrame.HeaderByteCount + cursorBytes + frame.Payload.Length;
        if (totalPayloadCount > MaxPayloadBytes)
        {
            throw new MediaPacketCodecException(
                MediaPacketCodecError.PayloadTooLarge,
                $"payload {totalPayloadCount} exceeds max {MaxPayloadBytes}",
                actual: totalPayloadCount,
                max: MaxPayloadBytes);
        }

        var envelope = new byte[LengthPrefixBytes + totalPayloadCount];
        var offset = 0;

        BinaryPrimitives.WriteUInt32BigEndian(envelope.AsSpan(offset, 4), (uint)totalPayloadCount);
        offset += 4;

        // Header.
        envelope[offset++] = (byte)frame.Kind;
        envelope[offset++] = (byte)frame.Flags;
        BinaryPrimitives.WriteUInt32BigEndian(envelope.AsSpan(offset, 4), frame.GopId);
        offset += 4;
        BinaryPrimitives.WriteUInt32BigEndian(envelope.AsSpan(offset, 4), frame.FrameIndex);
        offset += 4;
        BinaryPrimitives.WriteUInt64BigEndian(envelope.AsSpan(offset, 8), frame.PresentationTimestampMillis);
        offset += 8;

        // Optional cursor extension. Honor the flag the producer set even when
        // `Cursor` is null — write (0,0) rather than silently dropping the bit,
        // matching the Swift codec so receivers can round-trip frames they
        // cannot yet interpret.
        if (frame.Flags.HasFlag(MediaFrameFlags.HasCursorMetadata))
        {
            var cursor = frame.Cursor ?? new CursorMetadata(0, 0);
            BinaryPrimitives.WriteInt16BigEndian(envelope.AsSpan(offset, 2), cursor.X);
            offset += 2;
            BinaryPrimitives.WriteInt16BigEndian(envelope.AsSpan(offset, 2), cursor.Y);
            offset += 2;
        }

        Array.Copy(frame.Payload, 0, envelope, offset, frame.Payload.Length);
        return envelope;
    }

    /// <summary>
    /// Decode a single frame from the front of <paramref name="envelope"/>.
    /// Returns the frame plus how many bytes were consumed (so a caller can
    /// decode a back-to-back stream).
    /// </summary>
    public MediaPacketDecodeResult Decode(ReadOnlySpan<byte> envelope)
    {
        if (envelope.Length < LengthPrefixBytes + MediaFrame.HeaderByteCount)
        {
            throw new MediaPacketCodecException(
                MediaPacketCodecError.EnvelopeTooShort,
                "envelope shorter than length prefix + header");
        }

        var totalPayloadCount = (int)BinaryPrimitives.ReadUInt32BigEndian(envelope.Slice(0, 4));
        if (totalPayloadCount > MaxPayloadBytes)
        {
            throw new MediaPacketCodecException(
                MediaPacketCodecError.PayloadTooLarge,
                $"declared payload {totalPayloadCount} exceeds max {MaxPayloadBytes}",
                actual: totalPayloadCount,
                max: MaxPayloadBytes);
        }

        var totalEnvelopeBytes = LengthPrefixBytes + totalPayloadCount;
        if (envelope.Length < totalEnvelopeBytes)
        {
            throw new MediaPacketCodecException(
                MediaPacketCodecError.HeaderTruncated,
                "envelope shorter than declared total length");
        }

        var headerStart = LengthPrefixBytes;
        var kindByte = envelope[headerStart];
        if (!Enum.IsDefined(typeof(MediaFrameKind), kindByte))
        {
            throw new MediaPacketCodecException(
                MediaPacketCodecError.UnknownKind,
                $"unknown frame kind 0x{kindByte:x2}",
                unknownKind: kindByte);
        }

        var kind = (MediaFrameKind)kindByte;
        var flags = (MediaFrameFlags)envelope[headerStart + 1];
        var gopId = BinaryPrimitives.ReadUInt32BigEndian(envelope.Slice(headerStart + 2, 4));
        var frameIndex = BinaryPrimitives.ReadUInt32BigEndian(envelope.Slice(headerStart + 6, 4));
        var pts = BinaryPrimitives.ReadUInt64BigEndian(envelope.Slice(headerStart + 10, 8));

        var afterHeader = headerStart + MediaFrame.HeaderByteCount;
        CursorMetadata? cursor = null;
        if (flags.HasFlag(MediaFrameFlags.HasCursorMetadata))
        {
            var cursorEnd = afterHeader + MediaFrame.CursorMetadataByteCount;
            if (cursorEnd > LengthPrefixBytes + totalPayloadCount)
            {
                throw new MediaPacketCodecException(
                    MediaPacketCodecError.CursorTruncated,
                    "cursor extension runs past declared payload");
            }

            var cursorX = BinaryPrimitives.ReadInt16BigEndian(envelope.Slice(afterHeader, 2));
            var cursorY = BinaryPrimitives.ReadInt16BigEndian(envelope.Slice(afterHeader + 2, 2));
            cursor = new CursorMetadata(cursorX, cursorY);
            afterHeader = cursorEnd;
        }

        var payloadStart = afterHeader;
        var payloadEnd = LengthPrefixBytes + totalPayloadCount;
        var payload = envelope.Slice(payloadStart, payloadEnd - payloadStart).ToArray();

        var frame = new MediaFrame(kind, flags, gopId, frameIndex, pts, cursor, payload);
        return new MediaPacketDecodeResult(frame, totalEnvelopeBytes);
    }
}

/// <summary>Result of <see cref="MediaPacketCodec.Decode"/>: the frame + bytes consumed.</summary>
public readonly struct MediaPacketDecodeResult
{
    public MediaFrame Frame { get; }

    public int Consumed { get; }

    public MediaPacketDecodeResult(MediaFrame frame, int consumed)
    {
        Frame = frame;
        Consumed = consumed;
    }
}

/// <summary>Codec error taxonomy (parity: MediaPacketCodec.CodecError).</summary>
public enum MediaPacketCodecError
{
    EnvelopeTooShort,
    PayloadTooLarge,
    HeaderTruncated,
    UnknownKind,
    CursorTruncated,
}

public sealed class MediaPacketCodecException : Exception
{
    public MediaPacketCodecError Error { get; }

    public int? Actual { get; }

    public int? Max { get; }

    public byte? UnknownKind { get; }

    public MediaPacketCodecException(
        MediaPacketCodecError error,
        string message,
        int? actual = null,
        int? max = null,
        byte? unknownKind = null)
        : base(message)
    {
        Error = error;
        Actual = actual;
        Max = max;
        UnknownKind = unknownKind;
    }
}

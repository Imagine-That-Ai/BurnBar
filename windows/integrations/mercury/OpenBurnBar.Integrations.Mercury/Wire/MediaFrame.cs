using System;
using System.Linq;

namespace OpenBurnBar.Integrations.Mercury.Wire;

/// <summary>
/// Binary media-frame envelope used by the per-GOP video / per-packet audio
/// stream classes. Byte-exact port of
/// <c>OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaFrame.swift</c>.
///
/// Fixed 18-byte header:
/// <code>
/// |  0 .. 0  | frame type   (u8)
/// |  1 .. 1  | flags        (u8)  bit0 keyframe; bit1 end-of-GOP; bit2 muted; bit3 hasCursor
/// |  2 .. 5  | gop id       (u32 BE)
/// |  6 .. 9  | frame index  (u32 BE)
/// | 10 .. 17 | pts millis   (u64 BE)
/// | 18 .. .. | encoded payload
/// </code>
/// When <see cref="MediaFrameFlags.HasCursorMetadata"/> is set, four extra bytes
/// (i16 cursorX + i16 cursorY, big-endian) follow the header before the payload.
/// </summary>
public sealed class MediaFrame : IEquatable<MediaFrame>
{
    /// <summary>Fixed header size in bytes (parity: MediaFrame.headerByteCount).</summary>
    public const int HeaderByteCount = 18;

    /// <summary>Trailing bytes appended after the header when the cursor flag is set.</summary>
    public const int CursorMetadataByteCount = 4;

    public MediaFrameKind Kind { get; }

    public MediaFrameFlags Flags { get; }

    public uint GopId { get; }

    public uint FrameIndex { get; }

    public ulong PresentationTimestampMillis { get; }

    /// <summary>
    /// Cursor coordinates in display pixels at capture time. Encoded inline on
    /// the wire as two big-endian i16 immediately after the header when
    /// <see cref="MediaFrameFlags.HasCursorMetadata"/> is set; <c>null</c> otherwise.
    /// </summary>
    public CursorMetadata? Cursor { get; }

    public byte[] Payload { get; }

    public MediaFrame(
        MediaFrameKind kind,
        MediaFrameFlags flags = MediaFrameFlags.None,
        uint gopId = 0,
        uint frameIndex = 0,
        ulong presentationTimestampMillis = 0,
        CursorMetadata? cursor = null,
        byte[]? payload = null)
    {
        Kind = kind;
        Flags = flags;
        GopId = gopId;
        FrameIndex = frameIndex;
        PresentationTimestampMillis = presentationTimestampMillis;
        Cursor = cursor;
        Payload = payload ?? Array.Empty<byte>();
    }

    public bool Equals(MediaFrame? other)
    {
        if (other is null)
        {
            return false;
        }

        if (ReferenceEquals(this, other))
        {
            return true;
        }

        return Kind == other.Kind
            && Flags == other.Flags
            && GopId == other.GopId
            && FrameIndex == other.FrameIndex
            && PresentationTimestampMillis == other.PresentationTimestampMillis
            && Nullable.Equals(Cursor, other.Cursor)
            && Payload.SequenceEqual(other.Payload);
    }

    public override bool Equals(object? obj) => Equals(obj as MediaFrame);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Kind);
        hash.Add(Flags);
        hash.Add(GopId);
        hash.Add(FrameIndex);
        hash.Add(PresentationTimestampMillis);
        hash.Add(Cursor);
        hash.Add(Payload.Length);
        return hash.ToHashCode();
    }
}

/// <summary>Frame kinds (parity: MediaFrame.Kind).</summary>
public enum MediaFrameKind : byte
{
    VideoNal = 0x01,
    AudioOpus = 0x02,
    BweFeedback = 0x10,
    SessionControl = 0x20,
}

/// <summary>Frame flag bits (parity: MediaFrame.Flags OptionSet).</summary>
[Flags]
public enum MediaFrameFlags : byte
{
    None = 0,

    /// <summary>First frame of a new GOP — the receiver can re-anchor its decoder here.</summary>
    Keyframe = 1 << 0,

    /// <summary>Last frame of the current GOP.</summary>
    EndOfGroup = 1 << 1,

    /// <summary>Audio frame produced while the local mic is muted (kept for clock alignment).</summary>
    Muted = 1 << 2,

    /// <summary>Frame carries 4 trailing cursor bytes (i16 x + i16 y, big-endian).</summary>
    HasCursorMetadata = 1 << 3,
}

/// <summary>Cursor coordinates in display pixels (parity: MediaFrame.CursorMetadata).</summary>
public readonly struct CursorMetadata : IEquatable<CursorMetadata>
{
    public short X { get; }

    public short Y { get; }

    public CursorMetadata(short x, short y)
    {
        X = x;
        Y = y;
    }

    public bool Equals(CursorMetadata other) => X == other.X && Y == other.Y;

    public override bool Equals(object? obj) => obj is CursorMetadata other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(X, Y);
}

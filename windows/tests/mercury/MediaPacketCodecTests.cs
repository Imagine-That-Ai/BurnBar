using System;
using OpenBurnBar.Integrations.Mercury.Wire;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class MediaPacketCodecTests
{
    [Fact]
    public void Encode_ProducesByteExactWireLayout()
    {
        var frame = new MediaFrame(
            MediaFrameKind.VideoNal,
            MediaFrameFlags.Keyframe,
            gopId: 0x01020304,
            frameIndex: 0x05060708,
            presentationTimestampMillis: 0x0102030405060708,
            payload: new byte[] { 0xAA, 0xBB });

        var envelope = new MediaPacketCodec().Encode(frame);

        var expected = new byte[]
        {
            0x00, 0x00, 0x00, 0x14, // total payload length = 18 + 2 = 20
            0x01, // kind = videoNAL
            0x01, // flags = keyframe
            0x01, 0x02, 0x03, 0x04, // gopId (BE)
            0x05, 0x06, 0x07, 0x08, // frameIndex (BE)
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // pts (BE)
            0xAA, 0xBB, // payload
        };
        Assert.Equal(expected, envelope);
    }

    [Fact]
    public void EncodeDecode_RoundTripsAllFields()
    {
        var frame = new MediaFrame(
            MediaFrameKind.AudioOpus,
            MediaFrameFlags.EndOfGroup | MediaFrameFlags.Muted,
            gopId: 42,
            frameIndex: 7,
            presentationTimestampMillis: 123_456_789,
            payload: new byte[] { 1, 2, 3, 4, 5 });

        var codec = new MediaPacketCodec();
        var decoded = codec.Decode(codec.Encode(frame));

        Assert.Equal(frame, decoded.Frame);
        Assert.Equal(4 + 18 + 5, decoded.Consumed);
    }

    [Fact]
    public void Encode_WithCursorFlag_AppendsFourBigEndianBytes()
    {
        var frame = new MediaFrame(
            MediaFrameKind.VideoNal,
            MediaFrameFlags.HasCursorMetadata,
            cursor: new CursorMetadata(-2, 300),
            payload: new byte[] { 0x99 });

        var codec = new MediaPacketCodec();
        var envelope = codec.Encode(frame);

        // total = 18 header + 4 cursor + 1 payload = 23
        Assert.Equal(0x17, envelope[3]);
        // cursor sits immediately after the 18-byte header (offset 4 + 18 = 22)
        Assert.Equal(new byte[] { 0xFF, 0xFE }, envelope[22..24]); // -2 BE
        Assert.Equal(new byte[] { 0x01, 0x2C }, envelope[24..26]); // 300 BE

        var decoded = codec.Decode(envelope);
        Assert.Equal(new CursorMetadata(-2, 300), decoded.Frame.Cursor);
        Assert.Equal(new byte[] { 0x99 }, decoded.Frame.Payload);
    }

    [Fact]
    public void Encode_HonorsCursorFlagEvenWhenCursorNull_WritesZeroZero()
    {
        var frame = new MediaFrame(MediaFrameKind.VideoNal, MediaFrameFlags.HasCursorMetadata);
        var codec = new MediaPacketCodec();

        var decoded = codec.Decode(codec.Encode(frame));

        Assert.Equal(new CursorMetadata(0, 0), decoded.Frame.Cursor);
    }

    [Fact]
    public void Decode_TwoBackToBackFrames_ConsumedAdvancesStream()
    {
        var codec = new MediaPacketCodec();
        var first = codec.Encode(new MediaFrame(MediaFrameKind.VideoNal, payload: new byte[] { 1 }));
        var second = codec.Encode(new MediaFrame(MediaFrameKind.AudioOpus, payload: new byte[] { 2, 3 }));
        var stream = new byte[first.Length + second.Length];
        Array.Copy(first, stream, first.Length);
        Array.Copy(second, 0, stream, first.Length, second.Length);

        var d1 = codec.Decode(stream);
        Assert.Equal(first.Length, d1.Consumed);
        var d2 = codec.Decode(stream.AsSpan(d1.Consumed));
        Assert.Equal(MediaFrameKind.AudioOpus, d2.Frame.Kind);
        Assert.Equal(new byte[] { 2, 3 }, d2.Frame.Payload);
    }

    [Fact]
    public void Encode_PayloadOverMax_Throws()
    {
        var codec = new MediaPacketCodec(maxPayloadBytes: 20);
        var frame = new MediaFrame(MediaFrameKind.VideoNal, payload: new byte[10]);
        var ex = Assert.Throws<MediaPacketCodecException>(() => codec.Encode(frame));
        Assert.Equal(MediaPacketCodecError.PayloadTooLarge, ex.Error);
    }

    [Fact]
    public void Decode_EnvelopeTooShort_Throws()
    {
        var codec = new MediaPacketCodec();
        var ex = Assert.Throws<MediaPacketCodecException>(() => codec.Decode(new byte[] { 0, 0, 0 }));
        Assert.Equal(MediaPacketCodecError.EnvelopeTooShort, ex.Error);
    }

    [Fact]
    public void Decode_DeclaredLongerThanBuffer_Throws()
    {
        var codec = new MediaPacketCodec();
        var envelope = codec.Encode(new MediaFrame(MediaFrameKind.VideoNal, payload: new byte[] { 1, 2, 3 }));
        var truncated = envelope[..^1];
        var ex = Assert.Throws<MediaPacketCodecException>(() => codec.Decode(truncated));
        Assert.Equal(MediaPacketCodecError.HeaderTruncated, ex.Error);
    }

    [Fact]
    public void Decode_UnknownKind_Throws()
    {
        var codec = new MediaPacketCodec();
        var envelope = codec.Encode(new MediaFrame(MediaFrameKind.VideoNal, payload: new byte[] { 1 }));
        envelope[4] = 0x77; // corrupt kind byte
        var ex = Assert.Throws<MediaPacketCodecException>(() => codec.Decode(envelope));
        Assert.Equal(MediaPacketCodecError.UnknownKind, ex.Error);
        Assert.Equal((byte)0x77, ex.UnknownKind!.Value);
    }

    [Fact]
    public void Decode_CursorFlagButPayloadTooShort_Throws()
    {
        // Declared payload length only covers the 18-byte header, but the cursor
        // flag demands 4 more bytes → CursorTruncated.
        var codec = new MediaPacketCodec();
        var envelope = new byte[4 + 18];
        envelope[3] = 18; // total payload length = header only
        envelope[4] = (byte)MediaFrameKind.VideoNal;
        envelope[5] = (byte)MediaFrameFlags.HasCursorMetadata;
        var ex = Assert.Throws<MediaPacketCodecException>(() => codec.Decode(envelope));
        Assert.Equal(MediaPacketCodecError.CursorTruncated, ex.Error);
    }
}

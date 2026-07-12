using System;
using System.Collections.Generic;
using System.Text;
using OpenBurnBar.Integrations.Cast.Protocol;
using OpenBurnBar.Integrations.Cast.Session;
using Xunit;

namespace OpenBurnBar.Integrations.Cast.Tests;

public sealed class CastFramingTests
{
    [Fact]
    public void Encode_ProducesByteExactWireFrame()
    {
        // A deliberately tiny message whose every protobuf byte can be verified
        // by hand against cast_channel.proto.
        var message = new CastMessage
        {
            SourceId = "s",
            DestinationId = "d",
            Namespace = "n",
            PayloadUtf8 = "p",
            Type = CastMessage.PayloadType.String,
        };

        var expected = new byte[]
        {
            0x00, 0x00, 0x00, 0x10, // 4-byte big-endian length prefix = 16
            0x08, 0x00,             // field 1 protocol_version = 0
            0x12, 0x01, 0x73,       // field 2 source_id = "s"
            0x1A, 0x01, 0x64,       // field 3 destination_id = "d"
            0x22, 0x01, 0x6E,       // field 4 namespace = "n"
            0x28, 0x00,             // field 5 payload_type = STRING (0)
            0x32, 0x01, 0x70,       // field 6 payload_utf8 = "p"
        };

        Assert.Equal(expected, CastFraming.Encode(message));
    }

    [Fact]
    public void Encode_LengthPrefixIsBigEndianAndBodySized()
    {
        var message = CastReceiverProtocol.Connect(CastMessage.DefaultDestination);
        var framed = CastFraming.Encode(message);

        var length = ((uint)framed[0] << 24) | ((uint)framed[1] << 16) | ((uint)framed[2] << 8) | framed[3];
        Assert.Equal((uint)(framed.Length - 4), length);
    }

    [Fact]
    public void DecodeBody_RoundTripsARealConnectMessage()
    {
        var original = CastMessage.String(
            CastReceiverProtocol.NamespaceConnection,
            "{\"type\":\"CONNECT\"}",
            "transport-42");

        var framed = CastFraming.Encode(original);
        var body = new byte[framed.Length - 4];
        System.Array.Copy(framed, 4, body, 0, body.Length);

        var decoded = CastFraming.DecodeBody(body);
        Assert.NotNull(decoded);
        Assert.Equal(original, decoded);
    }

    [Fact]
    public void DecodeBody_EmptyBodyUsesTheIntentionalInboundDefaultSwap()
    {
        // The Swift port defaults a decoded (inbound) message's source to the
        // receiver channel and destination to the sender channel.
        var decoded = CastFraming.DecodeBody(System.Array.Empty<byte>());
        Assert.NotNull(decoded);
        Assert.Equal(CastMessage.DefaultDestination, decoded!.SourceId);
        Assert.Equal(CastMessage.DefaultSource, decoded.DestinationId);
        Assert.Equal(string.Empty, decoded.Namespace);
        Assert.Equal(CastMessage.PayloadType.String, decoded.Type);
    }

    [Fact]
    public void DecodeBody_SkipsUnknownFieldsWithoutFailing()
    {
        // Known field 2 = "x", then an unknown field 9 (wire type 0 varint = 300),
        // then field 4 namespace = "y". The unknown field must be skipped.
        var body = new List<byte>
        {
            0x12, 0x01, 0x78,             // field 2 source_id = "x"
            0x48, 0xAC, 0x02,             // field 9 varint (0x48 = (9<<3)|0), value 300
            0x22, 0x01, 0x79,             // field 4 namespace = "y"
        };

        var decoded = CastFraming.DecodeBody(body.ToArray());
        Assert.NotNull(decoded);
        Assert.Equal("x", decoded!.SourceId);
        Assert.Equal("y", decoded.Namespace);
    }

    [Fact]
    public void FrameBuffer_ReturnsNullUntilAWholeFrameArrives()
    {
        var message = CastReceiverProtocol.GetStatus(7);
        var framed = CastFraming.Encode(message);
        var buffer = new CastFrameBuffer();

        // Feed all but the last byte — no frame yet.
        buffer.Append(framed.AsSpan(0, framed.Length - 1));
        Assert.False(buffer.TryReadFrame(out var partial));
        Assert.Null(partial);

        // Feed the last byte — now it decodes.
        buffer.Append(framed.AsSpan(framed.Length - 1, 1));
        Assert.True(buffer.TryReadFrame(out var complete));
        Assert.NotNull(complete);
        Assert.Equal(CastReceiverProtocol.NamespaceReceiver, complete!.Namespace);
    }

    [Fact]
    public void FrameBuffer_DrainsMultipleConcatenatedFrames()
    {
        var first = CastReceiverProtocol.Connect(CastMessage.DefaultDestination);
        var second = CastReceiverProtocol.Ping();
        var buffer = new CastFrameBuffer();
        buffer.Append(CastFraming.Encode(first));
        buffer.Append(CastFraming.Encode(second));

        var drained = buffer.DrainDecodable();
        Assert.Equal(2, drained.Count);
        Assert.Equal(CastReceiverProtocol.NamespaceConnection, drained[0].Namespace);
        Assert.Equal(CastReceiverProtocol.NamespaceHeartbeat, drained[1].Namespace);
        Assert.Equal(0, buffer.BufferedByteCount);
    }

    [Fact]
    public void Encode_PayloadUtf8IsUtf8Encoded()
    {
        var message = CastMessage.String("n", "café ☕", "d");
        var framed = CastFraming.Encode(message);
        var decoded = CastFraming.DecodeBody(framed.AsSpan(4).ToArray());
        Assert.NotNull(decoded);
        Assert.Equal("café ☕", decoded!.PayloadUtf8);
        // Ensure the payload really was multibyte on the wire.
        Assert.Contains(Encoding.UTF8.GetBytes("☕"), b => System.Array.IndexOf(framed, b) >= 0);
    }
}

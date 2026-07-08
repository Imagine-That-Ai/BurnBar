// Parity source: AgentLens/Services/Cast/CastMessageFraming.swift (enum CastFraming + wire helpers)

using System;
using System.Collections.Generic;
using System.Text;

namespace OpenBurnBar.Integrations.Cast.Protocol;

/// <summary>
/// Hand-rolled CASTV2 wire codec. Each frame is a 4-byte big-endian length
/// prefix followed by a hand-encoded <c>CastMessage</c> protobuf body — the
/// schema is small and stable, so we avoid a build-time protobuf codegen step.
/// This is a byte-for-byte port of the Swift <c>CastFraming</c>.
/// </summary>
public static class CastFraming
{
    /// <summary>
    /// Encode a <see cref="CastMessage"/> into on-the-wire framed bytes:
    /// 4-byte big-endian length + protobuf body.
    /// </summary>
    public static byte[] Encode(CastMessage message)
    {
        if (message is null)
        {
            throw new ArgumentNullException(nameof(message));
        }

        var body = new List<byte>(64);

        // Field 1: protocol_version = CASTV2_1_0 (0). Tag = (1<<3)|0 = 0x08.
        body.Add(0x08);
        body.Add(0x00);

        // Field 2: source_id (string). Tag = (2<<3)|2 = 0x12.
        AppendLengthDelimited(body, 0x12, Encoding.UTF8.GetBytes(message.SourceId));
        // Field 3: destination_id. Tag = (3<<3)|2 = 0x1A.
        AppendLengthDelimited(body, 0x1A, Encoding.UTF8.GetBytes(message.DestinationId));
        // Field 4: namespace. Tag = (4<<3)|2 = 0x22.
        AppendLengthDelimited(body, 0x22, Encoding.UTF8.GetBytes(message.Namespace));
        // Field 5: payload_type = enum varint. Tag = (5<<3)|0 = 0x28.
        body.Add(0x28);
        AppendVarint(body, (ulong)message.Type);
        // Field 6: payload_utf8. Tag = (6<<3)|2 = 0x32.
        if (message.Type == CastMessage.PayloadType.String)
        {
            AppendLengthDelimited(body, 0x32, Encoding.UTF8.GetBytes(message.PayloadUtf8));
        }

        var framed = new byte[4 + body.Count];
        var length = (uint)body.Count;
        // 4-byte big-endian length prefix.
        framed[0] = (byte)((length >> 24) & 0xFF);
        framed[1] = (byte)((length >> 16) & 0xFF);
        framed[2] = (byte)((length >> 8) & 0xFF);
        framed[3] = (byte)(length & 0xFF);
        body.CopyTo(framed, 4);
        return framed;
    }

    /// <summary>
    /// Decode a <c>CastMessage</c> body (post-length-prefix). Returns
    /// <see langword="null"/> if a field is malformed and cannot be skipped.
    /// Visible for tests.
    /// </summary>
    public static CastMessage? DecodeBody(byte[] data)
    {
        if (data is null)
        {
            throw new ArgumentNullException(nameof(data));
        }

        // NOTE: The Swift port intentionally defaults sourceId to the receiver
        // channel and destinationId to the sender channel, because a *decoded*
        // message is inbound (its source is the receiver). Preserve that exactly.
        var sourceId = CastMessage.DefaultDestination;
        var destinationId = CastMessage.DefaultSource;
        var @namespace = string.Empty;
        var payloadType = CastMessage.PayloadType.String;
        var payloadUtf8 = string.Empty;

        var index = 0;
        while (index < data.Length)
        {
            var tag = data[index];
            index += 1;
            var fieldNumber = tag >> 3;
            var wireType = tag & 0x07;

            switch (fieldNumber, wireType)
            {
                case (1, 0): // protocol_version
                    if (ReadVarint(data, ref index) is null)
                    {
                        return null;
                    }

                    break;
                case (2, 2):
                    sourceId = ReadString(data, ref index) ?? sourceId;
                    break;
                case (3, 2):
                    destinationId = ReadString(data, ref index) ?? destinationId;
                    break;
                case (4, 2):
                    @namespace = ReadString(data, ref index) ?? @namespace;
                    break;
                case (5, 0):
                    var raw = ReadVarint(data, ref index);
                    if (raw is { } value && Enum.IsDefined(typeof(CastMessage.PayloadType), (int)value))
                    {
                        payloadType = (CastMessage.PayloadType)(int)value;
                    }

                    break;
                case (6, 2):
                    payloadUtf8 = ReadString(data, ref index) ?? payloadUtf8;
                    break;
                case (7, 2):
                    // payload_binary — skip; we don't use it.
                    if (ReadLengthDelimited(data, ref index) is null)
                    {
                        return null;
                    }

                    break;
                default:
                    if (!SkipUnknown(data, ref index, wireType))
                    {
                        return null;
                    }

                    break;
            }
        }

        return new CastMessage
        {
            SourceId = sourceId,
            DestinationId = destinationId,
            Namespace = @namespace,
            PayloadUtf8 = payloadUtf8,
            Type = payloadType,
        };
    }

    // MARK: - Varint / wire helpers

    private static void AppendVarint(List<byte> data, ulong value)
    {
        var v = value;
        while (v >= 0x80)
        {
            data.Add((byte)((v & 0x7F) | 0x80));
            v >>= 7;
        }

        data.Add((byte)v);
    }

    private static void AppendLengthDelimited(List<byte> data, byte tag, byte[] value)
    {
        data.Add(tag);
        AppendVarint(data, (ulong)value.Length);
        data.AddRange(value);
    }

    internal static ulong? ReadVarint(byte[] data, ref int index)
    {
        ulong result = 0;
        var shift = 0;
        while (index < data.Length)
        {
            var b = data[index];
            index += 1;
            result |= (ulong)(b & 0x7F) << shift;
            if ((b & 0x80) == 0)
            {
                return result;
            }

            shift += 7;
            if (shift > 63)
            {
                return null;
            }
        }

        return null;
    }

    private static byte[]? ReadLengthDelimited(byte[] data, ref int index)
    {
        var len = ReadVarint(data, ref index);
        if (len is null)
        {
            return null;
        }

        var end = index + (int)len.Value;
        if (end > data.Length || end < index)
        {
            return null;
        }

        var slice = new byte[end - index];
        Array.Copy(data, index, slice, 0, slice.Length);
        index = end;
        return slice;
    }

    private static string? ReadString(byte[] data, ref int index)
    {
        var bytes = ReadLengthDelimited(data, ref index);
        if (bytes is null)
        {
            return null;
        }

        try
        {
            return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true)
                .GetString(bytes);
        }
        catch (ArgumentException)
        {
            // Match Swift's String(data:encoding:.utf8) returning nil on invalid UTF-8.
            return null;
        }
    }

    private static bool SkipUnknown(byte[] data, ref int index, int wireType)
    {
        switch (wireType)
        {
            case 0:
                return ReadVarint(data, ref index) is not null;
            case 2:
                return ReadLengthDelimited(data, ref index) is not null;
            case 5:
                index += 4;
                return index <= data.Length;
            case 1:
                index += 8;
                return index <= data.Length;
            default:
                return false;
        }
    }
}

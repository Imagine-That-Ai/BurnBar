// Parity source: AgentLens/Services/Cast/CastTLSConnection.swift (receiveBuffer + drainBuffer)
// and CastMessageFraming.swift (decode(from: inout Data))

using System;
using System.Collections.Generic;
using OpenBurnBar.Integrations.Cast.Protocol;

namespace OpenBurnBar.Integrations.Cast.Session;

/// <summary>
/// Streaming reassembly buffer for the length-prefixed CASTV2 wire format. A
/// socket appends raw bytes as they arrive and drains whole frames; partial
/// frames stay buffered until the rest lands. Port of the Swift
/// <c>CastFraming.decode(from: inout Data)</c> + <c>drainBuffer</c> loop.
/// </summary>
public sealed class CastFrameBuffer
{
    private readonly List<byte> _buffer = new();

    /// <summary>Number of bytes currently buffered (not yet consumed as a frame).</summary>
    public int BufferedByteCount => _buffer.Count;

    /// <summary>Append freshly-received bytes to the reassembly buffer.</summary>
    public void Append(ReadOnlySpan<byte> bytes)
    {
        foreach (var b in bytes)
        {
            _buffer.Add(b);
        }
    }

    /// <summary>
    /// Try to consume one complete frame from the head of the buffer. Returns
    /// <see langword="false"/> (leaving the buffer intact) when fewer than a
    /// full frame's bytes are present. A frame whose body fails to decode is
    /// still consumed and yields <see langword="null"/> in <paramref name="message"/>.
    /// </summary>
    public bool TryReadFrame(out CastMessage? message)
    {
        message = null;
        if (_buffer.Count < 4)
        {
            return false;
        }

        var length = ((uint)_buffer[0] << 24)
                     | ((uint)_buffer[1] << 16)
                     | ((uint)_buffer[2] << 8)
                     | _buffer[3];

        var total = 4L + length;
        if (_buffer.Count < total)
        {
            return false;
        }

        var body = new byte[length];
        _buffer.CopyTo(4, body, 0, (int)length);
        _buffer.RemoveRange(0, (int)total);

        message = CastFraming.DecodeBody(body);
        return true;
    }

    /// <summary>Drain every complete frame currently buffered.</summary>
    public IReadOnlyList<CastMessage> DrainDecodable()
    {
        var messages = new List<CastMessage>();
        while (TryReadFrame(out var message))
        {
            if (message is not null)
            {
                messages.Add(message);
            }
        }

        return messages;
    }
}

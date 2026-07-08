// Length-prefixed framing for the signed-nonce handshake over a duplex stream.
//
// Serializes NonceChallenge / SignedNonceResponse to and from a PipeStream. Kept
// deliberately dumb — fixed field order, u16 length prefixes, a frame-type byte —
// so both the daemon (NamedPipePeerAuthListener) and the app
// (NamedPipePeerAuthConnector) speak the identical bytes. The transcript that is
// actually signed lives in the portable OpenBurnBar.Pal.Ipc.HandshakeTranscript;
// this only moves the challenge/response envelopes across the pipe.
//
// Scaffold for VAL-P0-CONPTY-018; live pipe round-trip is VAL-P0-CONPTY-019.

using System;
using System.Buffers.Binary;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Pal.Ipc;

namespace OpenBurnBar.Pal.Ipc.Windows;

internal static class HandshakeWire
{
    private const byte FrameChallenge = 0x01;
    private const byte FrameResponse = 0x02;
    private const int MaxFieldBytes = 64 * 1024;

    public static async Task WriteChallengeAsync(
        Stream stream, NonceChallenge challenge, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        buffer.WriteByte(FrameChallenge);
        WriteBytes(buffer, challenge.Nonce);
        WriteInt64(buffer, challenge.IssuedAtUnixMs);
        WriteInt64(buffer, challenge.TtlMs);
        buffer.WriteByte((byte)challenge.ChallengerRole);
        await FlushFrameAsync(stream, buffer, ct).ConfigureAwait(false);
    }

    public static async Task<NonceChallenge> ReadChallengeAsync(Stream stream, CancellationToken ct)
    {
        byte frame = await ReadByteAsync(stream, ct).ConfigureAwait(false);
        if (frame != FrameChallenge)
        {
            throw new IOException($"Expected challenge frame, got 0x{frame:X2}.");
        }

        byte[] nonce = await ReadBytesAsync(stream, ct).ConfigureAwait(false);
        long issuedAt = await ReadInt64Async(stream, ct).ConfigureAwait(false);
        long ttl = await ReadInt64Async(stream, ct).ConfigureAwait(false);
        var role = (HandshakeRole)await ReadByteAsync(stream, ct).ConfigureAwait(false);
        return new NonceChallenge(nonce, issuedAt, ttl, role);
    }

    public static async Task WriteResponseAsync(
        Stream stream, SignedNonceResponse response, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        buffer.WriteByte(FrameResponse);
        WriteBytes(buffer, response.Nonce);
        WriteBytes(buffer, response.Signature);
        await FlushFrameAsync(stream, buffer, ct).ConfigureAwait(false);
    }

    public static async Task<SignedNonceResponse> ReadResponseAsync(Stream stream, CancellationToken ct)
    {
        byte frame = await ReadByteAsync(stream, ct).ConfigureAwait(false);
        if (frame != FrameResponse)
        {
            throw new IOException($"Expected response frame, got 0x{frame:X2}.");
        }

        byte[] nonce = await ReadBytesAsync(stream, ct).ConfigureAwait(false);
        byte[] signature = await ReadBytesAsync(stream, ct).ConfigureAwait(false);
        return new SignedNonceResponse(nonce, signature);
    }

    // ── field helpers ─────────────────────────────────────────────────────────
    private static void WriteBytes(Stream s, byte[] value)
    {
        if (value.Length > MaxFieldBytes)
        {
            throw new IOException($"Field of {value.Length} bytes exceeds {MaxFieldBytes}.");
        }

        Span<byte> len = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16LittleEndian(len, (ushort)value.Length);
        s.Write(len);
        s.Write(value, 0, value.Length);
    }

    private static void WriteInt64(Stream s, long value)
    {
        Span<byte> buf = stackalloc byte[8];
        BinaryPrimitives.WriteInt64LittleEndian(buf, value);
        s.Write(buf);
    }

    private static async Task FlushFrameAsync(Stream stream, MemoryStream buffer, CancellationToken ct)
    {
        byte[] payload = buffer.ToArray();
        await stream.WriteAsync(payload, ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    private static async Task<byte[]> ReadBytesAsync(Stream stream, CancellationToken ct)
    {
        byte[] lenBuf = await ReadExactAsync(stream, 2, ct).ConfigureAwait(false);
        int len = BinaryPrimitives.ReadUInt16LittleEndian(lenBuf);
        if (len > MaxFieldBytes)
        {
            throw new IOException($"Declared field length {len} exceeds {MaxFieldBytes}.");
        }

        return len == 0 ? Array.Empty<byte>() : await ReadExactAsync(stream, len, ct).ConfigureAwait(false);
    }

    private static async Task<long> ReadInt64Async(Stream stream, CancellationToken ct)
    {
        byte[] buf = await ReadExactAsync(stream, 8, ct).ConfigureAwait(false);
        return BinaryPrimitives.ReadInt64LittleEndian(buf);
    }

    private static async Task<byte> ReadByteAsync(Stream stream, CancellationToken ct)
    {
        byte[] one = await ReadExactAsync(stream, 1, ct).ConfigureAwait(false);
        return one[0];
    }

    private static async Task<byte[]> ReadExactAsync(Stream stream, int count, CancellationToken ct)
    {
        var buffer = new byte[count];
        int read = 0;
        while (read < count)
        {
            int n = await stream.ReadAsync(buffer.AsMemory(read, count - read), ct).ConfigureAwait(false);
            if (n == 0)
            {
                throw new EndOfStreamException($"Pipe closed after {read}/{count} bytes.");
            }

            read += n;
        }

        return buffer;
    }
}

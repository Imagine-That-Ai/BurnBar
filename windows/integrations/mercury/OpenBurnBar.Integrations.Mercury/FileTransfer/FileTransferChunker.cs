using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using OpenBurnBar.Integrations.Mercury.Wire;

namespace OpenBurnBar.Integrations.Mercury.FileTransfer;

/// <summary>
/// Content-addressed file-transfer chunker + reassembler for the Mercury blob
/// lane. The macOS side rides iroh-blobs
/// (<c>OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaFileTransferService.swift</c>),
/// which content-addresses a file and streams fixed-size chunks; this is the
/// portable equivalent that the Windows adapter drives when the native iroh
/// blob backend is unavailable, and the reference the reassembly tests exercise.
///
/// Chunk size defaults to the iroh-blobs / <see cref="MediaPacketCodec"/> chunk
/// ceiling (256 KiB). Each chunk can be framed on the wire via the byte-exact
/// <see cref="MediaPacketCodec"/> (kind = <see cref="MediaFrameKind.SessionControl"/>,
/// gopId = transfer id, frameIndex = chunk index, end-of-group flag on the last
/// chunk), so file transfer reuses the same framing an audit reader already
/// understands.
/// </summary>
public static class FileTransferChunker
{
    /// <summary>Default chunk size (parity: MediaPacketCodec.DefaultMaxPayloadBytes = 256 KiB).</summary>
    public const int DefaultChunkSize = 256 * 1024;

    /// <summary>
    /// Split <paramref name="data"/> into ordered chunks + a manifest that binds
    /// the total length and a SHA-256 of the whole file (content addressing).
    /// An empty input yields zero chunks (the reassembler completes immediately).
    /// </summary>
    public static FileTransferPlan Chunk(byte[] data, uint transferId, int chunkSize = DefaultChunkSize, string? fileName = null)
    {
        if (data is null)
        {
            throw new ArgumentNullException(nameof(data));
        }

        if (chunkSize <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(chunkSize));
        }

        var totalChunks = (data.Length + chunkSize - 1) / chunkSize;
        var chunks = new List<FileTransferChunk>(totalChunks);
        for (var index = 0; index < totalChunks; index++)
        {
            var offset = index * chunkSize;
            var length = Math.Min(chunkSize, data.Length - offset);
            var payload = new byte[length];
            Array.Copy(data, offset, payload, 0, length);
            chunks.Add(new FileTransferChunk(transferId, index, totalChunks, offset, isLast: index == totalChunks - 1, payload));
        }

        var manifest = new FileTransferManifest(transferId, data.Length, chunkSize, totalChunks, Sha256Hex(data), fileName);
        return new FileTransferPlan(manifest, chunks);
    }

    /// <summary>Frame a chunk for the wire via the byte-exact media packet codec.</summary>
    public static byte[] ToFrameEnvelope(FileTransferChunk chunk, MediaPacketCodec? codec = null)
    {
        if (chunk is null)
        {
            throw new ArgumentNullException(nameof(chunk));
        }

        codec ??= new MediaPacketCodec();
        var flags = chunk.IsLast ? MediaFrameFlags.EndOfGroup : MediaFrameFlags.None;
        var frame = new MediaFrame(
            MediaFrameKind.SessionControl,
            flags,
            gopId: chunk.TransferId,
            frameIndex: (uint)chunk.Index,
            payload: chunk.Payload);
        return codec.Encode(frame);
    }

    /// <summary>Parse a chunk back from a wire envelope produced by <see cref="ToFrameEnvelope"/>.</summary>
    public static FileTransferChunk FromFrameEnvelope(ReadOnlySpan<byte> envelope, int totalChunks, MediaPacketCodec? codec = null)
    {
        codec ??= new MediaPacketCodec();
        var decoded = codec.Decode(envelope);
        var frame = decoded.Frame;
        if (frame.Kind != MediaFrameKind.SessionControl)
        {
            throw new InvalidOperationException("frame is not a file-transfer chunk");
        }

        var index = (int)frame.FrameIndex;
        var isLast = frame.Flags.HasFlag(MediaFrameFlags.EndOfGroup);
        var offset = index * DefaultChunkSize;
        return new FileTransferChunk(frame.GopId, index, totalChunks, offset, isLast, frame.Payload);
    }

    internal static string Sha256Hex(ReadOnlySpan<byte> data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
}

/// <summary>Manifest binding a transfer's length + content hash (parity: the attachment manifest).</summary>
public sealed class FileTransferManifest
{
    public uint TransferId { get; }

    public long TotalBytes { get; }

    public int ChunkSize { get; }

    public int TotalChunks { get; }

    public string Sha256Hex { get; }

    public string? FileName { get; }

    public FileTransferManifest(uint transferId, long totalBytes, int chunkSize, int totalChunks, string sha256Hex, string? fileName)
    {
        TransferId = transferId;
        TotalBytes = totalBytes;
        ChunkSize = chunkSize;
        TotalChunks = totalChunks;
        Sha256Hex = sha256Hex;
        FileName = fileName;
    }
}

/// <summary>A single ordered chunk of a file transfer.</summary>
public sealed class FileTransferChunk
{
    public uint TransferId { get; }

    public int Index { get; }

    public int TotalChunks { get; }

    public int Offset { get; }

    public bool IsLast { get; }

    public byte[] Payload { get; }

    public FileTransferChunk(uint transferId, int index, int totalChunks, int offset, bool isLast, byte[] payload)
    {
        TransferId = transferId;
        Index = index;
        TotalChunks = totalChunks;
        Offset = offset;
        IsLast = isLast;
        Payload = payload ?? Array.Empty<byte>();
    }
}

/// <summary>A chunk plan: manifest + ordered chunks.</summary>
public sealed class FileTransferPlan
{
    public FileTransferManifest Manifest { get; }

    public IReadOnlyList<FileTransferChunk> Chunks { get; }

    public FileTransferPlan(FileTransferManifest manifest, IReadOnlyList<FileTransferChunk> chunks)
    {
        Manifest = manifest;
        Chunks = chunks;
    }
}

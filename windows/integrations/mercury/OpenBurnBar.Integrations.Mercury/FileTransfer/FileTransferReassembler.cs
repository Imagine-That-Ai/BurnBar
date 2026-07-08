using System;

namespace OpenBurnBar.Integrations.Mercury.FileTransfer;

/// <summary>
/// Reassembles out-of-order file-transfer chunks into the original bytes,
/// verifying the whole-file length + SHA-256 against the manifest before it will
/// hand back a payload. Rejects wrong-transfer, out-of-range, and mismatched
/// chunks; ignores duplicates; refuses to reassemble until every chunk is
/// present. This is the receiver-side integrity gate for the blob lane.
/// </summary>
public sealed class FileTransferReassembler
{
    private readonly FileTransferManifest _manifest;
    private readonly byte[]?[] _chunks;
    private int _received;

    public FileTransferReassembler(FileTransferManifest manifest)
    {
        _manifest = manifest ?? throw new ArgumentNullException(nameof(manifest));
        _chunks = new byte[]?[Math.Max(0, manifest.TotalChunks)];
    }

    /// <summary>Number of distinct chunks accepted so far.</summary>
    public int ReceivedCount => _received;

    /// <summary>Whether every chunk has been accepted.</summary>
    public bool IsComplete => _received == _manifest.TotalChunks;

    /// <summary>
    /// Accept one chunk. Idempotent per index (a repeat is ignored). Rejects a
    /// chunk from a different transfer or with an out-of-range index.
    /// </summary>
    public FileTransferAcceptResult Accept(FileTransferChunk chunk)
    {
        if (chunk is null)
        {
            throw new ArgumentNullException(nameof(chunk));
        }

        if (chunk.TransferId != _manifest.TransferId)
        {
            return FileTransferAcceptResult.RejectedWrongTransfer;
        }

        if (chunk.Index < 0 || chunk.Index >= _manifest.TotalChunks)
        {
            return FileTransferAcceptResult.RejectedOutOfRange;
        }

        if (_chunks[chunk.Index] is not null)
        {
            return FileTransferAcceptResult.DuplicateIgnored;
        }

        _chunks[chunk.Index] = chunk.Payload;
        _received++;
        return FileTransferAcceptResult.Accepted;
    }

    /// <summary>
    /// Concatenate the accepted chunks in index order and verify the total length
    /// + SHA-256 against the manifest. Throws <see cref="FileTransferReassemblyException"/>
    /// if incomplete, the wrong length, or the content hash does not match
    /// (tamper / corruption).
    /// </summary>
    public byte[] Reassemble()
    {
        if (!IsComplete)
        {
            throw new FileTransferReassemblyException(
                FileTransferReassemblyError.Incomplete,
                $"transfer incomplete: {_received}/{_manifest.TotalChunks} chunks");
        }

        var output = new byte[_manifest.TotalBytes];
        var cursor = 0;
        for (var index = 0; index < _manifest.TotalChunks; index++)
        {
            var payload = _chunks[index]!;
            if (cursor + payload.Length > output.Length)
            {
                throw new FileTransferReassemblyException(
                    FileTransferReassemblyError.LengthMismatch,
                    "reassembled length exceeds manifest total");
            }

            Array.Copy(payload, 0, output, cursor, payload.Length);
            cursor += payload.Length;
        }

        if (cursor != output.Length)
        {
            throw new FileTransferReassemblyException(
                FileTransferReassemblyError.LengthMismatch,
                $"reassembled {cursor} bytes, manifest declared {output.Length}");
        }

        var actualHash = FileTransferChunker.Sha256Hex(output);
        if (!string.Equals(actualHash, _manifest.Sha256Hex, StringComparison.OrdinalIgnoreCase))
        {
            throw new FileTransferReassemblyException(
                FileTransferReassemblyError.HashMismatch,
                "reassembled content hash does not match the manifest");
        }

        return output;
    }
}

/// <summary>Outcome of accepting one chunk.</summary>
public enum FileTransferAcceptResult
{
    Accepted,
    DuplicateIgnored,
    RejectedOutOfRange,
    RejectedWrongTransfer,
}

/// <summary>Reassembly failure taxonomy.</summary>
public enum FileTransferReassemblyError
{
    Incomplete,
    LengthMismatch,
    HashMismatch,
}

public sealed class FileTransferReassemblyException : Exception
{
    public FileTransferReassemblyError Error { get; }

    public FileTransferReassemblyException(FileTransferReassemblyError error, string message)
        : base(message)
    {
        Error = error;
    }
}

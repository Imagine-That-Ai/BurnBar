using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.Integrations.Mercury.FileTransfer;

public enum FileOriginMarkStatus
{
    Marked,
    Unavailable,
    Failed,
}

public sealed record FileOriginMarkResult(FileOriginMarkStatus Status, string Provider, string Detail)
{
    public bool IsMarked => Status == FileOriginMarkStatus.Marked;
}

public interface IInboundFileOriginMarker
{
    ValueTask<FileOriginMarkResult> MarkInternetOriginAsync(
        string filePath,
        string sourcePeerHash,
        CancellationToken cancellationToken = default);
}

public enum FileThreatScanStatus
{
    Clean,
    ThreatDetected,
    Unavailable,
    Error,
}

public sealed record FileThreatScanResult(FileThreatScanStatus Status, string Provider, string Detail, int? ExitCode = null)
{
    public bool IsClean => Status == FileThreatScanStatus.Clean;
}

public interface IInboundFileThreatScanner
{
    bool IsAvailable { get; }

    ValueTask<FileThreatScanResult> ScanAsync(string filePath, CancellationToken cancellationToken = default);
}

public enum InboundFileDisposition
{
    AwaitingUserApproval,
    OriginMarkFailed,
    ScannerUnavailable,
    ThreatDetected,
    ScanFailed,
    Promoted,
    Discarded,
}

public enum InboundQuarantineError
{
    InvalidManifest,
    WrongTransfer,
    InvalidChunk,
    DuplicateChunk,
    Incomplete,
    HashMismatch,
    NotApproved,
    QuarantineFileChanged,
}

public sealed class InboundQuarantineException : Exception
{
    public InboundQuarantineException(InboundQuarantineError error, string message)
        : base(message)
    {
        Error = error;
    }

    public InboundQuarantineError Error { get; }
}

public sealed record QuarantinedInboundFile(
    string QuarantinePath,
    string DestinationDirectory,
    string DisplayName,
    long TotalBytes,
    string Sha256Hex,
    string SourcePeerHash,
    DateTimeOffset QuarantinedAtUtc,
    InboundFileDisposition Disposition,
    FileOriginMarkResult OriginMark,
    FileThreatScanResult? ThreatScan,
    string? PromotedPath = null);

/// <summary>
/// Disk-backed inbound receiver. It verifies every chunk and the complete file,
/// writes into a same-volume hidden quarantine, applies MOTW through the platform
/// marker, and requires a clean threat scan plus an explicit approval before an
/// atomic promotion.
/// </summary>
public sealed class InboundFileQuarantineService
{
    public const long DefaultMaxBytes = int.MaxValue;
    public const int DefaultMaxChunks = 8 * 1024;
    public const int MaxChunkBytes = 4 * 1024 * 1024;
    private const string QuarantineDirectoryName = ".openburnbar-quarantine";

    private readonly IInboundFileOriginMarker _originMarker;
    private readonly IInboundFileThreatScanner _threatScanner;
    private readonly long _maxBytes;
    private readonly Func<DateTimeOffset> _now;

    public InboundFileQuarantineService(
        IInboundFileOriginMarker originMarker,
        IInboundFileThreatScanner threatScanner,
        long maxBytes = DefaultMaxBytes,
        Func<DateTimeOffset>? now = null)
    {
        _originMarker = originMarker ?? throw new ArgumentNullException(nameof(originMarker));
        _threatScanner = threatScanner ?? throw new ArgumentNullException(nameof(threatScanner));
        _maxBytes = maxBytes is >= 0 and <= int.MaxValue
            ? maxBytes
            : throw new ArgumentOutOfRangeException(nameof(maxBytes));
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public async Task<QuarantinedInboundFile> QuarantineAsync(
        FileTransferManifest manifest,
        IEnumerable<FileTransferChunk> chunks,
        string destinationDirectory,
        string sourcePeerId,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        ArgumentNullException.ThrowIfNull(chunks);
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePeerId);
        ValidateManifest(manifest);

        string destination = Path.GetFullPath(destinationDirectory);
        Directory.CreateDirectory(destination);
        string quarantineDirectory = Path.Combine(destination, QuarantineDirectoryName);
        Directory.CreateDirectory(quarantineDirectory);
        TryMarkDirectoryHidden(quarantineDirectory);

        string temporary = Path.Combine(quarantineDirectory, ".incoming-" + Guid.NewGuid().ToString("N") + ".partial");
        string? quarantinePath = null;
        var received = new bool[manifest.TotalChunks];
        int receivedCount = 0;
        try
        {
            using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.ReadWrite,
                FileShare.None,
                FileTransferChunker.DefaultChunkSize,
                FileOptions.RandomAccess | FileOptions.WriteThrough))
            {
                stream.SetLength(manifest.TotalBytes);
                foreach (FileTransferChunk chunk in chunks)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    ValidateChunk(manifest, chunk, received);
                    stream.Position = chunk.Offset;
                    await stream.WriteAsync(chunk.Payload, cancellationToken).ConfigureAwait(false);
                    received[chunk.Index] = true;
                    receivedCount++;
                }

                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            if (receivedCount != manifest.TotalChunks)
            {
                throw new InboundQuarantineException(
                    InboundQuarantineError.Incomplete,
                    $"Inbound transfer is incomplete ({receivedCount}/{manifest.TotalChunks} chunks).");
            }

            string actualHash = FileTransferFileHash.Sha256Hex(temporary);
            if (!string.Equals(actualHash, manifest.Sha256Hex, StringComparison.OrdinalIgnoreCase))
            {
                throw new InboundQuarantineException(
                    InboundQuarantineError.HashMismatch,
                    "Inbound file hash does not match its manifest.");
            }

            string displayName = FileTransferFileName.Sanitize(manifest.FileName);
            string quarantineName = $"{manifest.TransferId:x8}-{actualHash[..12]}-{displayName}.quarantine";
            quarantinePath = Path.Combine(quarantineDirectory, quarantineName);
            File.Move(temporary, quarantinePath, overwrite: false);

            string peerHash = HashPeer(sourcePeerId);
            FileOriginMarkResult origin = await _originMarker
                .MarkInternetOriginAsync(quarantinePath, peerHash, cancellationToken)
                .ConfigureAwait(false);

            FileThreatScanResult? scan = null;
            InboundFileDisposition disposition;
            if (!origin.IsMarked)
            {
                disposition = InboundFileDisposition.OriginMarkFailed;
            }
            else if (!_threatScanner.IsAvailable)
            {
                disposition = InboundFileDisposition.ScannerUnavailable;
            }
            else
            {
                scan = await _threatScanner.ScanAsync(quarantinePath, cancellationToken).ConfigureAwait(false);
                disposition = scan.Status switch
                {
                    FileThreatScanStatus.Clean => InboundFileDisposition.AwaitingUserApproval,
                    FileThreatScanStatus.ThreatDetected => InboundFileDisposition.ThreatDetected,
                    FileThreatScanStatus.Unavailable => InboundFileDisposition.ScannerUnavailable,
                    _ => InboundFileDisposition.ScanFailed,
                };
            }

            File.SetAttributes(quarantinePath, File.GetAttributes(quarantinePath) | FileAttributes.ReadOnly);
            return new QuarantinedInboundFile(
                quarantinePath,
                destination,
                displayName,
                manifest.TotalBytes,
                actualHash,
                peerHash,
                _now(),
                disposition,
                origin,
                scan);
        }
        catch
        {
            TryDelete(temporary);
            if (quarantinePath is not null)
            {
                TryDelete(quarantinePath);
            }
            throw;
        }
    }

    public QuarantinedInboundFile ApproveAndPromote(QuarantinedInboundFile file)
    {
        ArgumentNullException.ThrowIfNull(file);
        if (file.Disposition != InboundFileDisposition.AwaitingUserApproval)
        {
            throw new InboundQuarantineException(
                InboundQuarantineError.NotApproved,
                "Only a clean quarantined file awaiting explicit approval can be promoted.");
        }

        VerifyQuarantinedFile(file);
        string destination = UniqueDestination(file.DestinationDirectory, file.DisplayName);
        File.SetAttributes(file.QuarantinePath, FileAttributes.Normal);
        try
        {
            File.Move(file.QuarantinePath, destination, overwrite: false);
        }
        catch
        {
            if (File.Exists(file.QuarantinePath))
            {
                File.SetAttributes(file.QuarantinePath, File.GetAttributes(file.QuarantinePath) | FileAttributes.ReadOnly);
            }
            throw;
        }
        return file with { Disposition = InboundFileDisposition.Promoted, PromotedPath = destination };
    }

    public QuarantinedInboundFile Discard(QuarantinedInboundFile file)
    {
        ArgumentNullException.ThrowIfNull(file);
        if (file.Disposition == InboundFileDisposition.Promoted)
        {
            throw new InboundQuarantineException(InboundQuarantineError.NotApproved, "A promoted file cannot be discarded from quarantine.");
        }

        TryDelete(file.QuarantinePath);
        return file with { Disposition = InboundFileDisposition.Discarded };
    }

    private void ValidateManifest(FileTransferManifest manifest)
    {
        if (manifest.TotalBytes < 0
            || manifest.TotalBytes > _maxBytes
            || manifest.ChunkSize <= 0
            || manifest.ChunkSize > MaxChunkBytes
            || manifest.TotalChunks < 0
            || manifest.TotalChunks > DefaultMaxChunks)
        {
            throw new InboundQuarantineException(InboundQuarantineError.InvalidManifest, "Inbound manifest is outside transfer limits.");
        }

        int expectedChunks = checked((int)((manifest.TotalBytes + manifest.ChunkSize - 1) / manifest.ChunkSize));
        if (expectedChunks != manifest.TotalChunks
            || manifest.Sha256Hex.Length != 64
            || Array.Exists(manifest.Sha256Hex.ToCharArray(), character => !Uri.IsHexDigit(character)))
        {
            throw new InboundQuarantineException(InboundQuarantineError.InvalidManifest, "Inbound manifest shape is inconsistent.");
        }
    }

    private static void ValidateChunk(FileTransferManifest manifest, FileTransferChunk chunk, bool[] received)
    {
        if (chunk.TransferId != manifest.TransferId)
        {
            throw new InboundQuarantineException(InboundQuarantineError.WrongTransfer, "Inbound chunk belongs to another transfer.");
        }

        if (chunk.Index < 0 || chunk.Index >= manifest.TotalChunks || chunk.TotalChunks != manifest.TotalChunks)
        {
            throw new InboundQuarantineException(InboundQuarantineError.InvalidChunk, "Inbound chunk index is invalid.");
        }

        if (received[chunk.Index])
        {
            throw new InboundQuarantineException(InboundQuarantineError.DuplicateChunk, "Duplicate inbound chunks are rejected.");
        }

        int expectedOffset = checked(chunk.Index * manifest.ChunkSize);
        int expectedLength = (int)Math.Min(manifest.ChunkSize, manifest.TotalBytes - expectedOffset);
        bool expectedLast = chunk.Index == manifest.TotalChunks - 1;
        if (chunk.Offset != expectedOffset || chunk.Payload.Length != expectedLength || chunk.IsLast != expectedLast)
        {
            throw new InboundQuarantineException(InboundQuarantineError.InvalidChunk, "Inbound chunk metadata does not match the manifest.");
        }
    }

    private static void VerifyQuarantinedFile(QuarantinedInboundFile file)
    {
        if (!File.Exists(file.QuarantinePath)
            || new FileInfo(file.QuarantinePath).Length != file.TotalBytes
            || !string.Equals(FileTransferFileHash.Sha256Hex(file.QuarantinePath), file.Sha256Hex, StringComparison.OrdinalIgnoreCase))
        {
            throw new InboundQuarantineException(
                InboundQuarantineError.QuarantineFileChanged,
                "Quarantined file changed after verification.");
        }
    }

    private static string UniqueDestination(string directory, string fileName)
    {
        string candidate = Path.Combine(directory, fileName);
        string stem = Path.GetFileNameWithoutExtension(fileName);
        string extension = Path.GetExtension(fileName);
        for (int suffix = 1; File.Exists(candidate); suffix++)
        {
            candidate = Path.Combine(directory, $"{stem} ({suffix}){extension}");
        }

        return candidate;
    }

    private static string HashPeer(string peerId)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(peerId?.Trim() ?? string.Empty);
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }

    private static void TryMarkDirectoryHidden(string directory)
    {
        try
        {
            File.SetAttributes(directory, File.GetAttributes(directory) | FileAttributes.Hidden);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.SetAttributes(path, FileAttributes.Normal);
                File.Delete(path);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}

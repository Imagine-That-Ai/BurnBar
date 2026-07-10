using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

namespace OpenBurnBar.Integrations.Mercury.FileTransfer;

public enum OutboundSnapshotError
{
    SourceMissing,
    SourceIsReparsePoint,
    SourceTooLarge,
    SourceChanged,
    SnapshotCollision,
    SnapshotOutsideDirectory,
}

public sealed class OutboundSnapshotException : Exception
{
    public OutboundSnapshotException(OutboundSnapshotError error, string message)
        : base(message)
    {
        Error = error;
    }

    public OutboundSnapshotError Error { get; }
}

/// <summary>An immutable, content-addressed copy used as the only outbound transfer source.</summary>
public sealed record OutboundFileSnapshot(
    string SnapshotPath,
    string OriginalFileName,
    long TotalBytes,
    string Sha256Hex,
    DateTimeOffset CreatedAtUtc);

/// <summary>
/// Creates a private snapshot before any transfer begins. The source is opened
/// without write/delete sharing, copied through an incremental SHA-256, checked
/// for metadata drift, atomically named by its content hash, and marked read-only.
/// </summary>
public sealed class OutboundFileSnapshotService
{
    public const long DefaultMaxBytes = int.MaxValue;
    private const int BufferBytes = 128 * 1024;

    private readonly long _maxBytes;
    private readonly Func<DateTimeOffset> _now;

    public OutboundFileSnapshotService(long maxBytes = DefaultMaxBytes, Func<DateTimeOffset>? now = null)
    {
        if (maxBytes is < 0 or > int.MaxValue)
        {
            throw new ArgumentOutOfRangeException(nameof(maxBytes));
        }

        _maxBytes = maxBytes;
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public OutboundFileSnapshot Create(string sourcePath, string snapshotDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        string sourceFull = Path.GetFullPath(sourcePath);
        if (!File.Exists(sourceFull))
        {
            throw new OutboundSnapshotException(OutboundSnapshotError.SourceMissing, "Outbound file is missing.");
        }

        FileAttributes attributes = File.GetAttributes(sourceFull);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new OutboundSnapshotException(
                OutboundSnapshotError.SourceIsReparsePoint,
                "Outbound file links are not accepted; select the regular file instead.");
        }

        var info = new FileInfo(sourceFull);
        return CreateCore(
            info.Name,
            snapshotDirectory,
            streamFactory: () => new FileStream(
                sourceFull,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                BufferBytes,
                FileOptions.SequentialScan),
            sourceMetadata: info);
    }

    public OutboundFileSnapshot Create(ReadOnlySpan<byte> bytes, string fileName, string snapshotDirectory)
    {
        byte[] stableBytes = bytes.ToArray();
        return CreateCore(
            FileTransferFileName.Sanitize(fileName),
            snapshotDirectory,
            streamFactory: () => new MemoryStream(stableBytes, writable: false),
            sourceMetadata: null);
    }

    public bool Release(OutboundFileSnapshot snapshot, string snapshotDirectory)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentException.ThrowIfNullOrWhiteSpace(snapshotDirectory);

        string root = Path.GetFullPath(snapshotDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        string snapshotPath = Path.GetFullPath(snapshot.SnapshotPath);
        StringComparison comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        string expectedPrefix = snapshot.Sha256Hex + "-";
        if (!snapshotPath.StartsWith(root, comparison)
            || !Path.GetFileName(snapshotPath).StartsWith(expectedPrefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new OutboundSnapshotException(
                OutboundSnapshotError.SnapshotOutsideDirectory,
                "Outbound snapshot is outside the managed snapshot directory.");
        }

        if (!File.Exists(snapshotPath))
        {
            return false;
        }

        if (!Matches(snapshotPath, snapshot.TotalBytes, snapshot.Sha256Hex))
        {
            throw new OutboundSnapshotException(
                OutboundSnapshotError.SourceChanged,
                "Outbound snapshot changed before release.");
        }

        File.SetAttributes(snapshotPath, FileAttributes.Normal);
        File.Delete(snapshotPath);
        return true;
    }

    private OutboundFileSnapshot CreateCore(
        string originalFileName,
        string snapshotDirectory,
        Func<Stream> streamFactory,
        FileInfo? sourceMetadata)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(snapshotDirectory);
        string root = Path.GetFullPath(snapshotDirectory);
        Directory.CreateDirectory(root);

        string temporary = Path.Combine(root, ".snapshot-" + Guid.NewGuid().ToString("N") + ".tmp");
        DateTime sourceWriteUtc = sourceMetadata?.LastWriteTimeUtc ?? DateTime.MinValue;
        long expectedLength = sourceMetadata?.Length ?? -1;
        if (expectedLength > _maxBytes)
        {
            throw new OutboundSnapshotException(OutboundSnapshotError.SourceTooLarge, "Outbound file exceeds the transfer size limit.");
        }

        long copied = 0;
        string hash;
        try
        {
            using Stream source = streamFactory();
            if (source.CanSeek)
            {
                expectedLength = source.Length;
                if (expectedLength > _maxBytes)
                {
                    throw new OutboundSnapshotException(OutboundSnapshotError.SourceTooLarge, "Outbound file exceeds the transfer size limit.");
                }
            }

            using var destination = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                BufferBytes,
                FileOptions.SequentialScan | FileOptions.WriteThrough);
            using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[BufferBytes];
            int read;
            while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
            {
                copied = checked(copied + read);
                if (copied > _maxBytes)
                {
                    throw new OutboundSnapshotException(OutboundSnapshotError.SourceTooLarge, "Outbound file exceeds the transfer size limit.");
                }

                destination.Write(buffer, 0, read);
                hasher.AppendData(buffer, 0, read);
            }

            destination.Flush(flushToDisk: true);
            hash = Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant();

            if (expectedLength >= 0 && copied != expectedLength)
            {
                throw new OutboundSnapshotException(OutboundSnapshotError.SourceChanged, "Outbound file changed while it was being snapshotted.");
            }

            if (sourceMetadata is not null)
            {
                sourceMetadata.Refresh();
                if (sourceMetadata.Length != expectedLength || sourceMetadata.LastWriteTimeUtc != sourceWriteUtc)
                {
                    throw new OutboundSnapshotException(OutboundSnapshotError.SourceChanged, "Outbound file changed while it was being snapshotted.");
                }
            }

            string safeName = FileTransferFileName.Sanitize(originalFileName);
            string finalPath = Path.Combine(root, hash + "-" + safeName);
            if (File.Exists(finalPath))
            {
                if (!Matches(finalPath, copied, hash))
                {
                    throw new OutboundSnapshotException(
                        OutboundSnapshotError.SnapshotCollision,
                        "A content-addressed snapshot collision was detected.");
                }

                File.Delete(temporary);
            }
            else
            {
                File.Move(temporary, finalPath, overwrite: false);
            }

            File.SetAttributes(finalPath, File.GetAttributes(finalPath) | FileAttributes.ReadOnly);
            return new OutboundFileSnapshot(finalPath, safeName, copied, hash, _now());
        }
        catch
        {
            TryDelete(temporary);
            throw;
        }
    }

    private static bool Matches(string path, long expectedLength, string expectedHash)
    {
        var info = new FileInfo(path);
        return info.Length == expectedLength
            && string.Equals(FileTransferFileHash.Sha256Hex(path), expectedHash, StringComparison.OrdinalIgnoreCase);
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

/// <summary>Reads bounded chunks from an immutable snapshot without loading the whole file.</summary>
public static class FileTransferSnapshotChunker
{
    public static FileTransferManifest CreateManifest(
        OutboundFileSnapshot snapshot,
        uint transferId,
        int chunkSize = FileTransferChunker.DefaultChunkSize)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (chunkSize <= 0 || chunkSize > InboundFileQuarantineService.MaxChunkBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(chunkSize));
        }

        VerifySnapshot(snapshot);

        int chunks = checked((int)((snapshot.TotalBytes + chunkSize - 1) / chunkSize));
        if (chunks > InboundFileQuarantineService.DefaultMaxChunks)
        {
            throw new ArgumentOutOfRangeException(
                nameof(chunkSize),
                "Chunk size would create a manifest beyond the receiver's bounded chunk count.");
        }

        return new FileTransferManifest(
            transferId,
            snapshot.TotalBytes,
            chunkSize,
            chunks,
            snapshot.Sha256Hex,
            snapshot.OriginalFileName);
    }

    public static IEnumerable<FileTransferChunk> ReadChunks(
        OutboundFileSnapshot snapshot,
        uint transferId,
        int chunkSize = FileTransferChunker.DefaultChunkSize)
    {
        FileTransferManifest manifest = CreateManifest(snapshot, transferId, chunkSize);
        return ReadChunks(snapshot, manifest);
    }

    public static IEnumerable<FileTransferChunk> ReadChunks(
        OutboundFileSnapshot snapshot,
        FileTransferManifest manifest)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(manifest);
        if (manifest.TotalBytes != snapshot.TotalBytes
            || !string.Equals(manifest.Sha256Hex, snapshot.Sha256Hex, StringComparison.OrdinalIgnoreCase))
        {
            throw new OutboundSnapshotException(OutboundSnapshotError.SourceChanged, "Transfer manifest does not match the snapshot.");
        }

        int chunkSize = manifest.ChunkSize;
        using var source = new FileStream(
            snapshot.SnapshotPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            chunkSize,
            FileOptions.SequentialScan);
        for (int index = 0; index < manifest.TotalChunks; index++)
        {
            int expected = (int)Math.Min(chunkSize, manifest.TotalBytes - ((long)index * chunkSize));
            var payload = new byte[expected];
            source.ReadExactly(payload);
            yield return new FileTransferChunk(
                manifest.TransferId,
                index,
                manifest.TotalChunks,
                checked(index * chunkSize),
                isLast: index == manifest.TotalChunks - 1,
                payload);
        }
    }

    private static void VerifySnapshot(OutboundFileSnapshot snapshot)
    {
        if (!File.Exists(snapshot.SnapshotPath)
            || new FileInfo(snapshot.SnapshotPath).Length != snapshot.TotalBytes
            || !string.Equals(FileTransferFileHash.Sha256Hex(snapshot.SnapshotPath), snapshot.Sha256Hex, StringComparison.OrdinalIgnoreCase))
        {
            throw new OutboundSnapshotException(OutboundSnapshotError.SourceChanged, "Outbound snapshot changed before transfer.");
        }
    }
}

internal static class FileTransferFileHash
{
    public static string Sha256Hex(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.SequentialScan);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }
}

internal static class FileTransferFileName
{
    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    public static string Sanitize(string? name)
    {
        string candidate = Path.GetFileName(name ?? string.Empty).Trim().TrimEnd('.', ' ');
        if (candidate.Length == 0)
        {
            candidate = "file";
        }

        char[] invalid = Path.GetInvalidFileNameChars();
        Span<char> output = stackalloc char[Math.Min(candidate.Length, 120)];
        int count = 0;
        foreach (char value in candidate)
        {
            if (count == output.Length)
            {
                break;
            }

            output[count++] = Array.IndexOf(invalid, value) >= 0
                || "<>:\"/\\|?*".IndexOf(value) >= 0
                || char.IsControl(value)
                ? '_'
                : value;
        }

        string result = new(output[..count]);
        string stem = Path.GetFileNameWithoutExtension(result);
        return Reserved.Contains(stem) ? "_" + result : result;
    }
}

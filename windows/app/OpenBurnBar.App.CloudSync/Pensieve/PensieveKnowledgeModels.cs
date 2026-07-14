using System.Text.Json.Serialization;
using OpenBurnBar.CloudSync.Crypto;

namespace OpenBurnBar.App.CloudSync.Pensieve;

public enum PensieveSourceKind
{
    RepoDocs,
    Notes,
    ChatMemory,
}

public static class PensieveSourceKindExtensions
{
    public static string WireValue(this PensieveSourceKind value) => value switch
    {
        PensieveSourceKind.RepoDocs => "repo_docs",
        PensieveSourceKind.Notes => "notes",
        PensieveSourceKind.ChatMemory => "chat_memory",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };
}

public sealed record PensieveWatchRoot(
    string Path,
    PensieveSourceKind SourceKind,
    IReadOnlySet<string> IncludedExtensions)
{
    public PensieveWatchRoot(
        string path,
        PensieveSourceKind sourceKind,
        IEnumerable<string>? includedExtensions = null)
        : this(
            NormalizePath(path),
            sourceKind,
            new HashSet<string>(
                (includedExtensions ?? Array.Empty<string>())
                    .Select(static value => value.Trim().TrimStart('.').ToLowerInvariant())
                    .Where(static value => value.Length > 0),
                StringComparer.OrdinalIgnoreCase))
    {
    }

    private static string NormalizePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException("A Pensieve watch root is required.", nameof(path));
        }

        return System.IO.Path.GetFullPath(path.Trim());
    }
}

public sealed record PensieveKnowledgeVector(
    [property: JsonPropertyName("vectorId")] string VectorId,
    [property: JsonPropertyName("cloakedVector")] IReadOnlyList<double> CloakedVector,
    [property: JsonPropertyName("sealedCiphertext")] CloudVaultSealedText SealedCiphertext,
    [property: JsonPropertyName("sealedMetadata")] CloudVaultSealedText SealedMetadata,
    [property: JsonPropertyName("dedupHash")] string DedupHash,
    [property: JsonPropertyName("sourceKind")] string SourceKind,
    [property: JsonPropertyName("chunkIndex")] int ChunkIndex,
    [property: JsonPropertyName("byteCount")] int ByteCount);

public sealed record PensieveKnowledgeBatch(
    [property: JsonPropertyName("sourceSlug")] string SourceSlug,
    [property: JsonPropertyName("slugHmac")] string SlugHmac,
    [property: JsonPropertyName("embeddingModelVersion")] string EmbeddingModelVersion,
    [property: JsonPropertyName("vectors")] IReadOnlyList<PensieveKnowledgeVector> Vectors);

public enum PensieveWatcherErrorCode
{
    None,
    VaultKeyUnavailable,
    SourceReadFailed,
    QueueWriteFailed,
    WatcherFailed,
}

public sealed record PensieveWatcherStatus(
    bool IsRunning,
    int RootCount,
    DateTimeOffset? LastScanAt,
    DateTimeOffset? LastEnqueueAt,
    int LastEnqueuedCount,
    PensieveWatcherErrorCode ErrorCode);

using System;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;

namespace OpenBurnBar.App.MemorySearch.Search;

// PORTED (faithful) from
//   AgentLens/Services/Search/Embedding/EmbeddingProviderProtocol.swift  (the provider seams)
//   AgentLens/Services/Search/Embedding/EmbeddingTypes.swift             (descriptor + identity)
//   AgentLens/Services/ProjectionPipeline/ProjectionPipelineCore.swift   (ProjectionIdentity.sha256Hex)
//
// The INJECTABLE NETWORK BOUNDARY is `EmbeddingAsync(string) -> Task<float[]>` on both
// IChunkEmbeddingProvider and IQueryEmbeddingProvider — the real (network) OpenAI/BGE/NL
// providers and the deterministic fake both satisfy it. The real network providers are the
// bucket-B adapter; the deterministic provider (DeterministicEmbeddingProvider.cs) is the
// reliable seam that carries CI coverage here.

/// <summary>
/// SHA-256 → lowercase hex string. Swift: <c>ProjectionIdentity.sha256Hex</c>
/// (ProjectionPipelineCore.swift:99-102). Input is the UTF-8 bytes of the string;
/// output is 64 lowercase hex characters. Load-bearing for the deterministic embedding
/// and for stable embedding identity ids.
/// </summary>
public static class ProjectionIdentityHash
{
    public static string Sha256Hex(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(digest).ToLowerInvariant();
    }
}

/// <summary>
/// Describes an embedding model. Swift: <c>struct EmbeddingModelDescriptor</c>. Init
/// normalization is matched: provider/modelName/version tags trimmed; dimensions floored at 1.
/// </summary>
public sealed record EmbeddingModelDescriptor
{
    public string Provider { get; }

    public string ModelName { get; }

    public int Dimensions { get; }

    public EmbeddingDistanceMetric DistanceMetric { get; }

    public string VersionTag { get; }

    public string ChunkerVersion { get; }

    public string NormalizationVersion { get; }

    public string PromptVersion { get; }

    public EmbeddingModelDescriptor(
        string provider,
        string modelName,
        int dimensions,
        EmbeddingDistanceMetric distanceMetric,
        string versionTag,
        string chunkerVersion,
        string normalizationVersion,
        string promptVersion)
    {
        Provider = (provider ?? string.Empty).Trim();
        ModelName = (modelName ?? string.Empty).Trim();
        Dimensions = Math.Max(1, dimensions);
        DistanceMetric = distanceMetric;
        VersionTag = (versionTag ?? string.Empty).Trim();
        ChunkerVersion = (chunkerVersion ?? string.Empty).Trim();
        NormalizationVersion = (normalizationVersion ?? string.Empty).Trim();
        PromptVersion = (promptVersion ?? string.Empty).Trim();
    }
}

/// <summary>
/// Stable ids derived from a descriptor. Swift: <c>enum EmbeddingIdentity</c>. Uses the
/// same lowercase-hex SHA-256 as the deterministic embedding.
/// </summary>
public static class EmbeddingIdentity
{
    /// <summary>Swift: <c>modelID(for:)</c>.</summary>
    public static string ModelId(EmbeddingModelDescriptor descriptor)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        string payload = string.Join(
            "|",
            descriptor.Provider.ToLowerInvariant(),
            descriptor.ModelName.ToLowerInvariant(),
            descriptor.Dimensions.ToString(System.Globalization.CultureInfo.InvariantCulture),
            descriptor.DistanceMetric.RawValue());
        return "embedding-model-" + ProjectionIdentityHash.Sha256Hex(payload);
    }

    /// <summary>Swift: <c>versionID(for:)</c>.</summary>
    public static string VersionId(EmbeddingModelDescriptor descriptor)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        string payload = string.Join(
            "|",
            ModelId(descriptor),
            descriptor.VersionTag.ToLowerInvariant(),
            descriptor.ChunkerVersion.ToLowerInvariant(),
            descriptor.NormalizationVersion.ToLowerInvariant(),
            descriptor.PromptVersion.ToLowerInvariant());
        return "embedding-version-" + ProjectionIdentityHash.Sha256Hex(payload);
    }
}

/// <summary>
/// Indexing-side embedding provider. Swift: <c>protocol ChunkEmbeddingProviding</c>. The
/// <see cref="EmbeddingAsync"/> method is the injectable network boundary.
/// </summary>
public interface IChunkEmbeddingProvider
{
    EmbeddingModelDescriptor Descriptor { get; }

    Task<float[]> EmbeddingAsync(string text);
}

/// <summary>Query-side embedding provider. Swift: <c>protocol QueryEmbeddingProviding</c>.</summary>
public interface IQueryEmbeddingProvider
{
    Task<float[]> EmbeddingAsync(string text);
}

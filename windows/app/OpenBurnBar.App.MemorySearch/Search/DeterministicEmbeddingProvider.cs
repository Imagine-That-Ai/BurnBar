using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading.Tasks;

namespace OpenBurnBar.App.MemorySearch.Search;

// PORTED (bit-for-bit faithful) from
//   AgentLens/Services/Search/Embedding/DeterministicEmbeddingProviders.swift
//     (DeterministicFakeEmbeddingProvider + DeterministicQueryEmbeddingProvider)
//
// This is the deterministic embedding seam used for CI and as the fallback query embedder.
// The single most common porting mistake is byte handling: the per-token hash bytes are the
// UTF-8/ASCII bytes of the 64-char lowercase-hex DIGEST STRING (64 bytes), NOT the 32 raw
// digest bytes. The lane fold constants (131, %31, /30.0, +0.15), sign-by-lane-parity,
// dimensions=96, seed, and weight=1/(position+1) are all matched exactly, and the final
// vector is L2-normalized via VectorMath.L2Normalized. windows/tests/memory-search asserts a
// fixed input yields a fixed 96-float vector to prove parity before anything is wired.

/// <summary>
/// Deterministic embedding provider. Swift: <c>struct DeterministicFakeEmbeddingProvider</c>.
/// Produces reproducible vectors from a seeded per-token SHA-256 hash.
/// </summary>
public sealed class DeterministicEmbeddingProvider : IChunkEmbeddingProvider, IQueryEmbeddingProvider
{
    private readonly string _seed;

    public EmbeddingModelDescriptor Descriptor { get; }

    public DeterministicEmbeddingProvider(
        string provider = "openburnbar",
        string modelName = "deterministic-fake-embedding",
        int dimensions = 96,
        EmbeddingDistanceMetric distanceMetric = EmbeddingDistanceMetric.Cosine,
        string versionTag = "ci-v1",
        string chunkerVersion = "openburnbar-chunker-v1",
        string normalizationVersion = "unit-l2-v1",
        string promptVersion = "plain-text-v1",
        string seed = "openburnbar-deterministic-embedding-seed-v1")
    {
        Descriptor = new EmbeddingModelDescriptor(
            provider,
            modelName,
            dimensions,
            distanceMetric,
            versionTag,
            chunkerVersion,
            normalizationVersion,
            promptVersion);
        _seed = seed;
    }

    /// <summary>Swift: <c>embedding(for:)</c>. Synchronous logic; async only to satisfy the seam.</summary>
    public Task<float[]> EmbeddingAsync(string text) => Task.FromResult(Embed(text));

    /// <summary>The deterministic computation, exposed synchronously for golden tests.</summary>
    public float[] Embed(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        string normalized = text
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Trim()
            .ToLowerInvariant();

        var vector = new float[Descriptor.Dimensions];
        var tokens = Tokenize(normalized);

        // Fallback: when there are no tokens, embed the whole normalized string as one token.
        IReadOnlyList<string> sourceTokens = tokens.Count == 0 ? new[] { normalized } : tokens;
        for (int position = 0; position < sourceTokens.Count; position++)
        {
            string token = sourceTokens[position];
            string payload = _seed + "|" + position.ToString(CultureInfo.InvariantCulture) + "|" + token;
            string digest = ProjectionIdentityHash.Sha256Hex(payload);
            // The bytes are the ASCII bytes of the 64-char hex string, NOT the raw digest.
            byte[] bytes = Encoding.ASCII.GetBytes(digest);
            float weight = 1.0f / Math.Max(1, position + 1);
            Apply(bytes, weight, vector);
        }

        // Swift keeps a `sourceTokens.isEmpty` guard here; the fallback makes it unreachable.
        return VectorMath.L2Normalized(vector);
    }

    /// <summary>Split on whitespace/newline/punctuation, keep non-empty. Swift: the
    /// <c>split(whereSeparator:)</c> + filter in <c>embedding(for:)</c>.</summary>
    private static List<string> Tokenize(string normalized)
    {
        var tokens = new List<string>();
        var builder = new StringBuilder();
        foreach (char ch in normalized)
        {
            if (char.IsWhiteSpace(ch) || char.IsPunctuation(ch))
            {
                if (builder.Length > 0)
                {
                    tokens.Add(builder.ToString());
                    builder.Clear();
                }
            }
            else
            {
                builder.Append(ch);
            }
        }

        if (builder.Length > 0)
        {
            tokens.Add(builder.ToString());
        }

        return tokens;
    }

    /// <summary>The 16-lane fold. Swift: <c>apply(bytes:weight:into:)</c>. Constants exact.</summary>
    private static void Apply(byte[] bytes, float weight, float[] vector)
    {
        if (vector.Length == 0 || bytes.Length == 0)
        {
            return;
        }

        int width = Math.Min(16, bytes.Length);
        for (int lane = 0; lane < width; lane++)
        {
            int index = (bytes[lane] + (lane * 131)) % vector.Length;
            float sign = lane % 2 == 0 ? 1f : -1f;
            float magnitude = ((float)(bytes[lane] % 31) / 30.0f) + 0.15f;
            vector[index] += sign * magnitude * weight;
        }
    }
}

/// <summary>
/// Query embedder backed by a deterministic fake. Swift:
/// <c>final class DeterministicQueryEmbeddingProvider</c>.
/// </summary>
public sealed class DeterministicQueryEmbeddingProvider : IQueryEmbeddingProvider
{
    private readonly DeterministicEmbeddingProvider _embedder;

    public DeterministicQueryEmbeddingProvider(DeterministicEmbeddingProvider? embedder = null)
    {
        _embedder = embedder ?? new DeterministicEmbeddingProvider();
    }

    public EmbeddingModelDescriptor Descriptor => _embedder.Descriptor;

    public Task<float[]> EmbeddingAsync(string text) => _embedder.EmbeddingAsync(text);
}

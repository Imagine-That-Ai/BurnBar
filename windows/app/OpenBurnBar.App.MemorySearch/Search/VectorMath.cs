using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.MemorySearch.Search;

// PORTED (bit-for-bit faithful) from
// AgentLens/Services/Search/VectorSearch/VectorIndexTypes.swift
// (VectorBlobCodec, VectorMath, EmbeddingDistanceMetric, VectorBackendKind, errors, entry/candidate).
//
// The precision discipline is load-bearing and matched exactly:
//   • all accumulation happens in `double` over `float` (Float32) inputs;
//   • euclidean subtracts in Float32 THEN widens ((double)(l - r));
//   • cosine denominator is sqrt(a) * sqrt(b) (two sqrts multiplied, NOT sqrt(a*b));
//   • l2 norm is (float)Math.Sqrt(doubleSum) then Float32 division.
// Reproduce these or you get last-ULP drift on ties (which the canonical
// tiebreak-by-chunkID comparator would then order differently). See
// windows/tests/memory-search for the golden-vector proof.

/// <summary>
/// Distance metric for vector similarity. Swift: <c>enum EmbeddingDistanceMetric</c>
/// (AgentLens/Services/DataStore/DataStoreTypes.swift). Raw values match the Swift
/// String rawValues exactly (used in embedding-version fingerprints).
/// </summary>
public enum EmbeddingDistanceMetric
{
    Cosine,
    DotProduct,
    Euclidean,
}

/// <summary>Lowercase raw-value parity with the Swift <c>String</c>-backed enum.</summary>
public static class EmbeddingDistanceMetricExtensions
{
    public static string RawValue(this EmbeddingDistanceMetric metric) => metric switch
    {
        EmbeddingDistanceMetric.Cosine => "cosine",
        EmbeddingDistanceMetric.DotProduct => "dot_product",
        EmbeddingDistanceMetric.Euclidean => "euclidean",
        _ => "cosine",
    };
}

/// <summary>
/// Codec for encoding/decoding float vectors to/from binary. Swift: <c>VectorBlobCodec</c>.
/// Host-endian Float32 (little-endian on every realistic net8.0 target, matching Apple).
/// </summary>
public static class VectorBlobCodec
{
    /// <summary>Encodes a float vector to bytes; empty vector → empty array. Swift: <c>encode</c>.</summary>
    public static byte[] Encode(IReadOnlyList<float> vector)
    {
        ArgumentNullException.ThrowIfNull(vector);
        if (vector.Count == 0)
        {
            return Array.Empty<byte>();
        }

        var bytes = new byte[vector.Count * sizeof(float)];
        for (int i = 0; i < vector.Count; i++)
        {
            // Little-endian to match Apple host-endian bytes.
            BitConverter.TryWriteBytes(new Span<byte>(bytes, i * sizeof(float), sizeof(float)), vector[i]);
        }

        return bytes;
    }

    /// <summary>
    /// Decodes bytes back to a float vector. Returns <c>null</c> when the buffer is empty
    /// or its length is not a multiple of 4. Swift: <c>decode</c>.
    /// </summary>
    public static float[]? Decode(byte[] data)
    {
        ArgumentNullException.ThrowIfNull(data);
        const int stride = sizeof(float);
        if (data.Length == 0 || data.Length % stride != 0)
        {
            return null;
        }

        int count = data.Length / stride;
        var vector = new float[count];
        for (int i = 0; i < count; i++)
        {
            vector[i] = BitConverter.ToSingle(data, i * stride);
        }

        return vector;
    }
}

/// <summary>
/// Vector similarity math. Swift: <c>enum VectorMath</c>. Every dispatch, guard, and
/// accumulation matches the Swift source exactly (see file header on precision).
/// </summary>
public static class VectorMath
{
    /// <summary>Similarity under the given metric; euclidean is NEGATED so higher = better
    /// for all metrics. Swift: <c>similarity(lhs:rhs:metric:)</c>.</summary>
    public static double Similarity(IReadOnlyList<float> lhs, IReadOnlyList<float> rhs, EmbeddingDistanceMetric metric)
    {
        return metric switch
        {
            EmbeddingDistanceMetric.Cosine => CosineSimilarity(lhs, rhs),
            EmbeddingDistanceMetric.DotProduct => DotProduct(lhs, rhs),
            EmbeddingDistanceMetric.Euclidean => -EuclideanDistance(lhs, rhs),
            _ => CosineSimilarity(lhs, rhs),
        };
    }

    /// <summary>L2-normalizes to unit length. Empty/zero-norm vectors are returned
    /// unchanged. Swift: <c>l2Normalized(_:)</c>. Sum accumulates in double; the norm is
    /// cast to Float32 before the Float32 division — matched exactly.</summary>
    public static float[] L2Normalized(IReadOnlyList<float> vector)
    {
        ArgumentNullException.ThrowIfNull(vector);
        var result = new float[vector.Count];
        if (vector.Count == 0)
        {
            return result;
        }

        double sumSquares = 0;
        for (int i = 0; i < vector.Count; i++)
        {
            double cast = vector[i];
            sumSquares += cast * cast;
        }

        if (!(sumSquares > 0))
        {
            for (int i = 0; i < vector.Count; i++)
            {
                result[i] = vector[i];
            }

            return result;
        }

        float norm = (float)Math.Sqrt(sumSquares);
        if (!(norm > 0))
        {
            for (int i = 0; i < vector.Count; i++)
            {
                result[i] = vector[i];
            }

            return result;
        }

        for (int i = 0; i < vector.Count; i++)
        {
            result[i] = vector[i] / norm;
        }

        return result;
    }

    private static double CosineSimilarity(IReadOnlyList<float> lhs, IReadOnlyList<float> rhs)
    {
        if (lhs.Count != rhs.Count || lhs.Count == 0)
        {
            return 0;
        }

        double dot = 0;
        double lhsNorm = 0;
        double rhsNorm = 0;
        for (int i = 0; i < lhs.Count; i++)
        {
            double l = lhs[i];
            double r = rhs[i];
            dot += l * r;
            lhsNorm += l * l;
            rhsNorm += r * r;
        }

        if (!(lhsNorm > 0) || !(rhsNorm > 0))
        {
            return 0;
        }

        return dot / (Math.Sqrt(lhsNorm) * Math.Sqrt(rhsNorm));
    }

    private static double DotProduct(IReadOnlyList<float> lhs, IReadOnlyList<float> rhs)
    {
        if (lhs.Count != rhs.Count || lhs.Count == 0)
        {
            return 0;
        }

        double dot = 0;
        for (int i = 0; i < lhs.Count; i++)
        {
            dot += (double)lhs[i] * (double)rhs[i];
        }

        return dot;
    }

    private static double EuclideanDistance(IReadOnlyList<float> lhs, IReadOnlyList<float> rhs)
    {
        if (lhs.Count != rhs.Count || lhs.Count == 0)
        {
            return 0;
        }

        double sumSquares = 0;
        for (int i = 0; i < lhs.Count; i++)
        {
            // Float32 subtraction FIRST, then widen to double — matches Swift `Double(lhs - rhs)`.
            double diff = lhs[i] - rhs[i];
            sumSquares += diff * diff;
        }

        return Math.Sqrt(sumSquares);
    }
}

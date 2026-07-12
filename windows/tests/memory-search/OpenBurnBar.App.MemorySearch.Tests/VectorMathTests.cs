using System;
using OpenBurnBar.App.MemorySearch.Search;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// Similarity math parity with Swift <c>VectorMath</c> (VectorIndexTypes.swift). Exact values are
/// hand-verifiable; guards (dimension mismatch, empty, zero-vector) mirror the Swift <c>guard</c>s.
/// </summary>
public sealed class VectorMathTests
{
    [Fact]
    public void Cosine_IdenticalVectors_IsOne()
    {
        var a = new[] { 1f, 2f, 3f };
        Assert.Equal(1.0, VectorMath.Similarity(a, a, EmbeddingDistanceMetric.Cosine), 12);
    }

    [Fact]
    public void Cosine_OrthogonalVectors_IsZero()
    {
        var a = new[] { 1f, 0f };
        var b = new[] { 0f, 1f };
        Assert.Equal(0.0, VectorMath.Similarity(a, b, EmbeddingDistanceMetric.Cosine), 12);
    }

    [Fact]
    public void Cosine_OppositeVectors_IsMinusOne()
    {
        var a = new[] { 1f, 1f };
        var b = new[] { -1f, -1f };
        Assert.Equal(-1.0, VectorMath.Similarity(a, b, EmbeddingDistanceMetric.Cosine), 12);
    }

    [Fact]
    public void Cosine_DimensionMismatch_IsZero()
    {
        Assert.Equal(0.0, VectorMath.Similarity(new[] { 1f, 2f }, new[] { 1f }, EmbeddingDistanceMetric.Cosine));
    }

    [Fact]
    public void Cosine_EmptyVectors_IsZero()
    {
        Assert.Equal(0.0, VectorMath.Similarity(Array.Empty<float>(), Array.Empty<float>(), EmbeddingDistanceMetric.Cosine));
    }

    [Fact]
    public void Cosine_ZeroVector_IsZero()
    {
        Assert.Equal(0.0, VectorMath.Similarity(new[] { 0f, 0f }, new[] { 1f, 2f }, EmbeddingDistanceMetric.Cosine));
    }

    [Fact]
    public void DotProduct_ComputesRawInnerProduct()
    {
        var a = new[] { 1f, 2f, 3f };
        var b = new[] { 4f, 5f, 6f };
        // 4 + 10 + 18 = 32
        Assert.Equal(32.0, VectorMath.Similarity(a, b, EmbeddingDistanceMetric.DotProduct), 12);
    }

    [Fact]
    public void DotProduct_DimensionMismatch_IsZero()
    {
        Assert.Equal(0.0, VectorMath.Similarity(new[] { 1f }, new[] { 1f, 2f }, EmbeddingDistanceMetric.DotProduct));
    }

    [Fact]
    public void Euclidean_IsNegatedDistance_SoHigherIsBetter()
    {
        var a = new[] { 0f, 0f };
        var b = new[] { 3f, 4f };
        // distance 5 → similarity -5
        Assert.Equal(-5.0, VectorMath.Similarity(a, b, EmbeddingDistanceMetric.Euclidean), 12);
    }

    [Fact]
    public void Euclidean_IdenticalVectors_IsZero()
    {
        var a = new[] { 7f, -2f, 0.5f };
        Assert.Equal(0.0, VectorMath.Similarity(a, a, EmbeddingDistanceMetric.Euclidean), 12);
    }

    [Fact]
    public void L2Normalized_ProducesUnitVector()
    {
        var normalized = VectorMath.L2Normalized(new[] { 3f, 4f });
        double norm = Math.Sqrt((normalized[0] * normalized[0]) + (normalized[1] * normalized[1]));
        Assert.Equal(1.0, norm, 6);
        Assert.Equal(0.6f, normalized[0], 5);
        Assert.Equal(0.8f, normalized[1], 5);
    }

    [Fact]
    public void L2Normalized_ZeroVector_ReturnedUnchanged()
    {
        var zero = new[] { 0f, 0f, 0f };
        Assert.Equal(zero, VectorMath.L2Normalized(zero));
    }

    [Fact]
    public void L2Normalized_EmptyVector_ReturnsEmpty()
    {
        Assert.Empty(VectorMath.L2Normalized(Array.Empty<float>()));
    }

    [Fact]
    public void BlobCodec_RoundTrips()
    {
        var vector = new[] { 1.5f, -2.25f, 0f, 3.125f };
        byte[] encoded = VectorBlobCodec.Encode(vector);
        Assert.Equal(vector.Length * 4, encoded.Length);
        Assert.Equal(vector, VectorBlobCodec.Decode(encoded));
    }

    [Fact]
    public void BlobCodec_EmptyEncodesToEmpty_DecodesToNull()
    {
        Assert.Empty(VectorBlobCodec.Encode(Array.Empty<float>()));
        Assert.Null(VectorBlobCodec.Decode(Array.Empty<byte>()));
    }

    [Fact]
    public void BlobCodec_NonMultipleOfFour_DecodesToNull()
    {
        Assert.Null(VectorBlobCodec.Decode(new byte[] { 1, 2, 3 }));
    }

    [Fact]
    public void DistanceMetric_RawValues_MatchSwift()
    {
        Assert.Equal("cosine", EmbeddingDistanceMetric.Cosine.RawValue());
        Assert.Equal("dot_product", EmbeddingDistanceMetric.DotProduct.RawValue());
        Assert.Equal("euclidean", EmbeddingDistanceMetric.Euclidean.RawValue());
    }
}

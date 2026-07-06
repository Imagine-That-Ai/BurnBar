using System;
using System.Security.Cryptography;
using System.Text;
using OpenBurnBar.App.MemorySearch.Search;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// Bit-for-bit parity for the deterministic hash embedding. Swift:
/// <c>DeterministicFakeEmbeddingProvider</c>. The 96-float golden below was produced by an
/// INDEPENDENT Python numpy-float32 reference implementation of the exact algorithm (sha256 →
/// ASCII bytes of the hex digest → 16-lane fold → L2 normalize) and matches the C# port to
/// float32 precision — proving the port reproduces the spec, not just itself. The dim=1 test is a
/// hand-verifiable structural proof of the ASCII-of-hex byte handling (the #1 porting hazard).
/// </summary>
public sealed class DeterministicEmbeddingTests
{
    // Independent Python numpy-float32 reference for embed("hello world"), dims=96.
    private static readonly float[] GoldenHelloWorld =
    {
        0, 0, 0, 0, 0, 0, 0, 0, 0, -0.31610626f, 0, 0, -0.17664762f, -0.14255771f, 0, 0,
        0.08367518f, 0.30370992f, 0, 0, 0, 0, 0, -0.26652095f, -0.13945864f, 0, 0.15805313f, 0, 0, 0, 0, 0,
        -0.15495405f, 0, 0, 0, 0, 0, 0, 0.1301614f, 0, -0.08367518f, 0, 0, 0, 0.052684378f, 0.34089887f, 0,
        0, 0, 0.16735037f, 0, 0.0061981557f, 0, 0, 0, 0.012396311f, 0, 0, 0.13326047f, 0, 0, 0, 0,
        0.058882535f, 0, 0, 0.27891728f, 0, 0, 0, 0.105368756f, 0, 0, 0.18284577f, 0, 0, 0, 0,
        -0.15805313f, -0.105368756f, 0, 0, -0.071278855f, 0, 0, 0, 0, -0.32850257f, 0.21693566f, 0, 0, 0, 0,
        -0.27891728f, -0.1456568f,
    };

    [Fact]
    public void Embed_HelloWorld_MatchesIndependentReferenceGolden()
    {
        var vector = new DeterministicEmbeddingProvider().Embed("hello world");
        Assert.Equal(96, vector.Length);
        for (int i = 0; i < GoldenHelloWorld.Length; i++)
        {
            Assert.Equal(GoldenHelloWorld[i], vector[i], 6);
        }
    }

    [Fact]
    public void Embed_IsDeterministic()
    {
        var provider = new DeterministicEmbeddingProvider();
        Assert.Equal(provider.Embed("the quick brown fox"), provider.Embed("the quick brown fox"));
    }

    [Fact]
    public void Embed_NonEmpty_IsUnitLength()
    {
        var vector = new DeterministicEmbeddingProvider().Embed("burn bar memory search");
        double norm = 0;
        foreach (float v in vector)
        {
            norm += (double)v * v;
        }

        Assert.Equal(1.0, Math.Sqrt(norm), 5);
    }

    [Fact]
    public void Embed_NormalizesCaseAndPunctuation_SameTokens_SameVector()
    {
        var provider = new DeterministicEmbeddingProvider();
        // Both normalize+tokenize to ["hello", "world"].
        Assert.Equal(provider.Embed("Hello, World!"), provider.Embed("  hello   world  "));
    }

    [Fact]
    public void Embed_EmptyString_UsesNormalizedFallbackToken_AndIsDeterministic()
    {
        var provider = new DeterministicEmbeddingProvider();
        var a = provider.Embed("");
        var b = provider.Embed("   ");
        Assert.Equal(96, a.Length);
        Assert.Equal(a, b); // both trim to "" → single fallback token ""
    }

    [Fact]
    public void Embed_Dimension1_MatchesHandComputedAsciiOfHexFold()
    {
        const int dims = 1;
        const string seed = "openburnbar-deterministic-embedding-seed-v1";
        var provider = new DeterministicEmbeddingProvider(dimensions: dims);

        // Independently recompute the single component from the ASCII bytes of the hex digest.
        string payload = seed + "|0|abc";
        string digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(payload))).ToLowerInvariant();
        byte[] bytes = Encoding.ASCII.GetBytes(digest);

        float sum = 0f;
        for (int lane = 0; lane < 16; lane++)
        {
            float sign = lane % 2 == 0 ? 1f : -1f;
            float magnitude = ((float)(bytes[lane] % 31) / 30.0f) + 0.15f;
            sum += sign * magnitude * 1.0f; // weight = 1/(0+1)
        }

        float expected = sum / MathF.Abs(sum); // L2 of a 1-D vector is its sign
        Assert.Equal(expected, provider.Embed("abc")[0], 6);
    }

    [Fact]
    public void Descriptor_HasExpectedDefaults()
    {
        var descriptor = new DeterministicEmbeddingProvider().Descriptor;
        Assert.Equal("openburnbar", descriptor.Provider);
        Assert.Equal("deterministic-fake-embedding", descriptor.ModelName);
        Assert.Equal(96, descriptor.Dimensions);
        Assert.Equal(EmbeddingDistanceMetric.Cosine, descriptor.DistanceMetric);
    }

    [Fact]
    public void Sha256Hex_IsLowercaseHexOfUtf8()
    {
        // "abc" → known SHA-256.
        Assert.Equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ProjectionIdentityHash.Sha256Hex("abc"));
    }

    [Fact]
    public void EmbeddingIdentity_IsStableAndPrefixed()
    {
        var descriptor = new DeterministicEmbeddingProvider().Descriptor;
        string modelId = EmbeddingIdentity.ModelId(descriptor);
        string versionId = EmbeddingIdentity.VersionId(descriptor);
        Assert.StartsWith("embedding-model-", modelId);
        Assert.StartsWith("embedding-version-", versionId);
        Assert.Equal(modelId, EmbeddingIdentity.ModelId(descriptor)); // stable
    }
}

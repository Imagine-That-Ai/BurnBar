using System.Text;
using System.Text.Json;
using OpenBurnBar.App.CloudSync.Pensieve;
using OpenBurnBar.CloudSync.Crypto;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

public sealed class PensieveKnowledgeChunkerTests
{
    private static readonly byte[] Key = Enumerable.Repeat((byte)0x42, 32).ToArray();

    [Fact]
    public void KeyedDigests_MatchIndependentTypeScriptReferences()
    {
        const string text = "BurnBar seals chunk text on device before it ever reaches the cloud.";
        Assert.Equal(
            "b37f513b9aa71e599623073b842c0a5e630abaad37f23e074ef93e41a8c07045",
            CloudVaultCrypto.PensieveDedupHash(text, Key));
        Assert.Equal(
            "85f04130dd91ccde32e00d8ee372aa06480799e1dfadce5336503099b93f6935",
            CloudVaultCrypto.PensieveSlugHmac("notes-security-md", Key));
    }

    [Fact]
    public void PrepareBatch_SealsTextMetadataAndCleartextSideChannels()
    {
        string secret = "sk-" + new string('A', 24);
        PensieveKnowledgeBatch batch = PensieveKnowledgeChunker.PrepareBatch(
            $"BurnBar uses {secret} only as a redaction fixture.",
            PensieveSourceKind.Notes,
            "notes/security.md",
            "notes-security-md",
            Key,
            title: "Security note",
            category: "architecture");

        PensieveKnowledgeVector vector = Assert.Single(batch.Vectors);
        Assert.Equal(384, vector.CloakedVector.Count);
        Assert.Equal(vector.DedupHash, vector.VectorId);
        Assert.Equal("notes", vector.SourceKind);
        Assert.Matches("^[a-f0-9]{64}$", vector.DedupHash);
        string plaintext = CloudVaultCrypto.OpenText(vector.SealedCiphertext, Key);
        Assert.Contains("[REDACTED_API_KEY]", plaintext, StringComparison.Ordinal);
        Assert.DoesNotContain(secret, plaintext, StringComparison.Ordinal);
        string metadata = CloudVaultCrypto.OpenText(vector.SealedMetadata, Key);
        using JsonDocument metadataJson = JsonDocument.Parse(metadata);
        Assert.Equal("notes/security.md", metadataJson.RootElement.GetProperty("source_path").GetString());
        Assert.Equal("architecture", metadataJson.RootElement.GetProperty("category").GetString());

        string wire = JsonSerializer.Serialize(batch);
        Assert.DoesNotContain(secret, wire, StringComparison.Ordinal);
        Assert.DoesNotContain("notes/security.md", wire, StringComparison.Ordinal);
    }

    [Fact]
    public void Chunk_RespectsUtf8CeilingForWhitespaceAndUnbrokenUnicode()
    {
        string text = string.Join(' ', Enumerable.Repeat("knowledge", 2_000));
        string unbroken = new('x', 4_000);
        foreach (string chunk in PensieveKnowledgeChunker.Chunk(text, 1_024)
                     .Concat(PensieveKnowledgeChunker.Chunk(unbroken, 1_024)))
        {
            Assert.InRange(Encoding.UTF8.GetByteCount(chunk), 1, 1_024);
        }
    }

    [Fact]
    public void SplitForCommit_EnforcesServerBatchLimitWithoutChangingEnvelopeIdentity()
    {
        var vector = new PensieveKnowledgeVector(
            new string('a', 64),
            new double[384],
            CloudVaultCrypto.SealText("text", Key),
            CloudVaultCrypto.SealText("{}", Key),
            new string('a', 64),
            "notes",
            0,
            4);
        var batch = new PensieveKnowledgeBatch(
            "notes",
            new string('b', 64),
            PensieveVectorCloak.DeterministicModelVersion,
            Enumerable.Repeat(vector, 1_601).ToArray());

        IReadOnlyList<PensieveKnowledgeBatch> partitions = PensieveKnowledgeChunker.SplitForCommit(batch);

        Assert.Equal(new[] { 800, 800, 1 }, partitions.Select(partition => partition.Vectors.Count));
        Assert.All(partitions, partition =>
        {
            Assert.Equal(batch.SourceSlug, partition.SourceSlug);
            Assert.Equal(batch.SlugHmac, partition.SlugHmac);
            Assert.Equal(batch.EmbeddingModelVersion, partition.EmbeddingModelVersion);
        });
    }

    [Theory]
    [InlineData("My Repo/Docs Folder!", "my-repo-docs-folder")]
    [InlineData("  trailing--dashes--  ", "trailing-dashes")]
    [InlineData("UPPER_case", "upper-case")]
    [InlineData("naïve café résumé", "na-ve-caf-r-sum")]
    public void Slugify_MatchesServerContract(string input, string expected) =>
        Assert.Equal(expected, PensieveKnowledgeChunker.Slugify(input));
}

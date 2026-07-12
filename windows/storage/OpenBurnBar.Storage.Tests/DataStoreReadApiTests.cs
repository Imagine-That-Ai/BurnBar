using System;
using System.Linq;
using Xunit;
using Xunit.Abstractions;

namespace OpenBurnBar.Storage.Tests;

/// <summary>
/// Exercises the DataStore-shaped read seam (<see cref="IConversationReadStore"/>)
/// against the committed Mac fixture — the Windows side of the DataStore seam the
/// Engine calls via the PAL. Proves the opened database is not just decryptable
/// but faithfully queryable through the typed API the port will consume.
/// </summary>
public sealed class DataStoreReadApiTests
{
    private readonly ITestOutputHelper _output;

    public DataStoreReadApiTests(ITestOutputHelper output)
    {
        _output = output;
    }

    private static OpenBurnBarStorage Open() =>
        OpenBurnBarStorage.OpenReadOnly(RepoFixtures.FixturePath, SqlCipherParameters.FixturePassphrase);

    [Fact]
    public void SchemaInventory_ContainsConversationsAndFtsShadows()
    {
        using var storage = Open();

        var objects = storage.ListSchemaObjects();
        Assert.Equal(storage.CountSchemaObjects(), objects.Count);
        _output.WriteLine($"sqlite_master objects = {objects.Count}");

        var names = objects.Select(o => o.Name).ToHashSet(StringComparer.Ordinal);
        Assert.Contains("conversations", names);
        Assert.Contains("conversations_fts", names);
        // FTS5 external-content shadow tables must be present (proves the virtual table decrypted).
        Assert.Contains("conversations_fts_data", names);
        Assert.Contains("conversations_fts_idx", names);
    }

    [Fact]
    public void GetConversation_ReturnsSeededCorpusRow()
    {
        using var storage = Open();

        var beta = storage.GetConversation("conv-beta-run");
        Assert.NotNull(beta);
        Assert.Equal("Claude Code", beta!.Provider);
        Assert.Equal("s-beta", beta.SessionId);
        Assert.Equal("ByteCompat", beta.ProjectName);
        Assert.Equal("Beta Running Log", beta.InferredTaskTitle);
        Assert.Contains("running shoes", beta.FullText, StringComparison.Ordinal);

        Assert.Null(storage.GetConversation("does-not-exist"));
    }

    [Fact]
    public void ListConversations_ReturnsAllThreeSeededRows()
    {
        using var storage = Open();

        var all = storage.ListConversations();
        var ids = all.Select(c => c.Id).ToHashSet(StringComparer.Ordinal);
        Assert.Contains("conv-alpha-fox", ids);
        Assert.Contains("conv-beta-run", ids);
        Assert.Contains("conv-gamma-db", ids);
    }

    [Fact]
    public void SearchConversationsFts_RanksBetaBeforeAlphaForRun()
    {
        using var storage = Open();

        var results = storage.SearchConversationsFts("run");
        Assert.Equal(
            new[] { "conv-beta-run", "conv-alpha-fox" },
            results.Select(r => r.Conversation.Id));

        // bm25 rank is ascending (more relevant first) → beta's rank <= alpha's rank.
        Assert.True(results[0].Rank <= results[1].Rank);
        // snippet() wraps the matched stem.
        Assert.Contains("<b>", results[0].Snippet, StringComparison.Ordinal);
    }

    [Fact]
    public void SearchConversationsFts_CaseFoldsTitleColumn()
    {
        using var storage = Open();

        var results = storage.SearchConversationsFts("GAMMA");
        Assert.Single(results);
        Assert.Equal("conv-gamma-db", results[0].Conversation.Id);
    }
}

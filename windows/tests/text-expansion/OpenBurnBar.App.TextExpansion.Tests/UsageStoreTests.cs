using System;
using System.Linq;
using Xunit;

namespace OpenBurnBar.App.TextExpansion.Tests;

/// <summary>Mirrors Swift <c>testTextExpansionUsageStoreRankingAndIncrementing</c>.</summary>
public sealed class UsageStoreTests
{
    [Fact]
    public void Rank_FallsBackToCaseInsensitiveTitle_WhenNoUsage()
    {
        var alpha = new TextExpansionSnippet(title: "Alpha", trigger: "alpha", body: "Body A");
        var beta = new TextExpansionSnippet(title: "Beta", trigger: "beta", body: "Body B");
        var gamma = new TextExpansionSnippet(title: "Gamma", trigger: "gamma", body: "Body C");
        var snippets = new[] { beta, gamma, alpha };

        var ranked = TextExpansionUsageRanker.Rank(snippets, new TextExpansionUsageLog());
        Assert.Equal(new[] { "Alpha", "Beta", "Gamma" }, ranked.Select(s => s.Title));
    }

    [Fact]
    public void Rank_OrdersByCountThenRecencyThenTitle()
    {
        var alpha = new TextExpansionSnippet(title: "Alpha", trigger: "alpha", body: "Body A");
        var beta = new TextExpansionSnippet(title: "Beta", trigger: "beta", body: "Body B");
        var gamma = new TextExpansionSnippet(title: "Gamma", trigger: "gamma", body: "Body C");
        var snippets = new[] { beta, gamma, alpha };

        var log = new TextExpansionUsageLog();

        var dateB = DateTimeOffset.UtcNow;
        log = log.Incrementing(beta.Id, dateB);
        Assert.Equal(1, log.Record(beta.Id)!.Count);
        Assert.Equal(dateB, log.Record(beta.Id)!.LastUsedAt);

        // Beta now ranks first on higher count.
        var ranked2 = TextExpansionUsageRanker.Rank(snippets, log);
        Assert.Equal(new[] { "Beta", "Alpha", "Gamma" }, ranked2.Select(s => s.Title));

        // Gamma ties Beta's count but is newer → Gamma, Beta, Alpha.
        var dateC = dateB.AddSeconds(10);
        log = log.Incrementing(gamma.Id, dateC);
        var ranked3 = TextExpansionUsageRanker.Rank(snippets, log);
        Assert.Equal(new[] { "Gamma", "Beta", "Alpha" }, ranked3.Select(s => s.Title));
    }

    [Fact]
    public void Incrementing_AdvancesLastUsedToMax_AndIsImmutable()
    {
        var snippet = new TextExpansionSnippet(title: "A", trigger: "aa", body: "b");
        var original = new TextExpansionUsageLog();
        var newer = DateTimeOffset.UtcNow;
        var once = original.Incrementing(snippet.Id, newer);

        // A later increment with an EARLIER timestamp keeps the max lastUsedAt.
        var twice = once.Incrementing(snippet.Id, newer.AddSeconds(-100));
        Assert.Equal(2, twice.Record(snippet.Id)!.Count);
        Assert.Equal(newer, twice.Record(snippet.Id)!.LastUsedAt);

        // The original log is untouched (value semantics).
        Assert.Null(original.Record(snippet.Id));
    }
}

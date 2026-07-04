using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Real coverage for the ported ranking engine
/// (AgentLens/Views/Settings/Search/SettingsSearchEngine.swift): weighted token hits,
/// AND-semantics, tie-break, limit, folding.
/// </summary>
public sealed class SettingsSearchEngineTests
{
    private static SettingsItem Item(
        string id,
        string title,
        string? subtitle = null,
        IReadOnlyList<string>? keywords = null,
        string? helpText = null,
        SettingsTab tab = SettingsTab.General,
        SettingsPageRoute route = SettingsPageRoute.Appearance,
        string? anchor = null) =>
        new(
            id: id,
            tab: tab,
            pageRoute: route,
            anchorId: anchor ?? id,
            title: title,
            subtitle: subtitle,
            keywords: keywords,
            helpText: helpText);

    [Fact]
    public void EmptyOrWhitespaceQuery_YieldsNoResults()
    {
        var items = new[] { Item("a", "Theme") };
        Assert.Empty(SettingsSearchEngine.Search("", items));
        Assert.Empty(SettingsSearchEngine.Search("   \t ", items));
    }

    [Fact]
    public void TitleHit_OutranksKeywordHit()
    {
        var titleMatch = Item("title", "Glass Transparency");
        var keywordMatch = Item("kw", "Something Else", keywords: new[] { "glass" });

        var results = SettingsSearchEngine.Search("glass", new[] { keywordMatch, titleMatch });

        Assert.Equal(2, results.Count);
        Assert.Equal("title", results[0].Id); // title weight 3 > keyword weight 2
        Assert.Equal("kw", results[1].Id);
    }

    [Fact]
    public void Weights_AreTitle3Keyword2Subtitle2HelpText1()
    {
        var titleOnly = Item("t", "glass");                               // 3
        var keywordOnly = Item("k", "zzz", keywords: new[] { "glass" });   // 2
        var subtitleOnly = Item("s", "zzz", subtitle: "glass");            // 2
        var helpOnly = Item("h", "zzz", helpText: "glass");               // 1

        Assert.Equal(3, SettingsSearchEngine.Score(titleOnly, new[] { "glass" }));
        Assert.Equal(2, SettingsSearchEngine.Score(keywordOnly, new[] { "glass" }));
        Assert.Equal(2, SettingsSearchEngine.Score(subtitleOnly, new[] { "glass" }));
        Assert.Equal(1, SettingsSearchEngine.Score(helpOnly, new[] { "glass" }));
    }

    [Fact]
    public void MultiFieldHit_SumsWeights()
    {
        // "glass" hits title (3) + keyword (2) + subtitle (2) + helpText (1) = 8.
        var item = Item("m", "Glass", subtitle: "glass surface", keywords: new[] { "glass" }, helpText: "glass blur");
        Assert.Equal(8, SettingsSearchEngine.Score(item, new[] { "glass" }));
    }

    [Fact]
    public void AndSemantics_EveryTokenMustHitSomeField()
    {
        // "port" hits, "zzz" hits nothing → whole row disqualified.
        var item = Item("p", "Gateway Port", keywords: new[] { "tcp" });
        Assert.Null(SettingsSearchEngine.Score(item, new[] { "port", "zzz" }));
        Assert.NotNull(SettingsSearchEngine.Score(item, new[] { "port", "gateway" }));
    }

    [Fact]
    public void AndSemantics_TokensMaySpanDifferentFields()
    {
        // "gateway" in title, "tcp" in keywords → qualifies (3 + 2 = 5).
        var item = Item("g", "Gateway Port", keywords: new[] { "tcp", "8317" });
        Assert.Equal(5, SettingsSearchEngine.Score(item, new[] { "gateway", "tcp" }));
    }

    [Fact]
    public void TieBreak_IsFoldedTitleAscending()
    {
        // Both match "sync" via keyword only (score 2). Tie breaks by title ascending.
        var beta = Item("b", "Beta Sync", keywords: new[] { "sync" });
        var alpha = Item("a", "Alpha Sync", keywords: new[] { "sync" });

        var results = SettingsSearchEngine.Search("sync", new[] { beta, alpha });

        Assert.Equal(new[] { "a", "b" }, results.Select(r => r.Id).ToArray());
    }

    [Fact]
    public void Limit_CapsResultCount()
    {
        var items = Enumerable.Range(0, 40)
            .Select(i => Item($"i{i:D2}", $"Widget {i:D2}", keywords: new[] { "widget" }))
            .ToArray();

        Assert.Equal(25, SettingsSearchEngine.Search("widget", items).Count); // default limit
        Assert.Equal(5, SettingsSearchEngine.Search("widget", items, limit: 5).Count);
    }

    [Fact]
    public void Fold_IsCaseAndDiacriticInsensitive()
    {
        var item = Item("c", "Café Ambiance");
        // Query without accent + different case must still hit the accented title.
        Assert.NotNull(SettingsSearchEngine.Score(item, SettingsSearchEngine.Tokenize("CAFE").ToList()));
        Assert.Equal("cafe ambiance", SettingsSearchEngine.Fold("Café Ambiance"));
    }

    [Fact]
    public void Tokenize_SplitsOnWhitespaceAndDropsEmpties()
    {
        Assert.Equal(new[] { "gateway", "port" }, SettingsSearchEngine.Tokenize("  Gateway   PORT ").ToArray());
        Assert.Empty(SettingsSearchEngine.Tokenize("   "));
    }

    [Fact]
    public void SubstringMatch_NotOnlyWholeWord()
    {
        // "trans" is a substring of "transparency".
        var item = Item("t", "Liquid Glass Transparency");
        Assert.Equal(3, SettingsSearchEngine.Score(item, new[] { "trans" }));
    }
}

using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Real integrity + parity coverage for the ported manifest
/// (AgentLens/Views/Settings/Search/SettingsManifest.swift): row counts, unique ids,
/// anchor coverage, and the generated per-provider rows.
/// </summary>
public sealed class SettingsManifestTests
{
    [Fact]
    public void RowCounts_MatchTheSwiftManifest()
    {
        // 72 hand-authored base rows (29 + 26 + 17) + 37 generated provider rows.
        Assert.Equal(72, SettingsManifest.BaseItems.Count);
        Assert.Equal(37, SettingsManifest.ProviderItems.Count);
        Assert.Equal(109, SettingsManifest.All.Count);
        Assert.Equal(37, AgentProviderMetadata.AllCases.Count);
    }

    [Fact]
    public void All_IsBaseItemsThenProviderItems()
    {
        var expected = SettingsManifest.BaseItems.Concat(SettingsManifest.ProviderItems).Select(i => i.Id);
        Assert.Equal(expected, SettingsManifest.All.Select(i => i.Id));
    }

    [Fact]
    public void EveryItemId_IsUnique()
    {
        var ids = SettingsManifest.All.Select(i => i.Id).ToArray();
        Assert.Equal(ids.Length, ids.Distinct().Count());
    }

    [Fact]
    public void EveryItem_HasTitleAndAnchor()
    {
        Assert.All(SettingsManifest.All, item =>
        {
            Assert.False(string.IsNullOrWhiteSpace(item.Title));
            Assert.False(string.IsNullOrWhiteSpace(item.AnchorId));
        });
    }

    [Fact]
    public void EveryIndexedAnchor_HasAVisibleScrollTarget()
    {
        // The macOS coverage invariant: search cannot index a setting with no anchor.
        var indexed = SettingsManifest.All.Select(i => i.AnchorId).ToHashSet();
        var visible = SettingsManifest.VisibleAnchorIDs.ToHashSet();
        Assert.True(indexed.IsSubsetOf(visible),
            "indexed anchors missing a visible scroll target: " +
            string.Join(", ", indexed.Except(visible)));
    }

    [Fact]
    public void AnchorIndex_MapsEveryItemAnchorToItsRoute()
    {
        foreach (var item in SettingsManifest.All)
        {
            Assert.True(SettingsManifest.AnchorIndex.ContainsKey(item.AnchorId));
        }
        // Spot-check a concrete mapping.
        Assert.Equal(SettingsPageRoute.Appearance, SettingsManifest.AnchorIndex[SettingsAnchor.AppearanceGlassTransparency]);
    }

    [Fact]
    public void ProviderItems_AreSortedByDisplayNameCaseInsensitive()
    {
        var titles = SettingsManifest.ProviderItems.Select(i => i.Title).ToArray();
        var sorted = titles.OrderBy(t => t, StringComparer.InvariantCultureIgnoreCase).ToArray();
        Assert.Equal(sorted, titles);
    }

    [Fact]
    public void ProviderItems_HaveUniqueIdsAnchorsAndAgentsRoute()
    {
        Assert.Equal(37, SettingsManifest.ProviderItems.Select(i => i.Id).Distinct().Count());
        Assert.Equal(37, SettingsManifest.ProviderItems.Select(i => i.AnchorId).Distinct().Count());
        Assert.All(SettingsManifest.ProviderItems, item =>
        {
            Assert.Equal(SettingsTab.Agents, item.Tab);
            Assert.Equal(SettingsPageRoute.AgentsAccounts, item.PageRoute);
            Assert.StartsWith("agents.account.", item.AnchorId);
            Assert.Single(item.LogoProviders);
        });
    }

    [Fact]
    public void OpenCodeProviderRow_UsesTheSpecialCasedId()
    {
        var openCode = SettingsManifest.ProviderItems.Single(i => i.Title == "OpenCode");
        Assert.Equal("providers.openCode", openCode.Id);           // special-cased in Swift
        Assert.Equal("agents.account.opencode", openCode.AnchorId); // persistedToken anchor
    }

    [Fact]
    public void ProviderKeywords_AreDedupedSortedAndCarryIdentityTokens()
    {
        var claude = SettingsManifest.ProviderItems.Single(i => i.Title == "Claude Code");

        // Sorted ordinal + de-duplicated.
        Assert.Equal(claude.Keywords.OrderBy(k => k, StringComparer.Ordinal), claude.Keywords);
        Assert.Equal(claude.Keywords.Count, claude.Keywords.Distinct().Count());

        // Identity tokens present: persistedToken, providerID.rawValue, and per-provider synonyms.
        Assert.Contains("claudecode", claude.Keywords);   // persistedToken
        Assert.Contains("claude-code", claude.Keywords);  // providerID.rawValue (differs from token)
        Assert.Contains("anthropic", claude.Keywords);
        Assert.Contains("opus", claude.Keywords);
        // Base keyword net.
        Assert.Contains("provider", claude.Keywords);
        Assert.Contains("failover", claude.Keywords);
    }

    [Fact]
    public void CursorAgentProviderRow_CarriesHyphenatedProviderId()
    {
        var cursorAgent = SettingsManifest.ProviderItems.Single(i => i.Title == "Cursor Agent");
        Assert.Contains("cursoragent", cursorAgent.Keywords);   // persistedToken
        Assert.Contains("cursor-agent", cursorAgent.Keywords);  // providerID.rawValue
    }

    [Fact]
    public void ProviderRows_SearchableByFriendlySynonyms()
    {
        // "moonshot" is a Kimi synonym; the Kimi provider row should surface.
        var results = SettingsSearchEngine.Search("moonshot", SettingsManifest.All);
        Assert.Contains(results, r => r.Title == "Kimi");
    }
}

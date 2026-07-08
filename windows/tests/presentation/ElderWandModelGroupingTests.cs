using System.Linq;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real, macOS-runnable tests for the ported grouping pass
/// (windows/app/OpenBurnBar.App.Presentation/ElderWand/ElderWandModelGrouping.cs), parity
/// with the ElderWandModelGrouping enum in ElderWandConfiguratorView.swift.
/// </summary>
public sealed class ElderWandModelGroupingTests
{
    private static ElderWandAdvertisedModel Model(
        string id, string title, bool eligible = true, string? provider = null, string? providerId = null) =>
        new(id, title, eligible, provider, providerId);

    [Fact]
    public void Group_Empty_ReturnsEmpty()
    {
        Assert.Empty(ElderWandModelGrouping.Group(System.Array.Empty<ElderWandAdvertisedModel>()));
    }

    [Fact]
    public void Group_DedupesById_FirstOccurrenceWins()
    {
        var groups = ElderWandModelGrouping.Group(new[]
        {
            Model("m1", "First", provider: "Anthropic"),
            Model("m1", "Duplicate", provider: "OpenAI"), // dropped — same id
            Model("  ", "blank"),                          // dropped — empty id
        });

        var options = groups.SelectMany(g => g.Options).ToList();
        Assert.Single(options);
        Assert.Equal("First", options[0].Title);
        Assert.Equal("Anthropic", groups.Single().ProviderName);
    }

    [Fact]
    public void Group_PreservesFirstSeenProviderOrder()
    {
        var groups = ElderWandModelGrouping.Group(new[]
        {
            Model("m1", "a", provider: "Zeta"),
            Model("m2", "b", provider: "Alpha"),
            Model("m3", "c", provider: "Zeta"),
        });

        Assert.Equal(new[] { "Zeta", "Alpha" }, groups.Select(g => g.ProviderName));
        Assert.Equal(2, groups[0].Options.Count); // Zeta got m1 + m3
    }

    [Fact]
    public void Group_SortsOptionsWithinGroupByTitle()
    {
        var groups = ElderWandModelGrouping.Group(new[]
        {
            Model("m1", "Zebra", provider: "P"),
            Model("m2", "Apple", provider: "P"),
            Model("m3", "Mango", provider: "P"),
        });

        Assert.Equal(new[] { "Apple", "Mango", "Zebra" }, groups.Single().Options.Select(o => o.Title));
    }

    [Fact]
    public void Group_ResolvesProviderName_NameThenIdThenOther()
    {
        var groups = ElderWandModelGrouping.Group(new[]
        {
            Model("m1", "a", provider: "  Anthropic  "),   // trimmed name
            Model("m2", "b", provider: "   ", providerId: "prov-x"), // falls to id
            Model("m3", "c"),                              // falls to "Other"
        });

        Assert.Equal(new[] { "Anthropic", "prov-x", "Other" }, groups.Select(g => g.ProviderName));
    }

    [Fact]
    public void Group_CarriesRouteEligibility()
    {
        var groups = ElderWandModelGrouping.Group(new[]
        {
            Model("m1", "Live", eligible: true, provider: "P"),
            Model("m2", "Asleep", eligible: false, provider: "P"),
        });

        var byTitle = groups.Single().Options.ToDictionary(o => o.Title, o => o.IsRouteEligible);
        Assert.True(byTitle["Live"]);
        Assert.False(byTitle["Asleep"]);
    }
}

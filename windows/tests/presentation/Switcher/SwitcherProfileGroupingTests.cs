using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.Switcher;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Switcher;

/// <summary>Pins the grouping + summary passes ported from AccountSwitcherSettingsView+Rendering.</summary>
public sealed class SwitcherProfileGroupingTests
{
    [Fact]
    public void ComputeGroups_OrdersCliByCanonicalOrder_ThenChrome_ThenSafari()
    {
        var profiles = new[]
        {
            SwitcherTestData.Browser("saf", SwitcherBrowserProfileType.Safari),
            SwitcherTestData.Cli("codex", SwitcherCLIProfileType.Codex, account: "a@x"),
            SwitcherTestData.Browser("chr", SwitcherBrowserProfileType.Chrome),
            SwitcherTestData.Cli("claude", SwitcherCLIProfileType.Claude, account: "b@x"),
            SwitcherTestData.Cli("gem", SwitcherCLIProfileType.Gemini, account: "c@x"),
        };

        var groups = SwitcherProfileGrouping.ComputeGroups(profiles);

        // Canonical CLI order is Claude, Codex, ... Gemini, then Chrome, then Safari.
        Assert.Equal(
            new[] { "claude", "codex", "gemini", "chrome", "safari" },
            groups.Select(g => g.Key).ToArray());
    }

    [Fact]
    public void ComputeGroups_OnlyProvidersWithMembersAppear()
    {
        var groups = SwitcherProfileGrouping.ComputeGroups(new[]
        {
            SwitcherTestData.Cli("codex", SwitcherCLIProfileType.Codex, account: "a@x"),
        });

        Assert.Single(groups);
        Assert.Equal("codex", groups[0].Key);
        Assert.True(groups[0].IsCli);
        Assert.False(groups[0].IsBrowser);
    }

    [Fact]
    public void ComputeGroups_ConnectedAndEnabledCounts_ReflectMetadata()
    {
        var profiles = new[]
        {
            SwitcherTestData.Cli("c1", SwitcherCLIProfileType.Claude, account: "connected@x"),
            SwitcherTestData.Cli("c2", SwitcherCLIProfileType.Claude, label: "no-account"),
            SwitcherTestData.Cli("c3", SwitcherCLIProfileType.Claude, account: "paused@x", disabled: true),
        };

        var group = SwitcherProfileGrouping.ComputeGroups(profiles).Single();

        Assert.Equal(3, group.Profiles.Count);
        Assert.Equal(2, group.EnabledCount);   // c1 + c2 enabled; c3 paused
        Assert.Equal(1, group.ConnectedCount); // only c1 has account + not disabled
    }

    [Fact]
    public void ComputeGroups_BrowserConnected_ByEmailOrServiceIdentities()
    {
        var profiles = new[]
        {
            SwitcherTestData.Browser("b1", SwitcherBrowserProfileType.Chrome, email: "me@gmail.com"),
            SwitcherTestData.Browser("b2", SwitcherBrowserProfileType.Chrome,
                services: new[] { new BrowserServiceIdentity(BrowserServiceProvider.OpenAI) }),
            SwitcherTestData.Browser("b3", SwitcherBrowserProfileType.Chrome),
        };

        var group = SwitcherProfileGrouping.ComputeGroups(profiles).Single();
        Assert.Equal(2, group.ConnectedCount);
    }

    [Fact]
    public void Summary_FourBranches()
    {
        // No connected accounts (CLI).
        var noneCli = SwitcherProfileGrouping.ComputeGroups(new[]
        {
            SwitcherTestData.Cli("c1", SwitcherCLIProfileType.Claude, label: "x"),
        }).Single();
        Assert.StartsWith("No connected accounts yet", noneCli.Summary());

        // No confirmed session (browser wording differs).
        var noneBrowser = SwitcherProfileGrouping.ComputeGroups(new[]
        {
            SwitcherTestData.Browser("b1", SwitcherBrowserProfileType.Chrome),
        }).Single();
        Assert.StartsWith("No confirmed session detected yet", noneBrowser.Summary());

        // Multiple enabled → handoff-ready.
        var many = SwitcherProfileGrouping.ComputeGroups(new[]
        {
            SwitcherTestData.Cli("c1", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("c2", SwitcherCLIProfileType.Claude, account: "b@x"),
        }).Single();
        Assert.Contains("ready for same-provider handoff", many.Summary());

        // One live account.
        var one = SwitcherProfileGrouping.ComputeGroups(new[]
        {
            SwitcherTestData.Cli("c1", SwitcherCLIProfileType.Claude, account: "a@x"),
        }).Single();
        Assert.Equal("One account is live. Add another to keep a reserve ready.", one.Summary());

        // Connected but some paused (one enabled connected + one paused).
        var paused = SwitcherProfileGrouping.ComputeGroups(new[]
        {
            SwitcherTestData.Cli("c1", SwitcherCLIProfileType.Claude, account: "a@x"),
            SwitcherTestData.Cli("c2", SwitcherCLIProfileType.Claude, account: "b@x", disabled: true),
        }).Single();
        Assert.StartsWith("Some accounts are paused", paused.Summary());
    }

    [Theory]
    [InlineData(1, "primary")]
    [InlineData(2, "reserve 1")]
    [InlineData(3, "reserve 2")]
    public void SlotLabel_PrimaryThenReserves(int oneBased, string expected)
    {
        Assert.Equal(expected, SwitcherProfileGrouping.SlotLabel(oneBased));
    }

    [Fact]
    public void GroupBrandColor_MatchesSwiftCliOrderHex()
    {
        var claude = SwitcherProfileGrouping.ComputeGroups(new[]
        {
            SwitcherTestData.Cli("c1", SwitcherCLIProfileType.Claude, account: "a@x"),
        }).Single();
        Assert.Equal("CC785C", claude.BrandColorHex);

        var codex = SwitcherProfileGrouping.ComputeGroups(new[]
        {
            SwitcherTestData.Cli("c1", SwitcherCLIProfileType.Codex, account: "a@x"),
        }).Single();
        Assert.Equal("00A67E", codex.BrandColorHex);
    }
}

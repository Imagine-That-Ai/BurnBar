using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.Switcher;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Switcher;

/// <summary>
/// Pins the account-change routing ported from BrowserAccountChangePlanner +
/// the destination helpers on AccountSwitcherSettingsView (DataOperations).
/// </summary>
public sealed class SwitcherDestinationPlannerTests
{
    private static BrowserServiceIdentity Service(BrowserServiceProvider p) => new(p);

    [Fact]
    public void BrowserDestinations_Apple_FirstThenUniversalFallbacks()
    {
        var result = SwitcherDestinationPlanner.BrowserDestinations(
            "apple", Array.Empty<BrowserServiceIdentity>());

        Assert.Equal(
            new[] { AccountChangeDestination.AppleID, AccountChangeDestination.OpenAI, AccountChangeDestination.Claude },
            result);
    }

    [Fact]
    public void BrowserDestinations_Google_FirstThenUniversalFallbacks()
    {
        var result = SwitcherDestinationPlanner.BrowserDestinations(
            "GOOGLE", Array.Empty<BrowserServiceIdentity>());

        Assert.Equal(
            new[] { AccountChangeDestination.GoogleAccount, AccountChangeDestination.OpenAI, AccountChangeDestination.Claude },
            result);
    }

    [Fact]
    public void BrowserDestinations_DetectedServices_OrderedBeforeFallbacks_AndDeduped()
    {
        var result = SwitcherDestinationPlanner.BrowserDestinations(
            "google",
            new[] { Service(BrowserServiceProvider.Claude), Service(BrowserServiceProvider.OpenAI) });

        // google first, then services in order (claude, openai), then fallbacks dedupe away.
        Assert.Equal(
            new[]
            {
                AccountChangeDestination.GoogleAccount,
                AccountChangeDestination.Claude,
                AccountChangeDestination.OpenAI,
            },
            result);
    }

    [Fact]
    public void BrowserDestinations_UnknownProvider_YieldsOnlyUniversalFallbacks()
    {
        var result = SwitcherDestinationPlanner.BrowserDestinations(
            null, Array.Empty<BrowserServiceIdentity>());

        Assert.Equal(
            new[] { AccountChangeDestination.OpenAI, AccountChangeDestination.Claude },
            result);
    }

    [Fact]
    public void ServiceDestinations_DedupesAndPreservesOrder()
    {
        var profile = SwitcherTestData.Browser(
            "b1", SwitcherBrowserProfileType.Chrome,
            services: new[]
            {
                Service(BrowserServiceProvider.OpenAI),
                Service(BrowserServiceProvider.OpenAI),
                Service(BrowserServiceProvider.Claude),
            });

        Assert.Equal(
            new[] { AccountChangeDestination.OpenAI, AccountChangeDestination.Claude },
            SwitcherDestinationPlanner.ServiceDestinations(profile));
    }

    [Fact]
    public void PreferredAccountChangeDestination_SingleService_Selected_MultipleOrZero_Null()
    {
        var single = SwitcherTestData.Browser(
            "b1", SwitcherBrowserProfileType.Chrome, services: new[] { Service(BrowserServiceProvider.Claude) });
        Assert.Equal(AccountChangeDestination.Claude, SwitcherDestinationPlanner.PreferredAccountChangeDestination(single));

        var many = SwitcherTestData.Browser(
            "b2", SwitcherBrowserProfileType.Chrome,
            services: new[] { Service(BrowserServiceProvider.Claude), Service(BrowserServiceProvider.OpenAI) });
        Assert.Null(SwitcherDestinationPlanner.PreferredAccountChangeDestination(many));

        var none = SwitcherTestData.Browser("b3", SwitcherBrowserProfileType.Chrome);
        Assert.Null(SwitcherDestinationPlanner.PreferredAccountChangeDestination(none));
    }

    [Theory]
    [InlineData(SwitcherCLIProfileType.Codex, AccountChangeDestination.OpenAI)]
    [InlineData(SwitcherCLIProfileType.Claude, AccountChangeDestination.Claude)]
    public void DefaultAccountChangeDestination_CodexAndClaude(
        SwitcherCLIProfileType type, AccountChangeDestination expected)
    {
        var profile = SwitcherTestData.Cli("c1", type);
        Assert.Equal(expected, SwitcherDestinationPlanner.DefaultAccountChangeDestination(profile));
    }

    [Theory]
    [InlineData(SwitcherCLIProfileType.OpenCode)]
    [InlineData(SwitcherCLIProfileType.Droid)]
    [InlineData(SwitcherCLIProfileType.Gemini)]
    public void DefaultAccountChangeDestination_OtherClis_Null(SwitcherCLIProfileType type)
    {
        Assert.Null(SwitcherDestinationPlanner.DefaultAccountChangeDestination(SwitcherTestData.Cli("c1", type)));
    }

    [Fact]
    public void AvailableDestinations_Browser_UsesPlanner_Cli_UsesServiceDestinations()
    {
        var chrome = SwitcherTestData.Browser("b1", SwitcherBrowserProfileType.Chrome, providerIdentifier: "google");
        var browserResult = SwitcherDestinationPlanner.AvailableAccountChangeDestinations(chrome);
        Assert.Equal(AccountChangeDestination.GoogleAccount, browserResult[0]);

        var cli = SwitcherTestData.Cli("c1", SwitcherCLIProfileType.Codex);
        // CLI profiles have no browser service identities → empty here (reconnect uses the default).
        Assert.Empty(SwitcherDestinationPlanner.AvailableAccountChangeDestinations(cli));
    }

    [Theory]
    [InlineData(SwitcherBrowserProfileType.Safari, null, "apple")]
    [InlineData(SwitcherBrowserProfileType.Chrome, null, "google")]
    [InlineData(SwitcherBrowserProfileType.Chrome, " Apple ", "apple")]
    public void BrowserProviderIdentifier_UsesExplicitElseBrowserDefault(
        SwitcherBrowserProfileType type, string? explicitId, string expected)
    {
        var profile = SwitcherTestData.Browser("b1", type, providerIdentifier: explicitId);
        Assert.Equal(expected, SwitcherDestinationPlanner.BrowserProviderIdentifier(profile));
    }

    [Fact]
    public void DestinationMetadata_MatchesSwiftLabelsSubtitlesAccentsAndAuthFlags()
    {
        Assert.Equal("OpenAI / Codex", AccountChangeDestination.OpenAI.Label());
        Assert.Equal("claude.ai", AccountChangeDestination.Claude.Subtitle());
        Assert.Equal("4285F4", AccountChangeDestination.GoogleAccount.AccentColorHex());
        Assert.True(AccountChangeDestination.AppleID.RequiresInteractiveAuth());
        Assert.False(AccountChangeDestination.OpenAI.RequiresInteractiveAuth());
        Assert.Equal("https://claude.ai/", AccountChangeDestination.Claude.Url());
        Assert.Equal(BrowserServiceProvider.OpenAI, AccountChangeDestination.OpenAI.BrowserServiceProvider());
        Assert.Null(AccountChangeDestination.GoogleAccount.BrowserServiceProvider());
    }
}

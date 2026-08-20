using System;
using System.Linq;
using OpenBurnBar.App.Presentation.Switcher;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Switcher;

/// <summary>Pins the ported record helpers + enum metadata + row-identity text.</summary>
public sealed class SwitcherModelsTests
{
    [Theory]
    [InlineData("  Work   Account ", "work account")]
    [InlineData("Personal", "personal")]
    [InlineData("A\tB", "a b")]
    public void NormalizeName_LowercaseTrimCollapse(string input, string expected)
    {
        Assert.Equal(expected, SwitcherProfileRecord.NormalizeName(input));
    }

    [Theory]
    [InlineData(SwitcherCLIProfileType.Codex, "codex")]
    [InlineData(SwitcherCLIProfileType.Claude, "claude-code")]
    [InlineData(SwitcherCLIProfileType.Droid, "factory")]
    [InlineData(SwitcherCLIProfileType.Grok, "xai")]
    [InlineData(SwitcherCLIProfileType.CursorAgent, "cursor-agent")]
    [InlineData(SwitcherCLIProfileType.Gemini, "geminicli")]
    [InlineData(SwitcherCLIProfileType.Pi, "piagent")]
    [InlineData(SwitcherCLIProfileType.Omp, "omp")]
    public void ProviderKey_MatchesCanonicalProviderId(SwitcherCLIProfileType type, string expected)
    {
        Assert.Equal(expected, type.ProviderKey());
    }

    [Theory]
    [InlineData(SwitcherCLIProfileType.CursorAgent, "cursoragent")]
    [InlineData(SwitcherCLIProfileType.Claude, "claude")]
    public void CliRawValue_MatchesSwiftRawValue(SwitcherCLIProfileType type, string expected)
    {
        Assert.Equal(expected, type.RawValue());
    }

    [Fact]
    public void DisplayName_PrefersLabelThenIdentifierThenType()
    {
        var browserLabelled = SwitcherTestData.Browser("b1", SwitcherBrowserProfileType.Chrome, label: "Home");
        Assert.Equal("Home", browserLabelled.DisplayName);

        var browserBare = SwitcherTestData.Browser("b2", SwitcherBrowserProfileType.Chrome, profileIdentifier: "Profile 3");
        Assert.Equal("Profile 3", browserBare.DisplayName);

        var cliByType = new SwitcherProfileRecord(
            "c1", SwitcherProfileTargetKind.Cli, 0,
            CliType: SwitcherCLIProfileType.Codex,
            CliMetadata: new SwitcherCLIProfileMetadata());
        Assert.Equal("Codex", cliByType.DisplayName);
    }

    [Fact]
    public void ConcreteTargetType_ReflectsBrowserOrCliRaw()
    {
        Assert.Equal("chrome", SwitcherTestData.Browser("b", SwitcherBrowserProfileType.Chrome).ConcreteTargetType);
        Assert.Equal("codex", SwitcherTestData.Cli("c", SwitcherCLIProfileType.Codex).ConcreteTargetType);
    }

    [Fact]
    public void RowIdentityText_Cli_Branches()
    {
        var connected = Row(SwitcherTestData.Cli("c", SwitcherCLIProfileType.Claude, account: " Alice • a@x "));
        Assert.Equal("Connected: Alice • a@x", connected.AccountIdentityText);
        Assert.True(connected.IsConnected);

        var paused = Row(SwitcherTestData.Cli("c", SwitcherCLIProfileType.Claude, account: "a@x", disabled: true));
        Assert.Equal("Paused — excluded from switching until re-enabled", paused.AccountIdentityText);
        Assert.False(paused.IsConnected);

        var reserve = Row(SwitcherTestData.Cli(
            "c", SwitcherCLIProfileType.Claude, exhaustedUntil: SwitcherTestData.Now.AddHours(2)));
        Assert.Equal("Held in reserve until quota resets", reserve.AccountIdentityText);

        var labelled = Row(SwitcherTestData.Cli("c", SwitcherCLIProfileType.Claude, label: "Work"));
        Assert.Equal("Not connected · Work", labelled.AccountIdentityText);

        var bare = Row(SwitcherTestData.Cli("c", SwitcherCLIProfileType.Claude));
        Assert.Equal("Not connected", bare.AccountIdentityText);
    }

    [Fact]
    public void RowIdentityText_Browser_Branches()
    {
        var email = Row(SwitcherTestData.Browser("b", SwitcherBrowserProfileType.Chrome, email: "me@gmail.com"));
        Assert.Equal("Google: me@gmail.com", email.AccountIdentityText);

        var safariLabel = Row(SwitcherTestData.Browser("b", SwitcherBrowserProfileType.Safari, label: "Personal"));
        Assert.Equal("Apple ID: Personal", safariLabel.AccountIdentityText);

        var services = Row(SwitcherTestData.Browser(
            "b", SwitcherBrowserProfileType.Chrome,
            services: new[] { new BrowserServiceIdentity(BrowserServiceProvider.OpenAI) }));
        Assert.Equal("Web sessions detected", services.AccountIdentityText);

        var none = Row(SwitcherTestData.Browser("b", SwitcherBrowserProfileType.Chrome));
        Assert.Equal("Not signed in", none.AccountIdentityText);
    }

    private static SwitcherProfileRowViewModel Row(SwitcherProfileRecord profile)
    {
        var group = SwitcherProfileGrouping.ComputeGroups(new[] { profile }).Single();
        return SwitcherProfileRowViewModel.ForGroup(group, activeProfileId: null, now: SwitcherTestData.Now).Single();
    }
}

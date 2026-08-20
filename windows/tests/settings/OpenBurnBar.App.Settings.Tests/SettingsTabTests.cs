using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Real coverage for the ported sidebar IA + provider identity
/// (AgentLens/Views/Settings/SettingsTab.swift + AgentProvider identity subset).
/// </summary>
public sealed class SettingsTabTests
{
    [Fact]
    public void VisibleTabs_StartWithHomeThenEverySectionInOrder()
    {
        var visible = SettingsTabMetadata.VisibleTabs;

        Assert.Equal(SettingsTab.Home, visible[0]);
        Assert.Equal(16, visible.Count);                 // all 16 tabs surface on the direct-download build
        Assert.Equal(16, visible.Distinct().Count());    // no dupes

        var expected = new List<SettingsTab> { SettingsTab.Home };
        foreach (var section in SettingsSectionMetadata.VisibleSections)
        {
            expected.AddRange(SettingsSectionMetadata.Tabs(section));
        }
        Assert.Equal(expected, visible);
    }

    [Fact]
    public void VisibleSections_ExcludeTheHomeSection()
    {
        Assert.DoesNotContain(SettingsSection.Home, SettingsSectionMetadata.VisibleSections);
        Assert.Equal(5, SettingsSectionMetadata.VisibleSections.Count);
    }

    [Fact]
    public void EveryTab_BelongsToTheSectionThatListsIt()
    {
        foreach (var tab in Enum.GetValues<SettingsTab>())
        {
            var section = SettingsTabMetadata.Section(tab);
            Assert.Contains(tab, SettingsSectionMetadata.Tabs(section));
        }
    }

    [Fact]
    public void AgentsAndModels_SectionOrdersAgentsThenModelProxy()
    {
        Assert.Equal(
            new[] { SettingsTab.Agents, SettingsTab.ModelProxy },
            SettingsSectionMetadata.Tabs(SettingsSection.AgentsAndModels));
    }

    [Fact]
    public void TabTitles_MatchTheSwiftLabels()
    {
        Assert.Equal("Engine Room", SettingsTabMetadata.Title(SettingsTab.Daemon));
        Assert.Equal("Devices & Sync", SettingsTabMetadata.Title(SettingsTab.DevicesAndSync));
        Assert.Equal("Model Proxy", SettingsTabMetadata.Title(SettingsTab.ModelProxy));
    }

    [Fact]
    public void TabLogoProviders_MatchTheSwiftTable()
    {
        Assert.Equal(
            new[] { AgentProvider.ClaudeCode, AgentProvider.Codex, AgentProvider.OpenCode, AgentProvider.Hermes },
            SettingsTabMetadata.LogoProviders(SettingsTab.Agents));
        Assert.Empty(SettingsTabMetadata.LogoProviders(SettingsTab.General));
    }

    [Theory]
    [InlineData("connections", SettingsTab.Agents)]
    [InlineData("routingPools", SettingsTab.Agents)]
    [InlineData("switcher", SettingsTab.Agents)]
    [InlineData("hermes", SettingsTab.Agents)]
    [InlineData("proxy", SettingsTab.ModelProxy)]
    [InlineData("gateway", SettingsTab.ModelProxy)]
    [InlineData("general", SettingsTab.General)] // exact current raw value
    public void ResolvingLegacyRawValue_MapsAliasesAndExactValues(string raw, SettingsTab expected)
    {
        Assert.Equal(expected, SettingsTabMetadata.ResolvingLegacyRawValue(raw));
    }

    [Fact]
    public void ResolvingLegacyRawValue_UnknownReturnsNull()
    {
        Assert.Null(SettingsTabMetadata.ResolvingLegacyRawValue("no-such-tab"));
    }

    // ── AgentProvider identity subset ─────────────────────────────────────────

    [Fact]
    public void AgentProviderAllCases_PreserveSwiftDeclarationOrder()
    {
        var cases = AgentProviderMetadata.AllCases;
        Assert.Equal(AgentProvider.Factory, cases[0]);
        Assert.Equal(AgentProvider.OpenBurnBar, cases[6]);   // 7th case in the Swift enum
        Assert.Equal(AgentProvider.Fx, cases[^1]);  // last case
    }

    [Theory]
    [InlineData(AgentProvider.ClaudeCode, "Claude Code", "claudecode", "claude-code")]
    [InlineData(AgentProvider.OpenCode, "OpenCode", "opencode", "opencode")]
    [InlineData(AgentProvider.CursorAgent, "Cursor Agent", "cursoragent", "cursor-agent")]
    [InlineData(AgentProvider.XAI, "xAI", "xai", "xai")]
    [InlineData(AgentProvider.OpenAI, "OpenAI", "openai", "openai")]
    [InlineData(AgentProvider.Kimi, "Kimi", "kimi", "kimi")]
    public void ProviderMetadata_MatchesSwift(AgentProvider provider, string display, string token, string providerId)
    {
        Assert.Equal(display, AgentProviderMetadata.DisplayName(provider));
        Assert.Equal(token, AgentProviderMetadata.PersistedToken(provider));
        Assert.Equal(providerId, AgentProviderMetadata.ProviderIdRawValue(provider));
    }
}

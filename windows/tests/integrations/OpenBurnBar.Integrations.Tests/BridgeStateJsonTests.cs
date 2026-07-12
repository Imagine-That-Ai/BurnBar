using System;
using System.Text.Json;
using OpenBurnBar.Integrations.SmartHub.Bridge;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class BridgeStateJsonTests
{
    private static SmartHubBridgeSnapshot TwoProviderSnapshot() => new(
        totalSpend: "$120.50",
        totalTokens: "5.4B",
        headline: "OpenBurnBar",
        subheadline: "Live",
        providers: new[]
        {
            new SmartHubProvider(
                name: "Claude Code",
                percent: 33,
                label: "$40 / $120",
                tone: SmartHubTone.Ember,
                windowLabel: "5h",
                accentHex: "E07868",
                buckets: new[]
                {
                    new SmartHubBucket("5-hour window", 33, "33%", "67% left", "in 2h", SmartHubTone.Ember, false),
                },
                accounts: new[]
                {
                    new SmartHubAccount("Work", "MAIN", SmartHubTone.Success, true),
                }),
            new SmartHubProvider(
                name: "Codex",
                percent: 80,
                label: "80%",
                tone: SmartHubTone.Warning,
                hasQuotaData: false,
                burnRates: new[]
                {
                    new SmartHubBurnRate("5h", "1.2M", "$0.50", "12 runs"),
                }),
        },
        headerTimestamp: "Thu, Jul 3  10:43 PM",
        headerStatus: "live provider pressure");

    private static JsonDocument Render(SmartHubTimePeriod period, SmartHubDisplayConfig display, ulong version = 7) =>
        JsonDocument.Parse(BridgeStateJson.Render(
            version,
            new DateTimeOffset(2026, 7, 3, 22, 43, 0, TimeSpan.Zero),
            isRefreshing: false,
            period,
            TwoProviderSnapshot(),
            display));

    [Fact]
    public void Render_EmitsTopLevelContract()
    {
        using var doc = Render(SmartHubTimePeriod.Rolling5h, SmartHubDisplayConfig.Default);
        var root = doc.RootElement;
        Assert.Equal(7UL, root.GetProperty("version").GetUInt64());
        Assert.Equal("2026-07-03T22:43:00Z", root.GetProperty("lastRefreshedAt").GetString());
        Assert.False(root.GetProperty("isRefreshing").GetBoolean());
        Assert.Equal("rolling5h", root.GetProperty("timePeriod").GetString());
        Assert.Equal("Last 5 hours", root.GetProperty("timePeriodLabel").GetString());
        Assert.Equal(4, root.GetProperty("timePeriodOptions").GetArrayLength());
        Assert.Equal("$120.50", root.GetProperty("totalSpend").GetString());
        Assert.Equal("Thu, Jul 3  10:43 PM", root.GetProperty("headerTimestamp").GetString());
        Assert.Equal(2, root.GetProperty("providers").GetArrayLength());
    }

    [Fact]
    public void Render_ProviderCardFields()
    {
        using var doc = Render(SmartHubTimePeriod.Rolling5h, SmartHubDisplayConfig.Default);
        var claude = doc.RootElement.GetProperty("providers")[0];
        Assert.Equal("Claude Code", claude.GetProperty("name").GetString());
        Assert.Equal("claudecode", claude.GetProperty("slug").GetString());
        Assert.Equal(33, claude.GetProperty("percent").GetInt32());
        Assert.Equal("ember", claude.GetProperty("tone").GetString());
        Assert.True(claude.GetProperty("hasQuotaData").GetBoolean());
        Assert.Equal(1, claude.GetProperty("buckets").GetArrayLength());
        Assert.Equal("5-hour window", claude.GetProperty("buckets")[0].GetProperty("name").GetString());
        Assert.Equal(1, claude.GetProperty("accounts").GetArrayLength());
        Assert.Equal("MAIN", claude.GetProperty("accounts")[0].GetProperty("badge").GetString());

        var codex = doc.RootElement.GetProperty("providers")[1];
        Assert.False(codex.GetProperty("hasQuotaData").GetBoolean());
        Assert.Equal(1, codex.GetProperty("burnRates").GetArrayLength());
        Assert.Equal("$0.50", codex.GetProperty("burnRates")[0].GetProperty("cost").GetString());
    }

    [Fact]
    public void Render_DisplayBlock()
    {
        using var doc = Render(SmartHubTimePeriod.Rolling5h, SmartHubDisplayConfig.Default);
        var display = doc.RootElement.GetProperty("display");
        Assert.Equal("quotaCarousel", display.GetProperty("layout").GetString());
        Assert.Equal("emberWhimsy", display.GetProperty("palette").GetString());
        Assert.Equal(0.85, display.GetProperty("brightness").GetDouble(), 3);
        Assert.Equal("#E07868", display.GetProperty("paletteHex").GetProperty("primary").GetString());
        Assert.Equal("#2A221A", display.GetProperty("themeHex").GetProperty("top").GetString());
        Assert.False(display.GetProperty("paletteHex").GetProperty("rainbow").GetBoolean());
    }

    [Fact]
    public void Render_ProviderFilter_ByPersistedTokenSlug()
    {
        var display = new SmartHubDisplayConfig(providerIds: new[] { "claudecode" });
        using var doc = Render(SmartHubTimePeriod.Rolling5h, display);
        var providers = doc.RootElement.GetProperty("providers");
        Assert.Equal(1, providers.GetArrayLength());
        Assert.Equal("Claude Code", providers[0].GetProperty("name").GetString());
    }

    [Fact]
    public void Render_ProviderFilter_ByDisplayName()
    {
        var display = new SmartHubDisplayConfig(providerIds: new[] { "codex" });
        using var doc = Render(SmartHubTimePeriod.Rolling5h, display);
        var providers = doc.RootElement.GetProperty("providers");
        Assert.Equal(1, providers.GetArrayLength());
        Assert.Equal("Codex", providers[0].GetProperty("name").GetString());
    }

    [Fact]
    public void Escape_HandlesQuotesAndBackslashes()
    {
        Assert.Equal("a\\\"b", BridgeStateJson.Escape("a\"b"));
        Assert.Equal("a\\\\b", BridgeStateJson.Escape("a\\b"));
    }

    [Fact]
    public void Escape_ProducesParseableJsonForQuotedNames()
    {
        var snapshot = new SmartHubBridgeSnapshot(
            totalSpend: "\"weird\"",
            headline: "h",
            subheadline: "s",
            providers: new[] { new SmartHubProvider("A\"B", 1, "l", SmartHubTone.Mercury) });
        var json = BridgeStateJson.Render(1, DateTimeOffset.UtcNow, false, SmartHubTimePeriod.Rolling5h, snapshot, SmartHubDisplayConfig.Default);
        using var doc = JsonDocument.Parse(json); // must not throw
        Assert.Equal("\"weird\"", doc.RootElement.GetProperty("totalSpend").GetString());
        Assert.Equal("A\"B", doc.RootElement.GetProperty("providers")[0].GetProperty("name").GetString());
    }

    [Fact]
    public void Iso8601_FormatsUtcWithZ()
    {
        var value = new DateTimeOffset(2026, 7, 3, 22, 43, 5, TimeSpan.FromHours(-4));
        Assert.Equal("2026-07-04T02:43:05Z", BridgeStateJson.Iso8601(value));
    }

    [Fact]
    public void PersistedTokenForName_StripsNonAlphanumerics()
    {
        Assert.Equal("claudecode", BridgeStateJson.PersistedTokenForName("Claude Code"));
        Assert.Equal("openai", BridgeStateJson.PersistedTokenForName("Open-AI!"));
    }
}

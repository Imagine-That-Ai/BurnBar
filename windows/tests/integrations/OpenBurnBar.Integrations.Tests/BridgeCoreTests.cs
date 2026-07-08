using System;
using System.Linq;
using System.Text;
using OpenBurnBar.Integrations.SmartHub.Bridge;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class BridgeAccessControlTests
{
    [Fact]
    public void ConstantTimeEquals_Basics()
    {
        Assert.True(BridgeAccessControl.ConstantTimeEquals("abc", "abc"));
        Assert.False(BridgeAccessControl.ConstantTimeEquals("abc", "abd"));
        Assert.False(BridgeAccessControl.ConstantTimeEquals("abc", "abcd"));
        Assert.False(BridgeAccessControl.ConstantTimeEquals(null, "abc"));
    }

    [Fact]
    public void MakeBridgeAccessToken_Is64HexChars()
    {
        var token = BridgeAccessControl.MakeBridgeAccessToken();
        Assert.Equal(64, token.Length);
        Assert.Matches("^[0-9a-f]{64}$", token);
        Assert.NotEqual(token, BridgeAccessControl.MakeBridgeAccessToken());
    }

    [Fact]
    public void IsAuthorized_AcceptsQueryToken()
    {
        Assert.True(BridgeAccessControl.IsAuthorized("/state.json?bridgeToken=tok", null, "tok"));
        Assert.False(BridgeAccessControl.IsAuthorized("/state.json?bridgeToken=nope", null, "tok"));
    }

    [Fact]
    public void IsAuthorized_AcceptsBearerHeader()
    {
        Assert.True(BridgeAccessControl.IsAuthorized("/state.json", "Bearer tok", "tok"));
        Assert.False(BridgeAccessControl.IsAuthorized("/state.json", "Bearer wrong", "tok"));
    }

    [Fact]
    public void IsAuthorized_EmptyServerToken_DeniesEverything()
    {
        Assert.False(BridgeAccessControl.IsAuthorized("/state.json?bridgeToken=", null, ""));
    }

    [Fact]
    public void QueryValue_PercentDecodes()
    {
        Assert.Equal("a b", BridgeAccessControl.QueryValue("/x?p=a%20b", "p"));
        Assert.Null(BridgeAccessControl.QueryValue("/x", "p"));
    }

    [Fact]
    public void SecuredPath_AppendsToken()
    {
        Assert.Equal("/render.html?bridgeToken=tok", BridgeAccessControl.SecuredPath("/render.html", "tok"));
    }

    [Fact]
    public void SecuredBridgeUrl_ReplacesExistingToken()
    {
        var url = BridgeAccessControl.SecuredBridgeUrl("http://x:8787/render.html?bridgeToken=old&foo=1", "new");
        Assert.Contains("foo=1", url);
        Assert.Contains("bridgeToken=new", url);
        Assert.DoesNotContain("bridgeToken=old", url);
    }

    [Fact]
    public void RedactedBridgeUrl_RemovesToken()
    {
        var url = BridgeAccessControl.RedactedBridgeUrl("http://x/p?bridgeToken=tok&a=1");
        Assert.DoesNotContain("bridgeToken", url);
        Assert.Contains("a=1", url);
    }
}

public class BridgeHttpParserTests
{
    private static byte[] Ascii(string s) => Encoding.ASCII.GetBytes(s);

    [Fact]
    public void Parse_Get_WithQueryAndHeaders()
    {
        var result = BridgeHttpParser.Parse(Ascii(
            "GET /state.json?bridgeToken=tok HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer y\r\n\r\n"));
        Assert.Equal(BridgeParseError.None, result.Error);
        var req = result.Request!;
        Assert.Equal("GET", req.Method);
        Assert.Equal("/state.json?bridgeToken=tok", req.RawPath);
        Assert.Equal("/state.json", req.PathOnly);
        Assert.Equal("Bearer y", req.Header("authorization"));
        Assert.Null(req.Body);
    }

    [Fact]
    public void Parse_Post_ExtractsBody()
    {
        var result = BridgeHttpParser.Parse(Ascii(
            "POST /period HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"period\":\"rolling7d\"}"));
        var req = result.Request!;
        Assert.Equal("POST", req.Method);
        Assert.Equal("{\"period\":\"rolling7d\"}", Encoding.UTF8.GetString(req.Body!));
    }

    [Fact]
    public void Parse_MalformedRequestLine_IsBadRequest()
    {
        var result = BridgeHttpParser.Parse(Ascii("GARBAGE\r\n\r\n"));
        Assert.Null(result.Request);
        Assert.Equal(BridgeParseError.BadRequest, result.Error);
    }

    [Fact]
    public void Parse_NonUtf8_IsNotUtf8()
    {
        var result = BridgeHttpParser.Parse(new byte[] { 0xFF, 0xFE, 0x00, 0x01 });
        Assert.Null(result.Request);
        Assert.Equal(BridgeParseError.NotUtf8, result.Error);
    }
}

public class BridgeWireFormatTests
{
    private static string Serialize(BridgeResponse response) => Encoding.UTF8.GetString(response.Serialize());

    [Fact]
    public void Json_SerializesExpectedHead()
    {
        var wire = Serialize(BridgeResponse.Json("{}"));
        Assert.StartsWith("HTTP/1.1 200 OK\r\n", wire);
        Assert.Contains("Content-Type: application/json; charset=utf-8\r\n", wire);
        Assert.Contains("Cache-Control: no-store\r\n", wire);
        Assert.Contains("Content-Length: 2\r\n", wire);
        Assert.Contains("Connection: close\r\n\r\n", wire);
        Assert.EndsWith("{}", wire);
    }

    [Fact]
    public void Status_404_HasStatusBody()
    {
        var wire = Serialize(BridgeResponse.Status(404));
        Assert.StartsWith("HTTP/1.1 404 Not Found\r\n", wire);
        Assert.EndsWith("{\"status\":404}", wire);
    }

    [Fact]
    public void Status_204_HasNoBody()
    {
        var response = BridgeResponse.Status(204);
        Assert.Empty(response.Body);
        var wire = Serialize(response);
        Assert.StartsWith("HTTP/1.1 204 No Content\r\n", wire);
        Assert.Contains("Content-Length: 0\r\n", wire);
    }

    [Fact]
    public void Redirect_CarriesLocation()
    {
        var wire = Serialize(BridgeResponse.Redirect("/render.html?bridgeToken=t"));
        Assert.StartsWith("HTTP/1.1 302 Found\r\n", wire);
        Assert.Contains("Location: /render.html?bridgeToken=t\r\n", wire);
    }
}

public class BridgeRuntimeStateTests
{
    [Fact]
    public void VersionBumps_OnlyOnRealChanges()
    {
        var now = new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.Zero);
        var state = new BridgeRuntimeState(() => now, "tok");
        Assert.Equal(0UL, state.RefreshVersion);

        state.UpdateSnapshot(SmartHubBridgeSnapshot.Empty);
        Assert.Equal(1UL, state.RefreshVersion);

        state.UpdateTimePeriod(SmartHubTimePeriod.Rolling7d);
        Assert.Equal(2UL, state.RefreshVersion);
        state.UpdateTimePeriod(SmartHubTimePeriod.Rolling7d); // no-op
        Assert.Equal(2UL, state.RefreshVersion);

        state.SetRefreshing(true);
        Assert.Equal(3UL, state.RefreshVersion);
        state.SetRefreshing(true); // no-op
        Assert.Equal(3UL, state.RefreshVersion);
        state.SetRefreshing(false);
        Assert.Equal(4UL, state.RefreshVersion);

        state.UpdateDisplayConfig(SmartHubDisplayConfig.Default); // equals default -> no-op
        Assert.Equal(4UL, state.RefreshVersion);
        state.UpdateDisplayConfig(new SmartHubDisplayConfig(brightness: 0.5));
        Assert.Equal(5UL, state.RefreshVersion);
    }

    [Fact]
    public void RecordClientPoll_StampsClock()
    {
        var now = new DateTimeOffset(2026, 7, 3, 1, 2, 3, TimeSpan.Zero);
        var state = new BridgeRuntimeState(() => now, "tok");
        Assert.Equal(DateTimeOffset.MinValue, state.LastClientPollAt);
        state.RecordClientPoll();
        Assert.Equal(now, state.LastClientPollAt);
    }

    [Fact]
    public void RegenerateToken_Changes()
    {
        var state = new BridgeRuntimeState(bridgeAccessToken: "tok");
        state.RegenerateToken();
        Assert.NotEqual("tok", state.BridgeAccessToken);
        Assert.Equal(64, state.BridgeAccessToken.Length);
    }
}

public class SmartHubModelsTests
{
    [Fact]
    public void TimePeriod_RawValueParseRoundTrip()
    {
        foreach (var period in SmartHubTimePeriodExtensions.AllCases)
        {
            Assert.Equal(period, SmartHubTimePeriodExtensions.Parse(period.RawValue()));
        }
        Assert.Equal(4, SmartHubTimePeriodExtensions.AllCases.Length);
        Assert.Null(SmartHubTimePeriodExtensions.Parse("bogus"));
        Assert.Equal("7d", SmartHubTimePeriod.Rolling7d.ShortLabel());
        Assert.Equal(24 * 7, SmartHubTimePeriod.Rolling7d.SpanHours());
    }

    [Fact]
    public void DisplayConfig_Clamps()
    {
        Assert.Equal(0.2, new SmartHubDisplayConfig(brightness: 0.1).ClampedBrightness);
        Assert.Equal(1.0, new SmartHubDisplayConfig(brightness: 2.0).ClampedBrightness);
        Assert.Equal(3, new SmartHubDisplayConfig(scrollSpeedSeconds: 1).ClampedScrollSpeed);
        Assert.Equal(30, new SmartHubDisplayConfig(scrollSpeedSeconds: 99).ClampedScrollSpeed);
        Assert.Equal(3, new SmartHubDisplayConfig(refreshCadenceSeconds: 1).ClampedRefreshCadence);
        Assert.Equal(60, new SmartHubDisplayConfig(refreshCadenceSeconds: 999).ClampedRefreshCadence);
    }

    [Fact]
    public void DisplayEnums_RawValuesAndHex()
    {
        Assert.Equal("quotaCarousel", SmartHubDisplayLayout.QuotaCarousel.RawValue());
        Assert.Equal("#E07868", SmartHubDisplayPalette.EmberWhimsy.PrimaryHex());
        Assert.True(SmartHubDisplayPalette.Rainbow.IsRainbow());
        Assert.Equal(("#2A221A", "#0E0D0B"), SmartHubDisplayTheme.WarmCharcoal.BackgroundPair());
        Assert.Equal("photoBlend", SmartHubDisplayBackground.PhotoBlend.RawValue());
    }

    [Fact]
    public void Provider_SlugDerivation()
    {
        Assert.Equal("claudecode", SmartHubProvider.SlugForName("Claude Code"));
        var provider = new SmartHubProvider("Claude Code", 50, "x", SmartHubTone.Ember);
        Assert.Equal("claudecode", provider.Slug);
        Assert.Equal("ember", provider.Tone.RawValue());
    }

    [Fact]
    public void DisplayConfig_ProviderIdEquality()
    {
        var a = new SmartHubDisplayConfig(providerIds: new[] { "claude", "codex" });
        var b = new SmartHubDisplayConfig(providerIds: new[] { "claude", "codex" });
        var c = new SmartHubDisplayConfig(providerIds: new[] { "claude" });
        Assert.Equal(a, b);
        Assert.NotEqual(a, c);
    }
}

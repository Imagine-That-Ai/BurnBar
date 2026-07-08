using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.SmartHub.Bridge;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class BridgeRouterTests
{
    private const string Token = "tok";

    private static BridgeRequest Req(string method, string rawPath, string? auth = null, byte[]? body = null)
    {
        var pathOnly = rawPath.Split('?')[0];
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (auth is not null)
        {
            headers["Authorization"] = auth;
        }
        return new BridgeRequest(method, rawPath, pathOnly, headers, body);
    }

    private static BridgeRuntimeState NewState() =>
        new(() => new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.Zero), Token);

    [Fact]
    public async Task Options_Returns204()
    {
        var router = new BridgeRouter(NewState());
        var response = await router.DispatchAsync(Req("OPTIONS", "/anything"));
        Assert.Equal(204, response.StatusCode);
    }

    [Fact]
    public async Task BrandLogo_ServedWithoutAuth()
    {
        var router = new BridgeRouter(NewState());
        var response = await router.DispatchAsync(Req("GET", "/brand-logo.svg"));
        Assert.Equal(200, response.StatusCode);
        Assert.Equal("image/svg+xml; charset=utf-8", response.ContentType);
    }

    [Fact]
    public async Task Root_Unauthorized_401()
    {
        var router = new BridgeRouter(NewState());
        var response = await router.DispatchAsync(Req("GET", "/"));
        Assert.Equal(401, response.StatusCode);
    }

    [Fact]
    public async Task Root_Authorized_RedirectsToSecuredRenderHtml()
    {
        var router = new BridgeRouter(NewState());
        var response = await router.DispatchAsync(Req("GET", "/?bridgeToken=tok"));
        Assert.Equal(302, response.StatusCode);
        Assert.Contains(response.ExtraHeaders, h => h.Key == "Location" && h.Value == "/render.html?bridgeToken=tok");
    }

    [Fact]
    public async Task RenderHtml_Authorized_ReturnsHtml()
    {
        var router = new BridgeRouter(NewState(), new BridgeAssets("<html>x</html>", "<svg/>"));
        var response = await router.DispatchAsync(Req("GET", "/render.html", auth: "Bearer tok"));
        Assert.Equal(200, response.StatusCode);
        Assert.Equal("text/html; charset=utf-8", response.ContentType);
        Assert.Equal("<html>x</html>", Encoding.UTF8.GetString(response.Body));
    }

    [Fact]
    public async Task StateJson_Authorized_RecordsPollAndReturnsJson()
    {
        var state = NewState();
        var router = new BridgeRouter(state);
        var response = await router.DispatchAsync(Req("GET", "/state.json?bridgeToken=tok"));
        Assert.Equal(200, response.StatusCode);
        Assert.Equal("application/json; charset=utf-8", response.ContentType);
        Assert.NotEqual(DateTimeOffset.MinValue, state.LastClientPollAt);
        using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(response.Body));
        Assert.Equal("rolling5h", doc.RootElement.GetProperty("timePeriod").GetString());
    }

    [Fact]
    public async Task StateJson_Unauthorized_401_AndNoPoll()
    {
        var state = NewState();
        var router = new BridgeRouter(state);
        var response = await router.DispatchAsync(Req("GET", "/state.json"));
        Assert.Equal(401, response.StatusCode);
        Assert.Equal(DateTimeOffset.MinValue, state.LastClientPollAt);
    }

    [Fact]
    public async Task Refresh_InvokesHandler_ReportsVersion()
    {
        var state = NewState();
        var called = false;
        var router = new BridgeRouter(state, refreshHandler: () => { called = true; return Task.FromResult(true); });

        var response = await router.DispatchAsync(Req("POST", "/refresh?bridgeToken=tok"));

        Assert.Equal(200, response.StatusCode);
        Assert.True(called);
        Assert.False(state.IsRefreshing); // flipped back off after
        using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(response.Body));
        Assert.True(doc.RootElement.GetProperty("ok").GetBoolean());
        Assert.False(doc.RootElement.GetProperty("refreshing").GetBoolean());
    }

    [Fact]
    public async Task Refresh_NoHandler_BumpsVersion()
    {
        var state = NewState();
        var router = new BridgeRouter(state);
        var response = await router.DispatchAsync(Req("POST", "/refresh?bridgeToken=tok"));
        using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(response.Body));
        Assert.True(doc.RootElement.GetProperty("ok").GetBoolean());
    }

    [Fact]
    public async Task Period_FromQuery_UpdatesAndInvokesHandler()
    {
        var state = NewState();
        SmartHubTimePeriod? handled = null;
        var router = new BridgeRouter(state, periodHandler: p => { handled = p; return Task.CompletedTask; });

        var response = await router.DispatchAsync(Req("POST", "/period?bridgeToken=tok&p=rolling7d"));

        Assert.Equal(200, response.StatusCode);
        Assert.Equal(SmartHubTimePeriod.Rolling7d, handled);
        Assert.Equal(SmartHubTimePeriod.Rolling7d, state.TimePeriod);
        using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(response.Body));
        Assert.Equal("rolling7d", doc.RootElement.GetProperty("timePeriod").GetString());
    }

    [Fact]
    public async Task Period_FromBody_Updates()
    {
        var state = NewState();
        var router = new BridgeRouter(state);
        var body = Encoding.UTF8.GetBytes("{\"period\":\"rolling24h\"}");
        var response = await router.DispatchAsync(Req("POST", "/period?bridgeToken=tok", auth: null, body: body));
        Assert.Equal(200, response.StatusCode);
        Assert.Equal(SmartHubTimePeriod.Rolling24h, state.TimePeriod);
    }

    [Fact]
    public async Task Period_Invalid_400()
    {
        var state = NewState();
        var router = new BridgeRouter(state);
        var response = await router.DispatchAsync(Req("POST", "/period?bridgeToken=tok&p=bogus"));
        Assert.Equal(400, response.StatusCode);
    }

    [Fact]
    public async Task VoiceRefresh_Acks()
    {
        var router = new BridgeRouter(NewState());
        var response = await router.DispatchAsync(Req("POST", "/voice-refresh?bridgeToken=tok"));
        Assert.Equal(200, response.StatusCode);
        Assert.Contains("queued", Encoding.UTF8.GetString(response.Body));
    }

    [Fact]
    public async Task Unknown_404()
    {
        var router = new BridgeRouter(NewState());
        var response = await router.DispatchAsync(Req("GET", "/nope?bridgeToken=tok"));
        Assert.Equal(404, response.StatusCode);
    }

    [Fact]
    public async Task HandleAsync_ParsesRawBytesEndToEnd()
    {
        var router = new BridgeRouter(NewState());
        var bytes = Encoding.ASCII.GetBytes("GET /state.json?bridgeToken=tok HTTP/1.1\r\nHost: x\r\n\r\n");
        var response = await router.HandleAsync(bytes);
        Assert.Equal(200, response.StatusCode);
    }

    [Fact]
    public async Task HandleAsync_MalformedIs400()
    {
        var router = new BridgeRouter(NewState());
        var response = await router.HandleAsync(Encoding.ASCII.GetBytes("GARBAGE\r\n\r\n"));
        Assert.Equal(400, response.StatusCode);
    }
}

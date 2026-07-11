using System.Linq;
using System.Text;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.HomeAssistant.Rest;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class HomeAssistantClientTests
{
    private const string Base = "http://homeassistant.local:8123";
    private const string Token = "llat-secret";

    [Fact]
    public void Endpoint_PreservesTrailingSlash()
    {
        Assert.Equal("http://h:8123/api/", HomeAssistantClient.Endpoint("http://h:8123/", "api/"));
        Assert.Equal("http://h:8123/api/states", HomeAssistantClient.Endpoint("http://h:8123", "/api/states"));
    }

    [Fact]
    public async Task Probe_401_ReturnsOkWithVersion()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(401, "", new HaHeader("X-HA-Version", "2024.7.1"));
        var client = new HomeAssistantClient(transport);

        var status = await client.ProbeAsync(Base);

        var ok = Assert.IsType<HomeAssistantProbeStatus.Ok>(status);
        Assert.Equal("2024.7.1", ok.Version);
        Assert.Equal("http://homeassistant.local:8123/api/", transport.LastRequest.Url);
        Assert.Equal("GET", transport.LastRequest.Method);
    }

    [Fact]
    public async Task Probe_TransportTimeout_ReturnsUnreachable()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueThrow(HomeAssistantClientException.Timeout());
        var client = new HomeAssistantClient(transport);

        var status = await client.ProbeAsync(Base);

        var unreachable = Assert.IsType<HomeAssistantProbeStatus.Unreachable>(status);
        Assert.Equal("Timed out", unreachable.Message);
    }

    [Fact]
    public async Task ValidateToken_Success_SendsBearer()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(200, Fixtures.Load("ha_api_running.json"));
        var client = new HomeAssistantClient(transport);

        await client.ValidateTokenAsync(Base, Token);

        var auth = transport.LastRequest.Headers.Single(h => h.Name == "Authorization");
        Assert.Equal("Bearer llat-secret", auth.Value);
    }

    [Fact]
    public async Task ValidateToken_Unauthorized_Throws()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(401, "");
        var client = new HomeAssistantClient(transport);

        var ex = await Assert.ThrowsAsync<HomeAssistantClientException>(() => client.ValidateTokenAsync(Base, Token));
        Assert.Equal(HomeAssistantClientErrorKind.Unauthorized, ex.Kind);
    }

    [Fact]
    public async Task ValidateToken_NonJsonBody_ThrowsDecoding()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(200, "this is not JSON and not the health message");
        var client = new HomeAssistantClient(transport);

        var ex = await Assert.ThrowsAsync<HomeAssistantClientException>(() => client.ValidateTokenAsync(Base, Token));
        Assert.Equal(HomeAssistantClientErrorKind.Decoding, ex.Kind);
    }

    [Fact]
    public async Task ValidateToken_JsonBodyWithoutHealthMessage_IsTolerated()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(200, "{\"ok\":true}");
        var client = new HomeAssistantClient(transport);

        // Valid JSON without "API running" is tolerated (proxy stripped message).
        await client.ValidateTokenAsync(Base, Token);
    }

    [Fact]
    public async Task ListMediaPlayers_RoundTripsFixture()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(200, Fixtures.Load("ha_states.json"));
        var client = new HomeAssistantClient(transport);

        var players = await client.ListMediaPlayersAsync(Base, Token);

        Assert.Equal(5, players.Count);
        Assert.Equal("http://homeassistant.local:8123/api/states", transport.LastRequest.Url);
        Assert.Equal("Aux Amp", players[0].FriendlyName);
    }

    [Fact]
    public async Task UpsertAutomation_PostsJsonBodyWithBearer()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(200, "{}");
        var client = new HomeAssistantClient(transport);

        await client.UpsertAutomationAsync(Base, Token, "openburnbar_recovery", "{\"alias\":\"x\"}");

        var req = transport.LastRequest;
        Assert.Equal("POST", req.Method);
        Assert.Equal("http://homeassistant.local:8123/api/config/automation/config/openburnbar_recovery", req.Url);
        Assert.Equal("{\"alias\":\"x\"}", Encoding.UTF8.GetString(req.Body!));
        Assert.Contains(req.Headers, h => h.Name == "Content-Type" && h.Value == "application/json");
    }

    [Fact]
    public async Task CallService_PostsToDomainService()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(200, "");
        var client = new HomeAssistantClient(transport);

        await client.CallServiceAsync(Base, Token, "media_player", "media_stop", "{\"entity_id\":\"media_player.x\"}");

        Assert.Equal("http://homeassistant.local:8123/api/services/media_player/media_stop", transport.LastRequest.Url);
    }

    [Fact]
    public async Task CallService_404_MapsPath()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(404, "");
        var client = new HomeAssistantClient(transport);

        var ex = await Assert.ThrowsAsync<HomeAssistantClientException>(
            () => client.CallServiceAsync(Base, Token, "media_player", "play_media", "{}"));
        Assert.Equal("/api/services/media_player/play_media", ex.Detail);
    }

    [Fact]
    public async Task TriggerWebhook_PostsPayload()
    {
        var transport = new FakeHomeAssistantTransport();
        transport.EnqueueResponse(200, "");
        var client = new HomeAssistantClient(transport);
        var payload = Encoding.UTF8.GetBytes("{\"dashboardURL\":\"http://x\"}");

        await client.TriggerWebhookAsync("http://homeassistant.local:8123/api/webhook/openburnbar_cast_recover_abc", payload);

        var req = transport.LastRequest;
        Assert.Equal("POST", req.Method);
        Assert.Equal(payload, req.Body);
    }
}

using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.HomeAssistant.Rest;
using OpenBurnBar.Integrations.HomeAssistant.Net;
using OpenBurnBar.Integrations.SmartHub.Bridge;
using OpenBurnBar.Integrations.SmartHub.Discovery;
using OpenBurnBar.Integrations.SmartHub.Net;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class NetAdapterTests
{
    private static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    // ── Live bridge HTTP host (real HTTP round-trips through the router) ──────

    [Fact]
    public async Task HttpListenerBridgeHost_ServesStateJson_WithToken()
    {
        var state = new BridgeRuntimeState(bridgeAccessToken: "tok");
        var router = new BridgeRouter(state, new BridgeAssets("<html>ok</html>", "<svg/>"));
        var host = new HttpListenerBridgeHost(router);
        var port = FreePort();
        await host.StartAsync(port);
        try
        {
            Assert.True(host.IsRunning);
            using var client = new HttpClient();

            var authed = await client.GetAsync($"http://127.0.0.1:{port}/state.json?bridgeToken=tok");
            Assert.Equal(HttpStatusCode.OK, authed.StatusCode);
            Assert.Equal("application/json", authed.Content.Headers.ContentType!.MediaType);
            var body = await authed.Content.ReadAsStringAsync();
            Assert.Contains("\"timePeriod\":\"rolling5h\"", body);

            var svg = await client.GetAsync($"http://127.0.0.1:{port}/brand-logo.svg");
            Assert.Equal(HttpStatusCode.OK, svg.StatusCode);

            var unauth = await client.GetAsync($"http://127.0.0.1:{port}/state.json");
            Assert.Equal(HttpStatusCode.Unauthorized, unauth.StatusCode);
        }
        finally
        {
            await host.StopAsync();
        }
        Assert.False(host.IsRunning);
    }

    [Fact]
    public async Task HttpListenerBridgeHost_PostPeriod_UpdatesState()
    {
        var state = new BridgeRuntimeState(bridgeAccessToken: "tok");
        var router = new BridgeRouter(state);
        var host = new HttpListenerBridgeHost(router);
        var port = FreePort();
        await host.StartAsync(port);
        try
        {
            using var client = new HttpClient();
            var content = new StringContent("{\"period\":\"rolling7d\"}", Encoding.UTF8, "application/json");
            var response = await client.PostAsync($"http://127.0.0.1:{port}/period?bridgeToken=tok", content);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.Equal(SmartHubTimePeriod.Rolling7d, state.TimePeriod);
        }
        finally
        {
            await host.StopAsync();
        }
    }

    // ── Live HA transport (real HttpClient against an in-process HA stub) ─────

    [Fact]
    public async Task HttpClientHomeAssistantTransport_Probe_And_ListMediaPlayers()
    {
        var port = FreePort();
        using var stub = new StubHttpServer(port, (path, _) =>
        {
            if (path == "/api/")
            {
                return (401, "", new[] { ("X-HA-Version", "2024.7.1") });
            }
            if (path == "/api/states")
            {
                return (200, Fixtures.Load("ha_states.json"), Array.Empty<(string, string)>());
            }
            return (404, "", Array.Empty<(string, string)>());
        });
        stub.Start();

        using var transport = new HttpClientHomeAssistantTransport();
        var client = new HomeAssistantClient(transport);
        var baseUrl = $"http://127.0.0.1:{port}";

        var probe = await client.ProbeAsync(baseUrl);
        var ok = Assert.IsType<HomeAssistantProbeStatus.Ok>(probe);
        Assert.Equal("2024.7.1", ok.Version);

        var players = await client.ListMediaPlayersAsync(baseUrl, "token");
        Assert.Equal(5, players.Count);
        Assert.Equal("Aux Amp", players[0].FriendlyName);
    }

    [Fact]
    public async Task HttpClientHomeAssistantTransport_MapsServerErrorToTypedException()
    {
        var port = FreePort();
        using var stub = new StubHttpServer(port, (_, _) => (503, "overloaded", Array.Empty<(string, string)>()));
        stub.Start();

        using var transport = new HttpClientHomeAssistantTransport();
        var client = new HomeAssistantClient(transport);
        var ex = await Assert.ThrowsAsync<HomeAssistantClientException>(
            () => client.ListMediaPlayersAsync($"http://127.0.0.1:{port}", "token"));
        Assert.Equal(HomeAssistantClientErrorKind.Server, ex.Kind);
        Assert.Equal(503, ex.StatusCode);
    }

    // ── Live LAN enumerator smoke ────────────────────────────────────────────

    [Fact]
    public void NetworkInterfaceLanEnumerator_DoesNotThrow()
    {
        var enumerator = new NetworkInterfaceLanEnumerator();
        var interfaces = enumerator.Enumerate();          // may be empty on a sandbox
        Assert.NotNull(interfaces);
        foreach (var iface in interfaces)
        {
            Assert.True(Ipv4Subnet.IsUsableLanIpv4(iface.Address));
        }
        Assert.False(string.IsNullOrEmpty(enumerator.LocalHostName()));
        // Feeds the pure candidate math without throwing.
        Assert.NotNull(Ipv4Subnet.DashboardUrlCandidates(enumerator.PreferredLanAddress(), enumerator.LocalHostName()));
    }

    /// A tiny in-process HTTP server so the HA transport can be exercised over a
    /// real socket. Cross-platform (HttpListener runs on the macOS test host).
    private sealed class StubHttpServer : IDisposable
    {
        private readonly HttpListener _listener = new();
        private readonly Func<string, string, (int Status, string Body, (string Name, string Value)[] Headers)> _handler;
        private readonly CancellationTokenSource _cts = new();

        public StubHttpServer(int port, Func<string, string, (int, string, (string, string)[])> handler)
        {
            _handler = handler;
            _listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        }

        public void Start()
        {
            _listener.Start();
            _ = Task.Run(LoopAsync);
        }

        private async Task LoopAsync()
        {
            while (!_cts.IsCancellationRequested && _listener.IsListening)
            {
                HttpListenerContext context;
                try
                {
                    context = await _listener.GetContextAsync();
                }
                catch (Exception)
                {
                    break;
                }
                var (status, body, headers) = _handler(context.Request.Url!.AbsolutePath, context.Request.HttpMethod);
                context.Response.StatusCode = status;
                foreach (var (name, value) in headers)
                {
                    context.Response.Headers[name] = value;
                }
                var bytes = Encoding.UTF8.GetBytes(body);
                context.Response.ContentLength64 = bytes.Length;
                await context.Response.OutputStream.WriteAsync(bytes);
                context.Response.OutputStream.Close();
            }
        }

        public void Dispose()
        {
            _cts.Cancel();
            try { _listener.Stop(); _listener.Close(); } catch (ObjectDisposedException) { }
        }
    }
}

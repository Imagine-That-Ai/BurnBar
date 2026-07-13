using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class LocalHttpGatewayHostTests
{
    [Fact]
    public async Task HealthEndpoint_ReturnsOkJson()
    {
        // Ephemeral port 0 is not supported by HttpListener prefix easily; pick high port.
        int port = 18765 + System.Environment.ProcessId % 1000;
        await using var host = new LocalHttpGatewayHost(port);
        host.Start();

        using var client = new HttpClient { BaseAddress = host.BaseAddress };
        string body = await client.GetStringAsync("/health");
        Assert.Contains("openburnbar-local-gateway", body, System.StringComparison.Ordinal);
        Assert.Contains("\"ok\":true", body.Replace(" ", ""), System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task CompletionEndpoint_UsesInjectedExecutorAndRecordsMetrics()
    {
        int port = 19765 + System.Environment.ProcessId % 1000;
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute("claude-route", "anthropic", "claude", 1, true),
        });
        var executor = new DelegateModelCompletionExecutor((route, body, _) =>
        {
            Assert.Equal("claude-route", route.Id);
            Assert.Contains("hello", Encoding.UTF8.GetString(body), System.StringComparison.Ordinal);
            return Task.FromResult(new ModelCompletionResult(
                200,
                Encoding.UTF8.GetBytes("{\"id\":\"completion-1\"}"),
                "application/json",
                true));
        });

        await using var host = new LocalHttpGatewayHost(port, router, executor);
        host.Start();
        using var client = new HttpClient { BaseAddress = host.BaseAddress };
        using var request = new StringContent(
            "{\"model\":\"claude\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}",
            Encoding.UTF8,
            "application/json");

        HttpResponseMessage response = await client.PostAsync("v1/chat/completions", request);
        string body = await response.Content.ReadAsStringAsync();

        Assert.Equal(200, (int)response.StatusCode);
        Assert.Contains("completion-1", body, System.StringComparison.Ordinal);
        RouteMetrics metrics = router.SnapshotMetrics()["claude-route"];
        Assert.Equal(1, metrics.Attempts);
        Assert.Equal(1, metrics.Successes);
    }

    [Fact]
    public async Task CompletionEndpoint_DegradesOnlyWhenAllowed()
    {
        int port = 20765 + System.Environment.ProcessId % 1000;
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute("fallback", "openai", "gpt", 2, true),
            new ModelRoute("preferred", "anthropic", "claude", 1, false),
        });
        string? selected = null;
        var executor = new DelegateModelCompletionExecutor((route, _, _) =>
        {
            selected = route.Id;
            return Task.FromResult(new ModelCompletionResult(
                200,
                Encoding.UTF8.GetBytes("{}"),
                "application/json",
                true));
        });

        await using var host = new LocalHttpGatewayHost(port, router, executor);
        host.Start();
        using var client = new HttpClient { BaseAddress = host.BaseAddress };

        using var allow = new StringContent(
            "{\"model\":\"claude\",\"messages\":[],\"openburnbar_allow_degrade\":true}",
            Encoding.UTF8,
            "application/json");
        HttpResponseMessage degraded = await client.PostAsync("v1/chat/completions", allow);
        Assert.Equal(200, (int)degraded.StatusCode);
        Assert.Equal("fallback", selected);

        using var deny = new StringContent(
            "{\"model\":\"claude\",\"messages\":[],\"openburnbar_allow_degrade\":false}",
            Encoding.UTF8,
            "application/json");
        HttpResponseMessage failed = await client.PostAsync("v1/chat/completions", deny);
        Assert.Equal(503, (int)failed.StatusCode);
    }

    [Fact]
    public async Task ProtectedGateway_RequiresBearerToken()
    {
        int port = 21765 + System.Environment.ProcessId % 1000;
        await using var host = new LocalHttpGatewayHost(
            port,
            new ModelProxyRouter(new[]
            {
                new ModelRoute("local", "openburnbar", "local", 0, true),
            }),
            new DelegateModelCompletionExecutor((_, _, _) =>
                Task.FromResult(new ModelCompletionResult(200, Encoding.UTF8.GetBytes("{}"), "application/json", true))),
            accessToken: "gateway-secret");
        host.Start();
        using var client = new HttpClient { BaseAddress = host.BaseAddress };

        HttpResponseMessage unauthorized = await client.GetAsync("v1/models");
        Assert.Equal(401, (int)unauthorized.StatusCode);

        using var authorized = new HttpRequestMessage(HttpMethod.Get, "v1/models");
        authorized.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "gateway-secret");
        HttpResponseMessage response = await client.SendAsync(authorized);
        Assert.Equal(200, (int)response.StatusCode);
    }

    [Fact]
    public async Task CompletionEndpoint_RejectsOversizedBodies()
    {
        int port = 22765 + System.Environment.ProcessId % 1000;
        await using var host = new LocalHttpGatewayHost(
            port,
            new ModelProxyRouter(new[]
            {
                new ModelRoute("local", "openburnbar", "local", 0, true),
            }),
            new DelegateModelCompletionExecutor((_, _, _) =>
                Task.FromResult(new ModelCompletionResult(200, Encoding.UTF8.GetBytes("{}"), "application/json", true))),
            maxRequestBytes: 32);
        host.Start();
        using var client = new HttpClient { BaseAddress = host.BaseAddress };
        using var request = new StringContent(
            "{\"model\":\"local\",\"messages\":[{\"content\":\"this is too long\"}]}",
            Encoding.UTF8,
            "application/json");

        HttpResponseMessage response = await client.PostAsync("v1/chat/completions", request);
        Assert.Equal(413, (int)response.StatusCode);
    }
}

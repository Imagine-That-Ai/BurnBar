using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class LocalHttpGatewayHostTests
{
    [Fact]
    public async Task Constructor_UsesValidatedCustomHostForBaseAddress()
    {
        await using var host = new LocalHttpGatewayHost(
            "localhost",
            8317,
            new ModelProxyRouter(new[]
            {
                new ModelRoute("local", "openburnbar", "local", 0, true),
            }),
            new DelegateModelCompletionExecutor((_, _, _) =>
                Task.FromResult(new ModelCompletionResult(200, Encoding.UTF8.GetBytes("{}"), "application/json", true))));

        Assert.Equal("localhost", host.Host);
        Assert.Equal(8317, host.Port);
        Assert.Equal("http://localhost:8317/", host.BaseAddress.AbsoluteUri);
    }

    [Fact]
    public void Constructor_RejectsInvalidCustomHost()
    {
        Assert.Throws<System.ArgumentException>(() => new LocalHttpGatewayHost(
            "http://localhost",
            8317,
            new ModelProxyRouter(new[]
            {
                new ModelRoute("local", "openburnbar", "local", 0, true),
            }),
            new DelegateModelCompletionExecutor((_, _, _) =>
                Task.FromResult(new ModelCompletionResult(200, Encoding.UTF8.GetBytes("{}"), "application/json", true)))));
    }

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
                Encoding.UTF8.GetBytes(
                    "{\"id\":\"completion-1\",\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":4}}"),
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

        using JsonDocument telemetryDocument = JsonDocument.Parse(
            await client.GetStringAsync("v1/metrics"));
        JsonElement telemetry = telemetryDocument.RootElement.GetProperty("telemetry");
        Assert.Equal(1, telemetry.GetProperty("retained_requests").GetInt32());
        Assert.Equal(12, telemetry.GetProperty("input_tokens").GetInt64());
        Assert.Equal(4, telemetry.GetProperty("output_tokens").GetInt64());
        JsonElement recent = telemetryDocument.RootElement.GetProperty("recent_routes")[0];
        Assert.Equal("claude", recent.GetProperty("client_model").GetString());
        Assert.Equal("claude-route", recent.GetProperty("route_id").GetString());
    }

    [Fact]
    public async Task CompletionEndpoint_DegradesOnlyWhenAllowed()
    {
        int port = 20765 + System.Environment.ProcessId % 1000;
        var router = new ModelProxyRouter(
            new[]
            {
                new ModelRoute("fallback", "openai", "gpt", 2, true),
                new ModelRoute("preferred", "anthropic", "claude", 1, false),
            },
            degradePolicy: CrossVendorDegradePolicy.Create(
                true,
                new[] { "openai" },
                new System.Collections.Generic.Dictionary<string, string>
                {
                    ["openai"] = "gpt",
                }));
        string? selected = null;
        string? upstreamModel = null;
        var executor = new DelegateModelCompletionExecutor((route, body, _) =>
        {
            selected = route.Id;
            using JsonDocument forwarded = JsonDocument.Parse(body);
            upstreamModel = forwarded.RootElement.GetProperty("model").GetString();
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
        Assert.Equal("gpt", upstreamModel);

        using var deny = new StringContent(
            "{\"model\":\"claude\",\"messages\":[],\"openburnbar_allow_degrade\":false}",
            Encoding.UTF8,
            "application/json");
        HttpResponseMessage failed = await client.PostAsync("v1/chat/completions", deny);
        Assert.Equal(503, (int)failed.StatusCode);

        using var omitted = new StringContent(
            "{\"model\":\"claude\",\"messages\":[]}",
            Encoding.UTF8,
            "application/json");
        HttpResponseMessage defaulted = await client.PostAsync("v1/chat/completions", omitted);
        Assert.Equal(503, (int)defaulted.StatusCode);
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
    public async Task ModelsEndpoint_AdvertisesProviderAndEligibilityMetadata()
    {
        int port = 22265 + System.Environment.ProcessId % 1000;
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute(
                "claude-route",
                "anthropic",
                "claude-sonnet-4",
                1,
                true,
                new System.Uri("https://api.anthropic.com/v1/messages")),
            new ModelRoute(
                "offline-route",
                "openai",
                "gpt-5",
                2,
                false,
                new System.Uri("https://api.openai.com/v1/chat/completions")),
        });
        await using var host = new LocalHttpGatewayHost(
            port,
            router,
            new DelegateModelCompletionExecutor((_, _, _) =>
                Task.FromResult(new ModelCompletionResult(200, Encoding.UTF8.GetBytes("{}"), "application/json", true))));
        host.Start();
        using var client = new HttpClient { BaseAddress = host.BaseAddress };

        using JsonDocument document = JsonDocument.Parse(await client.GetStringAsync("v1/models"));
        JsonElement models = document.RootElement.GetProperty("data");

        Assert.Equal(2, models.GetArrayLength());
        JsonElement claude = models[0];
        Assert.Equal("anthropic", claude.GetProperty("provider_id").GetString());
        Assert.Equal("anthropic", claude.GetProperty("provider_name").GetString());
        Assert.True(claude.GetProperty("route_eligible").GetBoolean());
        Assert.False(models[1].GetProperty("route_eligible").GetBoolean());
    }

    [Fact]
    public async Task ModelsAndMetricsExposeFailureDrivenHealthWithoutProviderBody()
    {
        int port = 23265 + System.Environment.ProcessId % 1000;
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute(
                "provider-route",
                "openai",
                "gpt-test",
                0,
                true,
                new System.Uri("https://api.openai.com/v1/chat/completions")),
        });
        await using var host = new LocalHttpGatewayHost(
            port,
            router,
            new DelegateModelCompletionExecutor((_, _, _) => Task.FromResult(
                new ModelCompletionResult(
                    429,
                    Encoding.UTF8.GetBytes("provider-body-secret"),
                    "application/json",
                    false))));
        host.Start();
        using var client = new HttpClient { BaseAddress = host.BaseAddress };
        using var request = new StringContent(
            "{\"model\":\"gpt-test\",\"messages\":[]}",
            Encoding.UTF8,
            "application/json");

        Assert.Equal(429, (int)(await client.PostAsync("v1/chat/completions", request)).StatusCode);
        string modelsBody = await client.GetStringAsync("v1/models");
        string metricsBody = await client.GetStringAsync("v1/metrics");

        using JsonDocument models = JsonDocument.Parse(modelsBody);
        JsonElement model = models.RootElement.GetProperty("data")[0];
        Assert.False(model.GetProperty("healthy").GetBoolean());
        Assert.False(model.GetProperty("route_eligible").GetBoolean());
        Assert.Equal("RateLimit", model.GetProperty("health_failure").GetString());
        Assert.Contains("RateLimit", metricsBody, System.StringComparison.Ordinal);
        Assert.DoesNotContain("provider-body-secret", modelsBody, System.StringComparison.Ordinal);
        Assert.DoesNotContain("provider-body-secret", metricsBody, System.StringComparison.Ordinal);
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

    [Fact]
    public async Task CompletionEndpoint_RateLimitsBeforeProviderExecution()
    {
        int port = 23765 + System.Environment.ProcessId % 1000;
        int executions = 0;
        await using var host = new LocalHttpGatewayHost(
            port,
            new ModelProxyRouter(new[]
            {
                new ModelRoute("local", "openburnbar", "local", 0, true),
            }),
            new DelegateModelCompletionExecutor((_, _, _) =>
            {
                System.Threading.Interlocked.Increment(ref executions);
                return Task.FromResult(new ModelCompletionResult(
                    200,
                    Encoding.UTF8.GetBytes("{}"),
                    "application/json",
                    true));
            }),
            accessToken: "test-token",
            rateLimiter: new GatewayRateLimiter(new GatewayRateLimitConfiguration(0.1, 1)));
        host.Start();
        using var client = new HttpClient { BaseAddress = host.BaseAddress };
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "wrong-token");
        HttpResponseMessage unauthorized = await PostCompletionAsync(client);
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "test-token");

        HttpResponseMessage first = await PostCompletionAsync(client);
        HttpResponseMessage second = await PostCompletionAsync(client);

        Assert.Equal(401, (int)unauthorized.StatusCode);
        Assert.Equal(200, (int)first.StatusCode);
        Assert.Equal(429, (int)second.StatusCode);
        Assert.Equal(System.TimeSpan.FromSeconds(10), second.Headers.RetryAfter?.Delta);
        Assert.Equal(1, executions);
        string responseBody = await second.Content.ReadAsStringAsync();
        Assert.Contains("rate_limit_error", responseBody, System.StringComparison.Ordinal);
        Assert.DoesNotContain("test-token", responseBody, System.StringComparison.Ordinal);
    }

    [Fact]
    public async Task UnauthenticatedLoopback_UsesOneSharedBucketAcrossInventedBearerValues()
    {
        int port = 24765 + System.Environment.ProcessId % 1000;
        int executions = 0;
        await using var host = new LocalHttpGatewayHost(
            port,
            new ModelProxyRouter(new[]
            {
                new ModelRoute("local", "openburnbar", "local", 0, true),
            }),
            new DelegateModelCompletionExecutor((_, _, _) =>
            {
                System.Threading.Interlocked.Increment(ref executions);
                return Task.FromResult(new ModelCompletionResult(
                    200,
                    Encoding.UTF8.GetBytes("{}"),
                    "application/json",
                    true));
            }),
            rateLimiter: new GatewayRateLimiter(new GatewayRateLimitConfiguration(100, 100)),
            unauthenticatedLoopbackRateLimiter:
                new GatewayRateLimiter(new GatewayRateLimitConfiguration(0.1, 1)));
        host.Start();
        using var client = new HttpClient { BaseAddress = host.BaseAddress };

        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "invented-a");
        HttpResponseMessage first = await PostCompletionAsync(client);
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "invented-b");
        HttpResponseMessage second = await PostCompletionAsync(client);

        Assert.Equal(200, (int)first.StatusCode);
        Assert.Equal(429, (int)second.StatusCode);
        Assert.Equal(1, executions);
    }

    private static Task<HttpResponseMessage> PostCompletionAsync(HttpClient client) =>
        client.PostAsync(
            "v1/chat/completions",
            new StringContent(
                "{\"model\":\"local\",\"messages\":[]}",
                Encoding.UTF8,
                "application/json"));
}

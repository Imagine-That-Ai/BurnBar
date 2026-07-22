using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

[Collection(LoopbackGatewayCollection.Name)]
public sealed class GatewayLiveModelDiscoveryTests
{
    [Fact]
    public async Task OllamaUsesNativeTagsAndAdvertisesOnlyInstalledLocalModels()
    {
        var handler = new SequenceHandler(_ => JsonResponse(
            "{\"models\":[{\"name\":\"llama3.2:latest\"},{\"name\":\"deepseek-r1:8b\"},{\"name\":\"remote:cloud\"}]}"));
        using var client = new HttpClient(handler);
        var router = new ModelProxyRouter(new[] { Route("ollama", "seed", "http://127.0.0.1:11434") });
        using var discovery = new GatewayLiveModelDiscovery(router, client);

        GatewayModelDiscoverySnapshot snapshot = await discovery.RefreshAsync();

        Assert.Equal("http://127.0.0.1:11434/api/tags", handler.Requests.Single().Uri.ToString());
        Assert.Equal(2, snapshot.DiscoveredRouteCount);
        Assert.Equal(
            new[] { "deepseek-r1:8b", "llama3.2:latest", "seed" },
            router.Routes.Select(route => route.Model).OrderBy(model => model).ToArray());
        Assert.All(router.Routes.Where(route => route.Discovery is not null), route =>
        {
            Assert.Equal("local_ollama_models_endpoint", route.Discovery!.SourceKind);
            Assert.Equal("route", route.Discovery.SourceRouteId);
            Assert.True(route.IsExecutable);
        });
    }

    [Fact]
    public async Task LoopbackOpenAiCatalogUsesBearerAndDeduplicatesModels()
    {
        var handler = new SequenceHandler(_ => JsonResponse(
            "{\"data\":[{\"id\":\"model-a\",\"display_name\":\"Model A\"},{\"id\":\"MODEL-A\"},{\"id\":\"model-b\",\"name\":\"Model B\"},{\"id\":\"model-c\",\"display_name\":\"Bad\\u0001Name\"},{\"id\":\"\"}]}"));
        using var client = new HttpClient(handler);
        var source = new ModelRoute(
            "route", "openai-compatible", "seed", 0, true,
            new Uri("http://localhost:1234/v1/chat/completions"),
            "provider-secret");
        var router = new ModelProxyRouter(new[] { source });
        using var discovery = new GatewayLiveModelDiscovery(router, client);

        await discovery.RefreshAsync();

        CapturedRequest request = Assert.Single(handler.Requests);
        Assert.Equal("http://localhost:1234/v1/models", request.Uri.ToString());
        Assert.Equal("Bearer", request.AuthorizationScheme);
        Assert.Equal("provider-secret", request.AuthorizationParameter);
        ModelRoute[] discovered = router.Routes.Where(route => route.Discovery is not null).ToArray();
        Assert.Equal(3, discovered.Length);
        Assert.Contains(discovered, route => route.Model == "model-a" && route.Discovery!.DisplayName == "Model A");
        Assert.Contains(discovered, route => route.Model == "model-b" && route.Discovery!.DisplayName == "Model B");
        Assert.Contains(discovered, route => route.Model == "model-c" && route.Discovery!.DisplayName == "model-c");
    }

    [Fact]
    public async Task RemoteHttpRoutesAreNeverProbedByLocalDiscovery()
    {
        var handler = new SequenceHandler(_ => throw new InvalidOperationException("must not send"));
        using var client = new HttpClient(handler);
        var router = new ModelProxyRouter(new[]
        {
            Route("openai", "gpt", "https://api.example.test/v1/chat/completions"),
        });
        using var discovery = new GatewayLiveModelDiscovery(router, client);

        GatewayModelDiscoverySnapshot snapshot = await discovery.RefreshAsync();

        Assert.Empty(handler.Requests);
        Assert.Equal(0, snapshot.DiscoveredRouteCount);
        Assert.Single(router.Routes);
    }

    [Fact]
    public async Task FailedAuthoritativeRefreshRemovesPreviouslyDiscoveredRoutes()
    {
        int call = 0;
        var handler = new SequenceHandler(_ =>
        {
            call++;
            return call == 1
                ? JsonResponse("{\"data\":[{\"id\":\"live-model\"}]}")
                : new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        });
        using var client = new HttpClient(handler);
        var router = new ModelProxyRouter(new[]
        {
            Route("openai-compatible", "seed", "http://127.0.0.1:1234/v1/chat/completions"),
        });
        using var discovery = new GatewayLiveModelDiscovery(router, client);

        Assert.Equal(1, (await discovery.RefreshAsync()).DiscoveredRouteCount);
        GatewayModelDiscoverySnapshot failed = await discovery.RefreshAsync();

        Assert.Equal(0, failed.DiscoveredRouteCount);
        Assert.Single(router.Routes);
        Assert.Equal("Discovery failed with HTTP 503.", failed.Sources.Single().Error);
    }

    [Fact]
    public async Task AuthenticationHealthTracksDiscoveryWithoutCompletionMetricsOrCredentialLeak()
    {
        int requestCount = 0;
        var handler = new SequenceHandler(_ => requestCount++ == 0
            ? new HttpResponseMessage(HttpStatusCode.Unauthorized)
            : JsonResponse("{\"data\":[{\"id\":\"recovered-model\"}]}"));
        using var client = new HttpClient(handler);
        ModelRoute source = new(
            "route", "openai-compatible", "seed", 0, true,
            new Uri("http://127.0.0.1:1234/v1/chat/completions"),
            "secret-that-must-not-leak");
        var router = new ModelProxyRouter(new[] { source });
        using var discovery = new GatewayLiveModelDiscovery(router, client);

        GatewayModelDiscoverySnapshot snapshot = await discovery.RefreshAsync();

        ModelRouteHealthRecord failure = Assert.IsType<ModelRouteHealthRecord>(router.ActiveHealthFailure(source));
        Assert.Equal(ModelRouteHealthFailureKind.Authentication, failure.FailureKind);
        Assert.DoesNotContain("secret-that-must-not-leak", snapshot.Sources.Single().Error, StringComparison.Ordinal);
        Assert.Empty(router.SnapshotMetrics());

        GatewayModelDiscoverySnapshot recovered = await discovery.RefreshAsync();

        Assert.Equal(1, recovered.DiscoveredRouteCount);
        Assert.Null(router.ActiveHealthFailure(source));
        Assert.Empty(router.SnapshotMetrics());
        Assert.All(handler.Requests, request =>
        {
            Assert.Equal("Bearer", request.AuthorizationScheme);
            Assert.Equal("secret-that-must-not-leak", request.AuthorizationParameter);
        });
    }

    [Fact]
    public async Task FactoryDiscoveryUsesReviewedHelpContractAndCleansDirectory()
    {
        ProviderCliProcessRequest? captured = null;
        var runner = new DelegateRunner(request =>
        {
            captured = request;
            Assert.True(Directory.Exists(request.WorkingDirectory));
            return new ProviderCliProcessResult(
                0,
                "Usage:\n\nAvailable Models:\n  claude-sonnet Claude Sonnet\n  gpt-5 GPT 5\n\nOptions:\n  --help Help\n",
                string.Empty);
        });
        using var client = new HttpClient(new SequenceHandler(_ => throw new InvalidOperationException("no HTTP")));
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute(
                "factory-route", "factory", "seed", 0, true,
                new Uri("cli://factory"), "factory-secret"),
        });
        using var discovery = new GatewayLiveModelDiscovery(router, client, runner);

        GatewayModelDiscoverySnapshot snapshot = await discovery.RefreshAsync();

        Assert.NotNull(captured);
        Assert.Equal("droid", captured.ExecutableId);
        Assert.Equal(new[] { "exec", "--help" }, captured.Arguments);
        Assert.Equal("factory-secret", captured.RequiredEnvironment["FACTORY_API_KEY"]);
        Assert.Equal(2, snapshot.DiscoveredRouteCount);
        Assert.False(Directory.Exists(captured.WorkingDirectory));
        Assert.Contains(router.Routes, route => route.Model == "claude-sonnet");
        Assert.Contains(router.Routes, route => route.Model == "gpt-5");
    }

    [Fact]
    public async Task FactoryDiscoveryRejectsOversizedCatalog()
    {
        var runner = new DelegateRunner(_ => new ProviderCliProcessResult(
            0,
            new string('x', GatewayLiveModelDiscovery.MaximumResponseBytes + 1),
            string.Empty));
        using var client = new HttpClient(new SequenceHandler(_ => throw new InvalidOperationException("no HTTP")));
        var router = new ModelProxyRouter(new[]
        {
            new ModelRoute(
                "factory-route", "factory", "seed", 0, true,
                new Uri("cli://factory"), "factory-secret"),
        });
        using var discovery = new GatewayLiveModelDiscovery(router, client, runner);

        GatewayModelDiscoverySnapshot snapshot = await discovery.RefreshAsync();

        Assert.Equal(0, snapshot.DiscoveredRouteCount);
        Assert.Single(router.Routes);
        Assert.Contains("bounded size", snapshot.Sources.Single().Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task DiscoveredModelCannotShadowConfiguredRoute()
    {
        var handler = new SequenceHandler(_ => JsonResponse(
            "{\"data\":[{\"id\":\"configured\"},{\"id\":\"new-model\"}]}"));
        using var client = new HttpClient(handler);
        var router = new ModelProxyRouter(new[]
        {
            Route("openai-compatible", "configured", "http://127.0.0.1:1234/v1/chat/completions"),
        });
        using var discovery = new GatewayLiveModelDiscovery(router, client);

        GatewayModelDiscoverySnapshot snapshot = await discovery.RefreshAsync();

        Assert.Equal(1, snapshot.DiscoveredRouteCount);
        Assert.Equal(2, router.Routes.Count);
        Assert.Single(router.Routes, route => route.Model == "configured");
        Assert.Single(router.Routes, route => route.Model == "new-model");
    }

    [Fact]
    public async Task OversizedResponseFailsClosedWithoutDiscoveredRoutes()
    {
        var handler = new SequenceHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent(new byte[GatewayLiveModelDiscovery.MaximumResponseBytes + 1]),
        });
        using var client = new HttpClient(handler);
        var router = new ModelProxyRouter(new[]
        {
            Route("openai-compatible", "seed", "http://127.0.0.1:1234/v1/chat/completions"),
        });
        using var discovery = new GatewayLiveModelDiscovery(router, client);

        GatewayModelDiscoverySnapshot snapshot = await discovery.RefreshAsync();

        Assert.Equal(0, snapshot.DiscoveredRouteCount);
        Assert.Single(router.Routes);
        Assert.Contains("bounded size", snapshot.Sources.Single().Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ModelsEndpointExposesDiscoveryProvenance()
    {
        int port = 24765 + Environment.ProcessId % 1000;
        ModelRoute configured = Route(
            "openai-compatible", "seed", "http://127.0.0.1:1234/v1/chat/completions");
        var router = new ModelProxyRouter(new[] { configured });
        using var discoveryClient = new HttpClient(new SequenceHandler(_ => JsonResponse(
            "{\"data\":[{\"id\":\"llama3.2:latest\",\"display_name\":\"Llama 3.2\"}]}")));
        using var discovery = new GatewayLiveModelDiscovery(router, discoveryClient);
        await discovery.RefreshAsync();
        await using var host = new LocalHttpGatewayHost(
            port,
            router,
            new RecordingExecutor(),
            discovery: discovery);
        host.Start();
        using var client = new HttpClient { BaseAddress = host.BaseAddress };

        using JsonDocument document = JsonDocument.Parse(await client.GetStringAsync("v1/models"));
        JsonElement row = document.RootElement.GetProperty("data")
            .EnumerateArray()
            .Single(item => item.GetProperty("id").GetString() == "llama3.2:latest");

        Assert.True(row.GetProperty("discovered").GetBoolean());
        Assert.Equal("Llama 3.2", row.GetProperty("display_name").GetString());
        Assert.Equal("local_openai_models_endpoint", row.GetProperty("discovery_source").GetString());
        Assert.Equal("route", row.GetProperty("source_route_id").GetString());
        JsonElement discoveryStatus = document.RootElement.GetProperty("discovery");
        Assert.Equal(1, discoveryStatus.GetProperty("discovered_route_count").GetInt32());
        Assert.Equal(1, discoveryStatus.GetProperty("sources")[0].GetProperty("model_count").GetInt32());
    }

    private static ModelRoute Route(string vendor, string model, string endpoint) =>
        new("route", vendor, model, 0, true, new Uri(endpoint));

    private static HttpResponseMessage JsonResponse(string body) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json"),
    };

    private sealed record CapturedRequest(
        Uri Uri,
        string? AuthorizationScheme,
        string? AuthorizationParameter);

    private sealed class SequenceHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _handler;

        public SequenceHandler(Func<HttpRequestMessage, HttpResponseMessage> handler) =>
            _handler = handler;

        public List<CapturedRequest> Requests { get; } = new();

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Requests.Add(new CapturedRequest(
                request.RequestUri!,
                request.Headers.Authorization?.Scheme,
                request.Headers.Authorization?.Parameter));
            return Task.FromResult(_handler(request));
        }
    }

    private sealed class DelegateRunner : IProviderCliProcessRunner
    {
        private readonly Func<ProviderCliProcessRequest, ProviderCliProcessResult> _handler;

        public DelegateRunner(Func<ProviderCliProcessRequest, ProviderCliProcessResult> handler) =>
            _handler = handler;

        public Task<ProviderCliProcessResult> RunAsync(
            ProviderCliProcessRequest request,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(_handler(request));
    }

    private sealed class RecordingExecutor : IModelCompletionExecutor
    {
        public Task<ModelCompletionResult> ExecuteAsync(
            ModelRoute route,
            byte[] requestBody,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new ModelCompletionResult(200, Array.Empty<byte>(), "application/json", true));
    }
}

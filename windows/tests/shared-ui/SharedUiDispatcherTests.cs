using System.Collections.Generic;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace OpenBurnBar.App.SharedUi.Tests;

/// <summary>
/// Dispatcher routing + reply contract: unknown commands fail with the
/// capability-absent wire string, backed commands pass raw daemon-shaped JSON
/// through, validation failures carry the pinned taxonomies, and channel
/// streaming emits chunks before the resolving invoke-result.
/// </summary>
public sealed class SharedUiDispatcherTests
{
    private sealed record Emitted(JsonObject Message)
    {
        public string Kind => Message["kind"]!.GetValue<string>();
    }

    private sealed class Collector
    {
        public List<Emitted> Messages { get; } = new();

        public SharedUiDispatcher.EmitAsync Emit => (message, ct) =>
        {
            Messages.Add(new Emitted((JsonObject)message.DeepClone()));
            return Task.CompletedTask;
        };

        public Emitted Last => Messages[^1];
    }

    private static SharedUiDispatcher CreateDispatcher(
        ISharedUiDataPlane? data = null,
        ISharedUiGatewayPlane? gateway = null,
        ISharedUiSystemPlane? system = null) =>
        new(new SharedUiDispatcherOptions
        {
            ShellVersion = "9.9.9-test",
            Data = data,
            Gateway = gateway,
            System = system,
            CapabilityStatus = () => new SharedUiCapabilityStatus
            {
                StorageReady = true,
                SessionLogsReady = true,
                GatewayRunning = gateway is not null,
            },
        });

    private static string Invoke(int id, string command, string args = "{}") =>
        $$"""{"kind":"invoke","id":{{id}},"command":"{{command}}","args":{{args}}}""";

    [Fact]
    public async Task UnknownCommandFailsWithCapabilityAbsentWireString()
    {
        var collector = new Collector();
        await CreateDispatcher().HandleMessageAsync(Invoke(5, "pet_feed"), collector.Emit);

        var reply = collector.Last.Message;
        Assert.Equal("invoke-result", reply["kind"]!.GetValue<string>());
        Assert.Equal(5, reply["id"]!.GetValue<int>());
        Assert.False(reply["ok"]!.GetValue<bool>());
        // The exact substring the frontend's isCapabilityAbsentError matches.
        Assert.Contains("not implemented on Windows", reply["error"]!.GetValue<string>());
    }

    [Fact]
    public async Task MalformedMessageProducesNoReply()
    {
        var collector = new Collector();
        await CreateDispatcher().HandleMessageAsync("{\"kind\":\"nope\"}", collector.Emit);
        Assert.Empty(collector.Messages);
    }

    [Fact]
    public async Task ListenRegistrationProducesNoReply()
    {
        var collector = new Collector();
        await CreateDispatcher().HandleMessageAsync(
            """{"kind":"listen","event":"media-incoming-call"}""", collector.Emit);
        Assert.Empty(collector.Messages);
    }

    [Fact]
    public async Task UsageSummaryPassesRawDaemonShapeThrough()
    {
        var data = new FakeDataPlane();
        var collector = new Collector();
        await CreateDispatcher(data: data).HandleMessageAsync(Invoke(1, "usage_summary"), collector.Emit);

        Assert.Equal(50, data.LastUsageLimit); // the Linux limit for usage_summary
        var reply = collector.Last.Message;
        Assert.True(reply["ok"]!.GetValue<bool>());
        Assert.Equal("claude", reply["value"]!["usage"]![0]!["providerId"]!.GetValue<string>());
        Assert.Equal(123, reply["value"]!["usage"]![0]!["tokens"]!.GetValue<long>());
    }

    [Fact]
    public async Task UsageCalendarUsesTheWiderLinuxLimit()
    {
        var data = new FakeDataPlane();
        var collector = new Collector();
        await CreateDispatcher(data: data).HandleMessageAsync(Invoke(1, "usage_calendar"), collector.Emit);
        Assert.Equal(2000, data.LastUsageLimit);
    }

    [Fact]
    public async Task SessionSearchRequiresQuery()
    {
        var collector = new Collector();
        await CreateDispatcher(data: new FakeDataPlane())
            .HandleMessageAsync(Invoke(2, "session_search"), collector.Emit);
        Assert.False(collector.Last.Message["ok"]!.GetValue<bool>());
        Assert.Contains("query", collector.Last.Message["error"]!.GetValue<string>());
    }

    [Fact]
    public async Task DaemonHealthNeverRejects()
    {
        var collector = new Collector();
        await CreateDispatcher().HandleMessageAsync(Invoke(3, "daemon_health"), collector.Emit);
        var reply = collector.Last.Message;
        Assert.True(reply["ok"]!.GetValue<bool>());
        Assert.True(reply["value"]!["ok"]!.GetValue<bool>());
        Assert.Equal("windows-inproc", reply["value"]!["daemonVersion"]!.GetValue<string>());
    }

    [Fact]
    public async Task GatewayProbeWithoutGatewayReturnsFalse()
    {
        var collector = new Collector();
        await CreateDispatcher().HandleMessageAsync(Invoke(4, "gateway_probe"), collector.Emit);
        Assert.True(collector.Last.Message["ok"]!.GetValue<bool>());
        Assert.False(collector.Last.Message["value"]!.GetValue<bool>());
    }

    [Fact]
    public async Task OpenExternalUrlValidatesTheStripeAllowlist()
    {
        var system = new FakeSystemPlane();
        var collector = new Collector();
        await CreateDispatcher(system: system).HandleMessageAsync(
            Invoke(6, "open_external_url", """{"url":"https://evil.example.com/checkout"}"""), collector.Emit);
        Assert.False(collector.Last.Message["ok"]!.GetValue<bool>());
        Assert.Equal("external_url_host_refused", collector.Last.Message["error"]!.GetValue<string>());
        Assert.Null(system.OpenedUrl);

        await CreateDispatcher(system: system).HandleMessageAsync(
            Invoke(7, "open_external_url", """{"url":"https://checkout.stripe.com/c/pay_123"}"""), collector.Emit);
        Assert.True(collector.Last.Message["ok"]!.GetValue<bool>());
        Assert.NotNull(system.OpenedUrl);
    }

    [Fact]
    public async Task GatewayChatStreamEmitsChunksBeforeResolvingInvoke()
    {
        var gateway = new FakeGatewayPlane("data: hello\n\n", "data: [DONE]\n\n");
        var collector = new Collector();
        await CreateDispatcher(gateway: gateway).HandleMessageAsync(
            Invoke(8, "gateway_chat_stream",
                """{"request":{"requestId":"req-1","model":"m","messages":[{"role":"user","content":"hi"}]},"onEvent":{"__channel":77}}"""),
            collector.Emit);

        Assert.Equal(3, collector.Messages.Count);
        Assert.Equal("channel", collector.Messages[0].Kind);
        Assert.Equal(77, collector.Messages[0].Message["channelId"]!.GetValue<int>());
        Assert.Equal("data: hello\n\n", collector.Messages[0].Message["chunk"]!.GetValue<string>());
        Assert.Equal("channel", collector.Messages[1].Kind);
        Assert.Equal("invoke-result", collector.Messages[2].Kind);
        Assert.True(collector.Messages[2].Message["ok"]!.GetValue<bool>());
    }

    [Fact]
    public async Task GatewayChatStreamRejectsBadRequestIdWithPinnedError()
    {
        var collector = new Collector();
        await CreateDispatcher(gateway: new FakeGatewayPlane()).HandleMessageAsync(
            Invoke(9, "gateway_chat_stream",
                """{"request":{"requestId":"bad id!","model":"m","messages":[{"role":"user","content":"hi"}]},"onEvent":{"__channel":77}}"""),
            collector.Emit);
        Assert.False(collector.Last.Message["ok"]!.GetValue<bool>());
        Assert.Equal("gateway_invalid_request_id", collector.Last.Message["error"]!.GetValue<string>());
    }

    [Fact]
    public async Task DataPlaneExceptionBecomesInvokeError()
    {
        var data = new ThrowingDataPlane();
        var collector = new Collector();
        await CreateDispatcher(data: data).HandleMessageAsync(Invoke(10, "usage_summary"), collector.Emit);
        Assert.False(collector.Last.Message["ok"]!.GetValue<bool>());
        Assert.Equal("boom", collector.Last.Message["error"]!.GetValue<string>());
    }

    // ── fakes ────────────────────────────────────────────────────────────

    private sealed class FakeDataPlane : ISharedUiDataPlane
    {
        public int LastUsageLimit { get; private set; }

        public Task<JsonObject> GetRecentUsageAsync(int limit, CancellationToken ct)
        {
            LastUsageLimit = limit;
            return Task.FromResult(new JsonObject
            {
                ["usage"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["id"] = "evt-1",
                        ["providerId"] = "claude",
                        ["modelId"] = "opus",
                        ["tokens"] = 123L,
                        ["costUsd"] = 0.5,
                        ["recordedAt"] = "2026-07-23T00:00:00.0000000+00:00",
                    },
                },
            });
        }

        public Task<JsonObject> ListSessionsAsync(int limit, CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["sessions"] = new JsonArray(), ["nextCursor"] = null });

        public Task<JsonObject> SearchSessionsAsync(string query, CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["sessions"] = new JsonArray(), ["nextCursor"] = null });

        public Task<JsonObject> GetConfigSnapshotAsync(CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["telemetryEnabled"] = false });

        public Task<JsonObject> GetProviderCatalogAsync(CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["providers"] = new JsonArray() });

        public Task<JsonObject> ApplyConfigUpdateAsync(JsonObject snapshot, CancellationToken ct) =>
            Task.FromResult(snapshot);

        public Task<JsonObject> GetDatabaseStatusAsync(CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["sqlcipherOk"] = true });

        public Task<JsonObject> GetAccountStatusAsync(CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["state"] = "signed_out", ["signedIn"] = false });

        public Task<JsonObject> GetUpdateStatusAsync(CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["state"] = "current" });

        public Task<JsonObject> GetAppVersionInfoAsync(CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["shellVersion"] = "1.0.0" });

        public Task<JsonObject> GetProxyRouteLogAsync(int limit, CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["entries"] = new JsonArray() });

        public Task<JsonObject> ClearProxyRouteLogAsync(CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["cleared"] = true });

        public Task<JsonObject> GetDatabaseWorkspaceStatusAsync(string? projectPath, CancellationToken ct) =>
            Task.FromResult(new JsonObject { ["indexStatus"] = new JsonObject { ["ok"] = false } });
    }

    private sealed class ThrowingDataPlane : ISharedUiDataPlane
    {
        public Task<JsonObject> GetRecentUsageAsync(int limit, CancellationToken ct) =>
            throw new System.InvalidOperationException("boom");

        public Task<JsonObject> ListSessionsAsync(int limit, CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> SearchSessionsAsync(string query, CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> GetConfigSnapshotAsync(CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> GetProviderCatalogAsync(CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> ApplyConfigUpdateAsync(JsonObject snapshot, CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> GetDatabaseStatusAsync(CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> GetAccountStatusAsync(CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> GetUpdateStatusAsync(CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> GetAppVersionInfoAsync(CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> GetProxyRouteLogAsync(int limit, CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> ClearProxyRouteLogAsync(CancellationToken ct) => throw new System.NotImplementedException();
        public Task<JsonObject> GetDatabaseWorkspaceStatusAsync(string? projectPath, CancellationToken ct) => throw new System.NotImplementedException();
    }

    private sealed class FakeGatewayPlane : ISharedUiGatewayPlane
    {
        private readonly string[] _chunks;

        public FakeGatewayPlane(params string[] chunks) => _chunks = chunks;

        public Task<bool> ProbeAsync(CancellationToken ct) => Task.FromResult(true);

        public async Task StreamChatAsync(
            JsonObject request, System.Func<string, CancellationToken, Task> onChunk, CancellationToken ct)
        {
            foreach (var chunk in _chunks)
            {
                await onChunk(chunk, ct);
            }
        }

        public void CancelChat(string requestId)
        {
        }
    }

    private sealed class FakeSystemPlane : ISharedUiSystemPlane
    {
        public string? OpenedUrl { get; private set; }

        public bool TrayDegraded => false;

        public void OpenDashboard()
        {
        }

        public void Quit()
        {
        }

        public void OpenExternalUrl(string validatedUrl) => OpenedUrl = validatedUrl;

        public void OpenUpdateUrl(string validatedUrl) => OpenedUrl = validatedUrl;

        public string ExportDiagnostics() => "/tmp/bundle.zip";
    }
}

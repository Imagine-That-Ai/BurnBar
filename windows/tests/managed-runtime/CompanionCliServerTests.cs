using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class CompanionCliServerTests
{
    [Fact]
    public void HandleLine_Ping_ReturnsPong()
    {
        string response = CompanionCliServer.HandleLine("{\"op\":\"ping\"}");
        Assert.Contains("\"pong\":true", response.Replace(" ", ""), System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void HandleLine_UnknownOp_FailsClosed()
    {
        string response = CompanionCliServer.HandleLine("{\"op\":\"nope\"}");
        Assert.Contains("unknown_op", response, System.StringComparison.Ordinal);
    }

    [Fact]
    public async Task Server_AcceptsClientAndAnswersVersion()
    {
        int port = 19000 + System.Environment.ProcessId % 500;
        await using var server = new CompanionCliServer(port);
        server.Start();

        using var client = new TcpClient();
        await client.ConnectAsync(System.Net.IPAddress.Loopback, port);
        await using NetworkStream stream = client.GetStream();
        using var writer = new StreamWriter(stream, Encoding.UTF8) { AutoFlush = true };
        using var reader = new StreamReader(stream, Encoding.UTF8);
        await writer.WriteLineAsync("{\"op\":\"version\"}");
        string? line = await reader.ReadLineAsync();
        Assert.NotNull(line);
        Assert.Contains("f2-companion-cli-1", line, System.StringComparison.Ordinal);
    }

    [Fact]
    public async Task Server_ExecutesHeadlessRunOverAuthenticatedLoopback()
    {
        string path = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            "obb-cli-live-run-" + System.IO.Path.GetRandomFileName());
        try
        {
            var runs = new HeadlessRunService(new JsonLinesHeadlessRunJournal(path));
            var runHandler = new CompanionCliHeadlessRunHandler(
                runs,
                BuiltInHeadlessRunSteps.ExecuteAsync);
            var router = new CompanionCliCommandRouter(
                submit: runHandler.SubmitAsync,
                resume: runHandler.ResumeAsync,
                recover: runHandler.RecoverAsync);
            await using var server = new CompanionCliServer(0, router, "integration-token");
            server.Start();

            using var client = new TcpClient();
            await client.ConnectAsync(System.Net.IPAddress.Loopback, server.Port);
            await using NetworkStream stream = client.GetStream();
            using var writer = new StreamWriter(stream, Encoding.UTF8) { AutoFlush = true };
            using var reader = new StreamReader(stream, Encoding.UTF8);
            await writer.WriteLineAsync(
                "{\"op\":\"run.submit\",\"authToken\":\"integration-token\",\"runId\":\"tcp-run\",\"steps\":[{\"id\":\"health\",\"kind\":\"health\"}]}");

            string? line = await reader.ReadLineAsync();
            Assert.NotNull(line);
            Assert.Contains("Succeeded", line, System.StringComparison.Ordinal);
            Assert.DoesNotContain("integration-token", line, System.StringComparison.Ordinal);
        }
        finally
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    [Fact]
    public async Task CommandRouter_HandlesHealthModelsAndRunSubmit()
    {
        var router = new CompanionCliCommandRouter(
            new ModelProxyRouter(new[] { new ModelRoute("r1", "openai", "gpt-test", 1, true) }),
            (request, _) => Task.FromResult<object?>(new { accepted = request.GetProperty("runId").GetString() }));

        string health = await router.HandleAsync("{\"op\":\"health\"}", CancellationToken.None);
        Assert.Contains("\"status\":\"ready\"", health, System.StringComparison.Ordinal);
        string models = await router.HandleAsync("{\"op\":\"models\"}", CancellationToken.None);
        Assert.Contains("gpt-test", models, System.StringComparison.Ordinal);
        string submit = await router.HandleAsync("{\"op\":\"run.submit\",\"runId\":\"r-1\"}", CancellationToken.None);
        Assert.Contains("r-1", submit, System.StringComparison.Ordinal);
    }

    [Fact]
    public async Task HandleLineAsync_RejectsOversizedRequest()
    {
        string line = "{\"op\":\"ping\",\"payload\":\"" + new string('x', CompanionCliServer.MaxLineBytes) + "\"}";
        string response = await CompanionCliServer.HandleLineAsync(line, null);
        Assert.Contains("request_too_large", response, System.StringComparison.Ordinal);
    }

    [Fact]
    public async Task HandleLineAsync_RequiresConfiguredAccessToken()
    {
        var handler = new RecordingCliHandler();
        byte[] token = Encoding.UTF8.GetBytes("cli-secret");

        string missing = await CompanionCliServer.HandleLineAsync(
            "{\"op\":\"ping\"}",
            handler,
            CancellationToken.None,
            token);
        Assert.Contains("unauthorized", missing, System.StringComparison.Ordinal);
        Assert.Equal(0, handler.Calls);

        string wrong = await CompanionCliServer.HandleLineAsync(
            "{\"op\":\"ping\",\"authToken\":\"wrong\"}",
            handler,
            CancellationToken.None,
            token);
        Assert.Contains("unauthorized", wrong, System.StringComparison.Ordinal);
        Assert.Equal(0, handler.Calls);

        string accepted = await CompanionCliServer.HandleLineAsync(
            "{\"op\":\"ping\",\"authToken\":\"cli-secret\"}",
            handler,
            CancellationToken.None,
            token);
        Assert.Contains("handled", accepted, System.StringComparison.Ordinal);
        Assert.Equal(1, handler.Calls);
        Assert.DoesNotContain("authToken", handler.LastLine, System.StringComparison.Ordinal);
    }

    private sealed class RecordingCliHandler : ICompanionCliCommandHandler
    {
        public int Calls { get; private set; }

        public string LastLine { get; private set; } = string.Empty;

        public Task<string> HandleAsync(string line, CancellationToken cancellationToken)
        {
            Calls++;
            LastLine = line;
            return Task.FromResult("{\"handled\":true}");
        }
    }

    [Fact]
    public async Task HeadlessRunHandler_SubmitsSafeNoopAndRejectsUnknownKind()
    {
        string path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "obb-cli-run-" + System.IO.Path.GetRandomFileName());
        try
        {
            var runs = new HeadlessRunService(new JsonLinesHeadlessRunJournal(path));
            var handler = new CompanionCliHeadlessRunHandler(runs, BuiltInHeadlessRunSteps.ExecuteAsync);
            var router = new CompanionCliCommandRouter(
                submit: handler.SubmitAsync,
                resume: handler.ResumeAsync,
                recover: handler.RecoverAsync);

            string success = await router.HandleAsync(
                "{\"op\":\"run.submit\",\"runId\":\"safe-1\",\"steps\":[{\"id\":\"a\",\"kind\":\"noop\"}]}",
                CancellationToken.None);
            Assert.Contains("Succeeded", success, System.StringComparison.Ordinal);

            string failed = await router.HandleAsync(
                "{\"op\":\"run.submit\",\"runId\":\"safe-2\",\"steps\":[{\"id\":\"a\",\"kind\":\"shell\"}]}",
                CancellationToken.None);
            Assert.Contains("step_kind_unavailable", failed, System.StringComparison.Ordinal);

            await new JsonLinesHeadlessRunJournal(path).AppendAsync(
                new HeadlessRunJournalEntry(
                    "interrupted",
                    HeadlessRunState.Running,
                    null,
                    null,
                    DateTimeOffset.UtcNow));

            string recoverable = await router.HandleAsync(
                "{\"op\":\"run.recover\"}",
                CancellationToken.None);
            Assert.Contains("result", recoverable, System.StringComparison.Ordinal);
            Assert.Contains("interrupted", recoverable, System.StringComparison.Ordinal);
        }
        finally
        {
            if (System.IO.File.Exists(path))
            {
                System.IO.File.Delete(path);
            }
        }
    }

    [Fact]
    public async Task CommandRouter_ExposesBoundedFusionHook()
    {
        var router = new CompanionCliCommandRouter(
            fusion: (request, _) => Task.FromResult<object?>(new
            {
                runId = request.GetProperty("runId").GetString(),
                accepted = true,
            }));

        string response = await router.HandleAsync(
            "{\"op\":\"fusion.run\",\"runId\":\"fusion-1\"}",
            CancellationToken.None);

        Assert.Contains("fusion-1", response, System.StringComparison.Ordinal);
        Assert.Contains("accepted", response, System.StringComparison.Ordinal);
    }

    [Fact]
    public async Task CommandRouter_ExposesCodeMemoryHook()
    {
        var router = new CompanionCliCommandRouter(
            code: (request, _) => Task.FromResult<object?>(new
            {
                op = request.GetProperty("op").GetString(),
                ready = true,
            }));

        string response = await router.HandleAsync(
            "{\"op\":\"code.status\"}",
            CancellationToken.None);

        Assert.Contains("code.status", response, System.StringComparison.Ordinal);
        Assert.Contains("ready", response, System.StringComparison.Ordinal);

        string context = await router.HandleAsync(
            "{\"op\":\"code.context_pack\",\"query\":\"Widget\"}",
            CancellationToken.None);
        Assert.Contains("code.context_pack", context, System.StringComparison.Ordinal);

        string graph = await router.HandleAsync(
            "{\"op\":\"code.call_graph\",\"name\":\"Invoke\"}",
            CancellationToken.None);
        Assert.Contains("code.call_graph", graph, System.StringComparison.Ordinal);

        string semantic = await router.HandleAsync(
            "{\"op\":\"code.semantic_search\",\"query\":\"Widget\"}",
            CancellationToken.None);
        Assert.Contains("code.semantic_search", semantic, System.StringComparison.Ordinal);
    }
}

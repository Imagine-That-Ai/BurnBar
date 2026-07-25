using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;
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
            string? line = await ExchangeAuthenticatedAsync(
                writer,
                reader,
                "{\"op\":\"run.submit\",\"runId\":\"tcp-run\",\"steps\":[{\"id\":\"health\",\"kind\":\"health\"}]}",
                "integration-token");
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
    public async Task Server_DrivesDurableAgentApprovalAndToolLifecycleOverAuthenticatedLoopback()
    {
        string path = Path.Combine(Path.GetTempPath(), "obb-cli-agent-" + Path.GetRandomFileName());
        try
        {
            int completionCalls = 0;
            var modelRouter = new ModelProxyRouter(new[]
            {
                new ModelRoute(
                    "agent-route",
                    "test",
                    "test-model",
                    0,
                    true,
                    new Uri("https://agent-route.test/v1/chat/completions")),
            });
            var executor = new DelegateModelCompletionExecutor((_, _, _) =>
            {
                string decision = Interlocked.Increment(ref completionCalls) == 1
                    ? "{\"action\":\"apply_patch\",\"rationale\":\"Edit\",\"arguments\":{\"changes\":[{\"path\":\"a.txt\",\"content\":\"new\"}]}}"
                    : "{\"action\":\"complete\",\"rationale\":\"Done\"}";
                byte[] body = JsonSerializer.SerializeToUtf8Bytes(new
                {
                    choices = new[] { new { message = new { content = decision } } },
                });
                return Task.FromResult(new ModelCompletionResult(200, body, "application/json", true));
            });
            await using var agentService = new HeadlessAgentRunService(
                modelRouter,
                executor,
                new JsonLinesHeadlessRunJournal(path),
                new InMemoryHeadlessAgentCheckpointStore());
            await agentService.StartAsync();
            var agentHandler = new CompanionCliAgentRunHandler(agentService);
            var dagHandler = new CompanionCliHeadlessRunHandler(
                new HeadlessRunService(new JsonLinesHeadlessRunJournal(path + ".dag")),
                BuiltInHeadlessRunSteps.ExecuteAsync,
                agentHandler);
            var commandRouter = new CompanionCliCommandRouter(
                modelRouter,
                submit: dagHandler.SubmitAsync,
                resume: dagHandler.ResumeAsync,
                recover: dagHandler.RecoverAsync,
                agentRuns: agentHandler);
            await using var server = new CompanionCliServer(0, commandRouter, "agent-token");
            server.Start();

            using var client = new TcpClient();
            await client.ConnectAsync(System.Net.IPAddress.Loopback, server.Port);
            await using NetworkStream stream = client.GetStream();
            using var writer = new StreamWriter(stream, Encoding.UTF8) { AutoFlush = true };
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var authenticated = false;

            async Task<JsonElement> ExchangeAsync(object request)
            {
                string serialized = JsonSerializer.Serialize(request);
                string line;
                if (!authenticated)
                {
                    line = await ExchangeAuthenticatedAsync(writer, reader, serialized, "agent-token");
                    authenticated = true;
                }
                else
                {
                    await writer.WriteLineAsync(serialized);
                    line = Assert.IsType<string>(await reader.ReadLineAsync());
                }
                Assert.DoesNotContain("agent-token", line, StringComparison.Ordinal);
                using JsonDocument document = JsonDocument.Parse(line);
                Assert.True(document.RootElement.GetProperty("ok").GetBoolean(), line);
                return document.RootElement.GetProperty("result").Clone();
            }

            await ExchangeAsync(new
            {
                op = "run.submit",
                runId = "agent-tcp",
                clientId = "companion",
                sessionId = "desktop-session",
                prompt = "edit the file",
                modelId = "test-model",
                metadata = new
                {
                    agentIntent = new
                    {
                        kind = "generic",
                        objective = "edit",
                        summary = "Edit the requested file.",
                    },
                },
            });

            JsonElement detail = default;
            for (int attempt = 0; attempt < 100; attempt++)
            {
                detail = await ExchangeAsync(new
                {
                    op = "run.get",
                    runId = "agent-tcp",
                    clientId = "companion",
                });
                if (detail.GetProperty("run").GetProperty("phase").GetString() == "awaiting_approval") break;
                await Task.Delay(20);
            }
            Assert.Equal("awaiting_approval", detail.GetProperty("run").GetProperty("phase").GetString());
            string approvalId = Assert.IsType<string>(detail.GetProperty("approvalRequest").GetProperty("approvalId").GetString());

            await ExchangeAsync(new
            {
                op = "approval.respond",
                runId = "agent-tcp",
                clientId = "companion",
                approvalId,
                decision = "approve",
            });
            JsonElement claim = await ExchangeAsync(new
            {
                op = "workspace.executeTool",
                runId = "agent-tcp",
                clientId = "companion",
                sessionId = "desktop-session",
            });
            Assert.Equal("dispatched", claim.GetProperty("disposition").GetString());
            string callId = Assert.IsType<string>(claim.GetProperty("toolCall").GetProperty("callId").GetString());

            await ExchangeAsync(new
            {
                op = "workspace.toolResult",
                runId = "agent-tcp",
                clientId = "companion",
                sessionId = "desktop-session",
                callId,
                succeeded = true,
                output = new { changed = true },
            });
            for (int attempt = 0; attempt < 100; attempt++)
            {
                detail = await ExchangeAsync(new
                {
                    op = "run.get",
                    runId = "agent-tcp",
                    clientId = "companion",
                });
                if (detail.GetProperty("run").GetProperty("phase").GetString() == "completed") break;
                await Task.Delay(20);
            }
            Assert.Equal("completed", detail.GetProperty("run").GetProperty("phase").GetString());
            Assert.Equal(2, completionCalls);
        }
        finally
        {
            File.Delete(path);
            File.Delete(path + ".dag");
        }
    }

    [Fact]
    public async Task Server_ExecutesLocalMissionDagOverAuthenticatedLoopback()
    {
        string path = Path.Combine(Path.GetTempPath(), "obb-cli-live-mission-" + Path.GetRandomFileName());
        try
        {
            var runs = new HeadlessRunService(new JsonLinesHeadlessRunJournal(path));
            var missionHandler = new CompanionCliMissionHandler(
                new LocalMissionDagExecutor(
                    runs,
                    rateLimiter: new MissionRateLimiter(60, TimeSpan.FromMinutes(1))));
            var router = new CompanionCliCommandRouter(
                missionSubmit: missionHandler.SubmitAsync,
                missionResume: missionHandler.ResumeAsync);
            await using var server = new CompanionCliServer(0, router, "mission-token");
            server.Start();

            using var client = new TcpClient();
            await client.ConnectAsync(System.Net.IPAddress.Loopback, server.Port);
            await using NetworkStream stream = client.GetStream();
            using var writer = new StreamWriter(stream, Encoding.UTF8) { AutoFlush = true };
            using var reader = new StreamReader(stream, Encoding.UTF8);
            string? line = await ExchangeAuthenticatedAsync(
                writer,
                reader,
                "{\"op\":\"mission.submit\",\"missionId\":\"mission-tcp\",\"nodes\":[{\"id\":\"ready\",\"kind\":\"health\"},{\"id\":\"done\",\"kind\":\"noop\",\"dependsOn\":[\"ready\"]}]}",
                "mission-token");
            Assert.NotNull(line);
            Assert.Contains("mission-tcp", line, StringComparison.Ordinal);
            Assert.Contains("Succeeded", line, StringComparison.Ordinal);
            Assert.DoesNotContain("mission-token", line, StringComparison.Ordinal);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static async Task<string> ExchangeAuthenticatedAsync(
        StreamWriter writer,
        StreamReader reader,
        string request,
        string token)
    {
        byte[] key = Encoding.UTF8.GetBytes(token);
        try
        {
            string clientNonce = Convert.ToBase64String(
                System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
            await writer.WriteLineAsync(JsonSerializer.Serialize(new
            {
                op = "auth.challenge.v1",
                clientNonce,
            }));
            string challengeLine = Assert.IsType<string>(await reader.ReadLineAsync());
            using JsonDocument challenge = JsonDocument.Parse(challengeLine);
            string serverNonce = Assert.IsType<string>(
                challenge.RootElement.GetProperty("serverNonce").GetString());
            string serverProof = Assert.IsType<string>(
                challenge.RootElement.GetProperty("serverProof").GetString());
            Assert.True(CompanionCliAuthentication.VerifyServerProof(
                serverProof,
                clientNonce,
                serverNonce,
                key));

            JsonObject root = Assert.IsType<JsonObject>(JsonNode.Parse(request));
            root["authProof"] = new JsonObject
            {
                ["clientNonce"] = clientNonce,
                ["serverNonce"] = serverNonce,
                ["proof"] = CompanionCliAuthentication.CreateClientProof(
                    root,
                    clientNonce,
                    serverNonce,
                    key),
            };
            await writer.WriteLineAsync(root.ToJsonString());
            return Assert.IsType<string>(await reader.ReadLineAsync());
        }
        finally
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(key);
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
    public async Task Server_DiscardsOversizedLineAndKeepsConnectionUsable()
    {
        await using var server = new CompanionCliServer(0);
        server.Start();
        using var client = new TcpClient();
        await client.ConnectAsync(System.Net.IPAddress.Loopback, server.Port);
        await using NetworkStream stream = client.GetStream();
        using var writer = new StreamWriter(stream, Encoding.UTF8) { AutoFlush = true };
        using var reader = new StreamReader(stream, Encoding.UTF8);

        await writer.WriteLineAsync(new string('x', CompanionCliServer.MaxLineBytes + 1));
        string oversized = Assert.IsType<string>(await reader.ReadLineAsync());
        Assert.Contains("request_too_large", oversized, StringComparison.Ordinal);
        await writer.WriteLineAsync("{\"op\":\"ping\"}");
        string ping = Assert.IsType<string>(await reader.ReadLineAsync());
        Assert.Contains("pong", ping, StringComparison.Ordinal);
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

    [Theory]
    [InlineData("connector.get")]
    [InlineData("connector.update")]
    [InlineData("connector.action")]
    [InlineData("workspace.bridge.enqueue")]
    [InlineData("workspace.bridge.claim")]
    [InlineData("workspace.bridge.result")]
    [InlineData("context.next")]
    [InlineData("context.snapshot")]
    public async Task CommandRouter_ExposesAuthenticatedToolingHook(string operation)
    {
        var router = new CompanionCliCommandRouter(
            tooling: (request, _) => Task.FromResult<object?>(new
            {
                operation = request.GetProperty("op").GetString(),
                accepted = true,
            }));

        string response = await router.HandleAsync(
            JsonSerializer.Serialize(new { op = operation }),
            CancellationToken.None);

        Assert.Contains(operation, response, StringComparison.Ordinal);
        Assert.Contains("accepted", response, StringComparison.Ordinal);
    }
}

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
    public async Task HeadlessRunHandler_SubmitsSafeNoopAndRejectsUnknownKind()
    {
        string path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "obb-cli-run-" + System.IO.Path.GetRandomFileName());
        try
        {
            var runs = new HeadlessRunService(new JsonLinesHeadlessRunJournal(path));
            var handler = new CompanionCliHeadlessRunHandler(runs, BuiltInHeadlessRunSteps.ExecuteAsync);
            var router = new CompanionCliCommandRouter(
                submit: handler.SubmitAsync,
                resume: handler.ResumeAsync);

            string success = await router.HandleAsync(
                "{\"op\":\"run.submit\",\"runId\":\"safe-1\",\"steps\":[{\"id\":\"a\",\"kind\":\"noop\"}]}",
                CancellationToken.None);
            Assert.Contains("Succeeded", success, System.StringComparison.Ordinal);

            string failed = await router.HandleAsync(
                "{\"op\":\"run.submit\",\"runId\":\"safe-2\",\"steps\":[{\"id\":\"a\",\"kind\":\"shell\"}]}",
                CancellationToken.None);
            Assert.Contains("step_kind_unavailable", failed, System.StringComparison.Ordinal);
        }
        finally
        {
            if (System.IO.File.Exists(path))
            {
                System.IO.File.Delete(path);
            }
        }
    }
}

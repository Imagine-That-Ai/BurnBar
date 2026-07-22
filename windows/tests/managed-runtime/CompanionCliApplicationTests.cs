using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.Cli;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class CompanionCliApplicationTests
{
    [Fact]
    public async Task Health_UsesProtectedAuthenticatedDefaults()
    {
        var client = new RecordingClient("{\"ok\":true,\"status\":\"ready\"}");
        CompanionCliClientOptions? options = null;
        var application = new CompanionCliApplication(value =>
        {
            options = value;
            return client;
        });
        var output = new StringWriter();
        var error = new StringWriter();

        int exitCode = await application.RunAsync(
            new[] { "health" },
            new StringReader(string.Empty),
            output,
            error);

        Assert.Equal(0, exitCode);
        Assert.Equal("health", client.Request.GetProperty("op").GetString());
        Assert.NotNull(options);
        Assert.Equal(8765, options.Port);
        Assert.True(options.RequireAuthentication);
        Assert.Contains("ready", output.ToString(), StringComparison.Ordinal);
        Assert.Equal(string.Empty, error.ToString());
    }

    [Fact]
    public async Task RunSubmit_ReadsBoundedPayloadFromStandardInput()
    {
        var client = new RecordingClient("{\"ok\":true,\"result\":{\"accepted\":true}}");
        var application = new CompanionCliApplication(_ => client);
        var output = new StringWriter();

        int exitCode = await application.RunAsync(
            new[] { "run-submit", "--input", "-", "--port", "9012", "--timeout-seconds", "30", "--compact" },
            new StringReader("{\"runId\":\"run-1\",\"prompt\":\"inspect\"}"),
            output,
            new StringWriter());

        Assert.Equal(0, exitCode);
        Assert.Equal("run.submit", client.Request.GetProperty("op").GetString());
        Assert.Equal("run-1", client.Request.GetProperty("runId").GetString());
        Assert.DoesNotContain("authToken", client.Request.GetRawText(), StringComparison.Ordinal);
        Assert.DoesNotContain(Environment.NewLine + "  ", output.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Call_AllowsFutureProtocolOperationWithoutClientRelease()
    {
        var client = new RecordingClient("{\"ok\":true}");
        var application = new CompanionCliApplication(_ => client);

        int exitCode = await application.RunAsync(
            new[] { "call", "future.operation", "--no-auth" },
            new StringReader(string.Empty),
            new StringWriter(),
            new StringWriter());

        Assert.Equal(0, exitCode);
        Assert.Equal("future.operation", client.Request.GetProperty("op").GetString());
    }

    [Fact]
    public async Task ServerFailure_ReturnsStableNonzeroExitCodeAndJson()
    {
        var client = new RecordingClient("{\"ok\":false,\"error\":\"run_unavailable\"}");
        var application = new CompanionCliApplication(_ => client);
        var output = new StringWriter();

        int exitCode = await application.RunAsync(
            new[] { "run-get" },
            new StringReader(string.Empty),
            output,
            new StringWriter());

        Assert.Equal(2, exitCode);
        Assert.Contains("run_unavailable", output.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task InlineAuthentication_IsRejectedWithoutTransport()
    {
        var application = new CompanionCliApplication(_ =>
            throw new InvalidOperationException("transport must not be created"));
        var error = new StringWriter();

        int exitCode = await application.RunAsync(
            new[] { "health", "--input", "-" },
            new StringReader("{\"authToken\":\"do-not-log\"}"),
            new StringWriter(),
            error);

        Assert.Equal(64, exitCode);
        Assert.Contains("must not contain", error.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("do-not-log", error.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task NonObjectInput_IsRejectedWithoutTransport()
    {
        var application = new CompanionCliApplication(_ =>
            throw new InvalidOperationException("transport must not be created"));
        var error = new StringWriter();

        int exitCode = await application.RunAsync(
            new[] { "health", "--input", "-" },
            new StringReader("[\"not\",\"an\",\"object\"]"),
            new StringWriter(),
            error);

        Assert.Equal(64, exitCode);
        Assert.Contains("Input must be a JSON object", error.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Help_DoesNotConstructTransport()
    {
        var application = new CompanionCliApplication(_ =>
            throw new InvalidOperationException("transport must not be created"));
        var output = new StringWriter();

        int exitCode = await application.RunAsync(
            new[] { "--help" },
            new StringReader(string.Empty),
            output,
            new StringWriter());

        Assert.Equal(0, exitCode);
        Assert.Contains("OpenBurnBar companion CLI", output.ToString(), StringComparison.Ordinal);
        Assert.Contains("DPAPI-protected", output.ToString(), StringComparison.Ordinal);
    }

    private sealed class RecordingClient : ICompanionCliClient
    {
        private readonly JsonElement _response;

        public RecordingClient(string response)
        {
            using JsonDocument document = JsonDocument.Parse(response);
            _response = document.RootElement.Clone();
        }

        public JsonElement Request { get; private set; }

        public Task<JsonElement> ExchangeAsync(JsonElement request, CancellationToken cancellationToken = default)
        {
            Request = request.Clone();
            return Task.FromResult(_response);
        }
    }
}

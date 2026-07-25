using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class ProviderCliModelCompletionExecutorTests
{
    [Theory]
    [InlineData("factory", "cli://factory")]
    [InlineData("factory-droid", "cli://factory")]
    public void MatchingCliEndpointIsExecutable(string vendor, string endpoint)
    {
        ModelRoute route = Configuration(vendor, endpoint).Resolve("credential");

        Assert.True(route.IsExecutable);
        Assert.True(ProviderCliModelCompletionExecutor.IsCliRoute(route));
    }

    [Theory]
    [InlineData("codex", "cli://factory")]
    [InlineData("codex", "cli://codex")]
    [InlineData("factory", "cli://codex")]
    [InlineData("codex", "cli://codex/path")]
    [InlineData("codex", "cli://codex?mode=unsafe")]
    [InlineData("openai", "cli://codex")]
    public void MismatchedOrDecoratedCliEndpointIsRejected(string vendor, string endpoint)
    {
        Assert.Throws<ArgumentException>(() => Configuration(vendor, endpoint).Validate());
    }

    [Fact]
    public async Task CompositeDispatchesByEndpointRatherThanVendorNameAlone()
    {
        var http = new RecordingExecutor(201);
        var cli = new RecordingExecutor(202);
        var composite = new CompositeModelCompletionExecutor(http, cli);
        ModelRoute httpCodex = new(
            "codex-http", "codex", "gpt-5", 0, true,
            new Uri("https://provider.example/v1/chat/completions"));
        ModelRoute cliFactory = CliRoute("factory", "claude-sonnet", "cli://factory");

        Assert.Equal(201, (await composite.ExecuteAsync(httpCodex, Body())).StatusCode);
        Assert.Equal(202, (await composite.ExecuteAsync(cliFactory, Body())).StatusCode);
        Assert.Single(http.Routes);
        Assert.Single(cli.Routes);
    }

    [Fact]
    public async Task CodexCliRouteIsRejectedBeforeProcessLaunch()
    {
        var runner = new DelegateRunner(_ => throw new InvalidOperationException("must not launch"));
        var executor = new ProviderCliModelCompletionExecutor(runner);

        ModelCompletionResult result = await executor.ExecuteAsync(
            CliRoute("codex", "gpt-5", "cli://codex", "secret-key"),
            Body("hello from user", role: ""));

        Assert.Equal(503, result.StatusCode);
        Assert.Equal(0, runner.CallCount);
    }

    [Fact]
    public async Task CodexStreamingCliRouteIsRejected()
    {
        var runner = new DelegateRunner(_ => new ProviderCliProcessResult(
            0,
            "{\"message\":{\"text\":\"streamed answer\"}}\n",
            string.Empty));
        var executor = new ProviderCliModelCompletionExecutor(runner);

        ModelCompletionResult result = await executor.ExecuteAsync(
            CliRoute("codex", "gpt-5", "cli://codex"),
            Body("stream this", stream: true));

        Assert.Equal(503, result.StatusCode);
        Assert.Equal(0, runner.CallCount);
    }

    [Fact]
    public async Task FactoryUsesProtectedEnvironmentDisabledToolsAndEphemeralPromptFile()
    {
        string? prompt = null;
        string? directory = null;
        ProviderCliProcessRequest? captured = null;
        var runner = new DelegateRunner(request =>
        {
            captured = request;
            directory = request.WorkingDirectory;
            int flag = request.Arguments.ToList().IndexOf("-f");
            Assert.True(flag >= 0);
            prompt = File.ReadAllText(request.Arguments[flag + 1]);
            return new ProviderCliProcessResult(
                0,
                "{\"result\":{\"response\":\"factory answer\"}}",
                string.Empty);
        });
        var executor = new ProviderCliModelCompletionExecutor(runner);

        ModelCompletionResult result = await executor.ExecuteAsync(
            CliRoute("factory", "claude-sonnet", "cli://factory", "factory-secret"),
            Body("factory request"));

        Assert.True(result.Succeeded);
        Assert.NotNull(captured);
        Assert.Equal("droid", captured.ExecutableId);
        Assert.Contains("ApplyPatch,execute-cli", captured.Arguments);
        Assert.Equal("factory-secret", captured.RequiredEnvironment["FACTORY_API_KEY"]);
        Assert.Equal("1", captured.RequiredEnvironment["OPENBURNBAR_FACTORY_STRICT_STANDARD"]);
        Assert.Null(captured.StandardInput);
        Assert.Contains("Do not inspect or modify files", prompt, StringComparison.Ordinal);
        Assert.Contains("factory request", prompt, StringComparison.Ordinal);
        Assert.Equal("factory answer", ResponseText(result));
        Assert.NotNull(directory);
        Assert.False(Directory.Exists(directory));
    }

    [Fact]
    public async Task FactoryWithoutCredentialFailsBeforeLaunchAndCleansTemporaryFiles()
    {
        var runner = new DelegateRunner(_ => throw new InvalidOperationException("must not launch"));
        var executor = new ProviderCliModelCompletionExecutor(runner);

        ModelCompletionResult result = await executor.ExecuteAsync(
            CliRoute("factory", "claude-sonnet", "cli://factory"),
            Body());

        Assert.Equal(401, result.StatusCode);
        Assert.Equal(0, runner.CallCount);
        Assert.Equal("factory_api_key_missing", ErrorCode(result));
    }

    [Fact]
    public async Task FactoryStandardModelRejectsDroidCoreDowngrade()
    {
        var runner = new DelegateRunner(_ => new ProviderCliProcessResult(
            0,
            "{\"result\":\"Standard usage is exhausted; using Droid Core\"}",
            string.Empty));
        var executor = new ProviderCliModelCompletionExecutor(runner);

        ModelCompletionResult result = await executor.ExecuteAsync(
            CliRoute("factory", "claude-sonnet", "cli://factory", "factory-secret"),
            Body());

        Assert.Equal(402, result.StatusCode);
        Assert.Equal("factory_standard_usage_exhausted", ErrorCode(result));
    }

    [Fact]
    public async Task FactoryDroidCoreModelMayUseDroidCore()
    {
        var runner = new DelegateRunner(_ => new ProviderCliProcessResult(
            0,
            "{\"result\":\"Droid Core response\"}",
            string.Empty));
        var executor = new ProviderCliModelCompletionExecutor(runner);

        ModelCompletionResult result = await executor.ExecuteAsync(
            CliRoute("factory-droid", "glm-5.1", "cli://factory", "factory-secret"),
            Body());

        Assert.True(result.Succeeded);
        Assert.Equal("Droid Core response", ResponseText(result));
    }

    [Fact]
    public async Task ProviderFailureIsClassifiedWithoutEchoingSensitiveOutput()
    {
        const string sensitive = "quota exhausted token=do-not-return";
        var runner = new DelegateRunner(_ => new ProviderCliProcessResult(17, string.Empty, sensitive));
        var executor = new ProviderCliModelCompletionExecutor(runner);

        ModelCompletionResult result = await executor.ExecuteAsync(
            CliRoute("factory", "claude-sonnet", "cli://factory", "factory-secret"),
            Body());

        Assert.Equal(429, result.StatusCode);
        string body = Encoding.UTF8.GetString(result.Body);
        Assert.Equal("provider_cli_failed", ErrorCode(result));
        Assert.DoesNotContain(sensitive, body, StringComparison.Ordinal);
        Assert.DoesNotContain("do-not-return", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task InvalidCliEndpointFailsClosedBeforeLaunch()
    {
        var runner = new DelegateRunner(_ => throw new InvalidOperationException("must not launch"));
        var executor = new ProviderCliModelCompletionExecutor(runner);
        ModelRoute route = new(
            "bad", "codex", "gpt-5", 0, true,
            new Uri("https://provider.example/v1/chat/completions"));

        ModelCompletionResult result = await executor.ExecuteAsync(route, Body());

        Assert.Equal(503, result.StatusCode);
        Assert.Equal(0, runner.CallCount);
    }

    private static GatewayRouteConfiguration Configuration(string vendor, string endpoint) =>
        new("cli-route", vendor, "model", endpoint, 0, true, GatewayRouteAuthentication.Bearer);

    private static ModelRoute CliRoute(
        string vendor,
        string model,
        string endpoint,
        string? bearerToken = null) =>
        new("cli-route", vendor, model, 0, true, new Uri(endpoint), bearerToken);

    private static byte[] Body(string content = "hello", bool stream = false, string role = "user") =>
        JsonSerializer.SerializeToUtf8Bytes(new
        {
            stream,
            messages = new[] { new { role, content } },
        });

    private static string ResponseText(ModelCompletionResult result) =>
        JsonDocument.Parse(result.Body).RootElement
            .GetProperty("choices")[0]
            .GetProperty("message")
            .GetProperty("content")
            .GetString()!;

    private static string ErrorCode(ModelCompletionResult result) =>
        JsonDocument.Parse(result.Body).RootElement
            .GetProperty("error")
            .GetProperty("code")
            .GetString()!;

    private sealed class DelegateRunner : IProviderCliProcessRunner
    {
        private readonly Func<ProviderCliProcessRequest, ProviderCliProcessResult> _handler;

        public DelegateRunner(Func<ProviderCliProcessRequest, ProviderCliProcessResult> handler) =>
            _handler = handler;

        public int CallCount { get; private set; }

        public Task<ProviderCliProcessResult> RunAsync(
            ProviderCliProcessRequest request,
            CancellationToken cancellationToken = default)
        {
            CallCount++;
            return Task.FromResult(_handler(request));
        }
    }

    private sealed class RecordingExecutor : IModelCompletionExecutor
    {
        private readonly int _statusCode;

        public RecordingExecutor(int statusCode) => _statusCode = statusCode;

        public List<ModelRoute> Routes { get; } = new();

        public Task<ModelCompletionResult> ExecuteAsync(
            ModelRoute route,
            byte[] requestBody,
            CancellationToken cancellationToken = default)
        {
            Routes.Add(route);
            return Task.FromResult(new ModelCompletionResult(
                _statusCode,
                Array.Empty<byte>(),
                "application/json",
                Succeeded: true));
        }
    }
}

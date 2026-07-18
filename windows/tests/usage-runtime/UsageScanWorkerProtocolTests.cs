using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.UsageRuntime;
using Xunit;

namespace OpenBurnBar.App.UsageRuntime.Tests;

public sealed class UsageScanWorkerProtocolTests
{
    [Fact]
    public async Task Protocol_RoundTripsRequestAndResponseWithoutLineLimits()
    {
        UsageEngineScanRequest request = Request();
        await using var requestStream = new MemoryStream();
        await UsageScanWorkerProtocol.WriteRequestAsync(requestStream, request);
        requestStream.Position = 0;

        UsageEngineScanRequest decodedRequest = await UsageScanWorkerProtocol
            .ReadRequestAsync(requestStream);
        Assert.Equal(request.SupportDirectory, decodedRequest.SupportDirectory);
        Assert.Equal(request.IncludeConversationBodies, decodedRequest.IncludeConversationBodies);

        var response = new UsageEngineScanResponse
        {
            Ok = true,
            Providers = new[]
            {
                new UsageProviderScanResult
                {
                    Provider = "Codex",
                    Status = UsageProviderScanStatus.Succeeded,
                    UsageCount = 1,
                },
            },
        };
        await using var responseStream = new MemoryStream();
        await UsageScanWorkerProtocol.WriteResponseAsync(responseStream, response);
        responseStream.Position = 0;

        UsageEngineScanResponse decodedResponse = await UsageScanWorkerProtocol
            .ReadResponseAsync(responseStream);
        Assert.True(decodedResponse.Ok);
        Assert.Equal(UsageProviderScanStatus.Succeeded, decodedResponse.Providers.Single().Status);
    }

    [Fact]
    public async Task WorkerHost_ExecutesExactlyOneScanAndWritesResponse()
    {
        await using var input = new MemoryStream();
        await UsageScanWorkerProtocol.WriteRequestAsync(input, Request());
        input.Position = 0;
        await using var output = new MemoryStream();
        using var error = new StringWriter();
        var engine = new RecordingEngine(new UsageEngineScanResponse { Ok = true });

        int exitCode = await UsageScanWorkerHost.RunAsync(engine, input, output, error);

        Assert.Equal(0, exitCode);
        Assert.Equal(1, engine.ScanCount);
        Assert.Equal(string.Empty, error.ToString());
        output.Position = 0;
        Assert.True((await UsageScanWorkerProtocol.ReadResponseAsync(output)).Ok);
    }

    [Fact]
    public async Task WorkerHost_FailsClosedWithoutWritingSuccessJson()
    {
        await using var input = new MemoryStream();
        await UsageScanWorkerProtocol.WriteRequestAsync(input, Request());
        input.Position = 0;
        await using var output = new MemoryStream();
        using var error = new StringWriter();
        var engine = new ThrowingEngine();

        int exitCode = await UsageScanWorkerHost.RunAsync(engine, input, output, error);

        Assert.Equal(1, exitCode);
        Assert.Equal(0, output.Length);
        Assert.Contains("usage_scan_worker_failed", error.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void CreateStartInfo_UsesHardenedRedirectedWorkerProfile()
    {
        string workerPath = Path.GetFullPath(Path.Combine("fixture", "OpenBurnBar.Cli.exe"));
        ProcessStartInfo startInfo = OutOfProcessUsageEngine.CreateStartInfo(workerPath);

        Assert.Equal(workerPath, startInfo.FileName);
        Assert.Equal(new[] { UsageScanWorkerProtocol.WorkerArgument }, startInfo.ArgumentList);
        Assert.False(startInfo.UseShellExecute);
        Assert.True(startInfo.CreateNoWindow);
        Assert.True(startInfo.RedirectStandardInput);
        Assert.True(startInfo.RedirectStandardOutput);
        Assert.True(startInfo.RedirectStandardError);
        Assert.DoesNotContain(startInfo.Environment.Keys, ChildProcessEnvironment.IsForbidden);
    }

    [Fact]
    public async Task MissingWorker_IsTypedUnavailableFailure()
    {
        var engine = new OutOfProcessUsageEngine(() => Path.Combine("missing", "worker.exe"));

        UsageRuntimeException exception = await Assert.ThrowsAsync<UsageRuntimeException>(
            async () => await engine.ScanAsync(Request()));

        Assert.Equal(UsageRuntimeFailureKind.NativeEngineUnavailable, exception.Kind);
    }

    private static UsageEngineScanRequest Request() => new()
    {
        SupportDirectory = "support",
        HomeDirectory = "home",
        ClaudeProjectsDirectory = "claude",
        CodexHomeDirectory = "codex",
        CursorSessionsDirectory = "cursor",
        FactorySessionsDirectory = "factory",
        HermesHomeDirectory = "hermes",
        IncludeConversationBodies = false,
    };

    private sealed class RecordingEngine(UsageEngineScanResponse response) : IUsageEngine
    {
        public int ScanCount { get; private set; }

        public ValueTask<UsageEngineScanResponse> ScanAsync(
            UsageEngineScanRequest request,
            CancellationToken cancellationToken = default)
        {
            ScanCount++;
            return ValueTask.FromResult(response);
        }
    }

    private sealed class ThrowingEngine : IUsageEngine
    {
        public ValueTask<UsageEngineScanResponse> ScanAsync(
            UsageEngineScanRequest request,
            CancellationToken cancellationToken = default) =>
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.NativeEngineFailure,
                "fixture failure");
    }
}

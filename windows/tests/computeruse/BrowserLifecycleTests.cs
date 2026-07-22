using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Browser;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class BrowserLifecycleTests
{
    [Fact]
    public async Task RunSession_InProcessDriver_NavigatesAndEvaluates()
    {
        var life = new BrowserComputerUseLifecycle(new InProcessBrowserDriver());
        BrowserSessionResult result = await life.RunSessionAsync(
            new BrowserSessionRequest("https://example.com", new[] { "document.title" }));
        Assert.True(result.Succeeded);
        Assert.NotNull(result.SessionId);
        Assert.Single(result.Evaluations);
        Assert.StartsWith("ok:", result.Evaluations[0].Value);
    }

    [Fact]
    public async Task RunSession_EmptyUrl_FailsClosed()
    {
        var life = new BrowserComputerUseLifecycle(new InProcessBrowserDriver());
        BrowserSessionResult result = await life.RunSessionAsync(new BrowserSessionRequest(""));
        Assert.False(result.Succeeded);
        Assert.Equal("start_url_required", result.Error);
    }

    [Fact]
    public async Task RunSession_RejectsOversizedInputsBeforeLaunch()
    {
        var life = new BrowserComputerUseLifecycle(new InProcessBrowserDriver());

        BrowserSessionResult url = await life.RunSessionAsync(
            new BrowserSessionRequest(new string('x', BrowserComputerUseLifecycle.MaxUrlCharacters + 1)));
        BrowserSessionResult count = await life.RunSessionAsync(
            new BrowserSessionRequest(
                "https://example.com",
                Enumerable.Repeat("document.title", BrowserComputerUseLifecycle.MaxScripts + 1).ToArray()));
        BrowserSessionResult bytes = await life.RunSessionAsync(
            new BrowserSessionRequest(
                "https://example.com",
                new[] { new string('x', BrowserComputerUseLifecycle.MaxScriptCharacters + 1) }));

        Assert.Equal("start_url_too_large", url.Error);
        Assert.Equal("scripts_too_many", count.Error);
        Assert.Equal("scripts_too_large", bytes.Error);
    }

    [Fact]
    public void ProcessDriver_StartInfoRedirectsJsonLineProtocolStreams()
    {
        ProcessStartInfo startInfo = ProcessBrowserDriver.CreateStartInfo(
            "browser-bridge",
            "[\"--stdio\",\"jsonl\"]");

        Assert.False(startInfo.UseShellExecute);
        Assert.True(startInfo.RedirectStandardInput);
        Assert.True(startInfo.RedirectStandardOutput);
        Assert.True(startInfo.RedirectStandardError);
        Assert.Equal(new[] { "--stdio", "jsonl" }, startInfo.ArgumentList.ToArray());
    }

    [Fact]
    public void LaunchOptions_RejectOversizedArgumentsAndMalformedJson()
    {
        Assert.Throws<InvalidOperationException>(() => new BrowserProcessLaunchOptions(
            "browser-bridge",
            Enumerable.Repeat("arg", BrowserProcessLaunchOptions.MaxArguments + 1).ToArray()));
        Assert.Throws<InvalidOperationException>(() => ProcessBrowserDriver.CreateStartInfo(
            "browser-bridge",
            "not-json"));
    }

    [PlaywrightIntegrationFact]
    public async Task ProcessDriver_LivePlaywrightBridge_NavigatesEvaluatesAndCloses()
    {
        string node = Environment.GetEnvironmentVariable("OPENBURNBAR_BROWSER_CU_INTEGRATION_NODE")!;
        string bridge = Environment.GetEnvironmentVariable("OPENBURNBAR_BROWSER_CU_INTEGRATION_BRIDGE")!;
        string nodePath = Environment.GetEnvironmentVariable("OPENBURNBAR_BROWSER_CU_INTEGRATION_NODE_PATH")!;
        string browsersPath = Environment.GetEnvironmentVariable("OPENBURNBAR_BROWSER_CU_INTEGRATION_BROWSERS_PATH")!;
        var options = new BrowserProcessLaunchOptions(
            node,
            new[] { bridge, "--headless" },
            new Dictionary<string, string?>
            {
                ["NODE_PATH"] = nodePath,
                ["PLAYWRIGHT_BROWSERS_PATH"] = browsersPath,
            });
        var lifecycle = new BrowserComputerUseLifecycle(new ProcessBrowserDriver(options));
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));

        BrowserSessionResult result = await lifecycle.RunSessionAsync(
            new BrowserSessionRequest(
                "data:text/html,<title>OpenBurnBar browser parity</title>",
                new[] { "document.title" }),
            timeout.Token);

        Assert.True(result.Succeeded, result.Error);
        Assert.Single(result.Evaluations);
        Assert.Equal("OpenBurnBar browser parity", result.Evaluations[0].Value);
    }

    private sealed class PlaywrightIntegrationFactAttribute : FactAttribute
    {
        private static readonly string[] RequiredEnvironment =
        {
            "OPENBURNBAR_BROWSER_CU_INTEGRATION_NODE",
            "OPENBURNBAR_BROWSER_CU_INTEGRATION_BRIDGE",
            "OPENBURNBAR_BROWSER_CU_INTEGRATION_NODE_PATH",
            "OPENBURNBAR_BROWSER_CU_INTEGRATION_BROWSERS_PATH",
        };

        public PlaywrightIntegrationFactAttribute()
        {
            if (RequiredEnvironment.Any(name =>
                    string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(name))))
            {
                Skip = "Live Playwright bridge environment is not configured.";
            }
        }
    }
}

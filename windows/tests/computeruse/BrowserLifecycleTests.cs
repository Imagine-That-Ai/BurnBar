using System.Diagnostics;
using System.Linq;
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
}

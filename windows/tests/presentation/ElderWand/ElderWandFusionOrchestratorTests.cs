using System.Threading.Tasks;
using System.IO;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.ElderWand;

public sealed class ElderWandFusionOrchestratorTests
{
    [Fact]
    public async Task RunAsync_ReachesTerminalWithinBudget()
    {
        var orch = new ElderWandFusionOrchestrator((call, _) =>
        {
            if (call.Step >= 2)
            {
                return Task.FromResult(FusionToolResult.Done("final"));
            }

            return Task.FromResult(FusionToolResult.Continue("mid-" + call.Step));
        });

        FusionRunResult result = await orch.RunAsync(new FusionRunRequest("seed", MaxSteps: 5));
        Assert.True(result.Succeeded);
        Assert.Equal(2, result.Steps.Count);
        Assert.True(result.Steps[^1].Result.Terminal);
    }

    [Fact]
    public async Task RunAsync_StopsOnToolFailure()
    {
        var orch = new ElderWandFusionOrchestrator((_, _) =>
            Task.FromResult(FusionToolResult.Fail("boom")));
        FusionRunResult result = await orch.RunAsync(new FusionRunRequest("seed", MaxSteps: 3));
        Assert.False(result.Succeeded);
        Assert.Equal("boom", result.Error);
        Assert.Single(result.Steps);
    }

    [Fact]
    public async Task RunAsync_JournalsMetadataWithoutPayload()
    {
        string path = Path.Combine(Path.GetTempPath(), "obb-fusion-" + Path.GetRandomFileName() + ".jsonl");
        try
        {
            var journal = new JsonLinesFusionRunJournal(path);
            var orch = new ElderWandFusionOrchestrator(
                (_, _) => Task.FromResult(FusionToolResult.Done("secret-output")),
                journal);

            FusionRunResult result = await orch.RunAsync(new FusionRunRequest("secret-prompt", RunId: "run-1"));
            Assert.True(result.Succeeded);
            string contents = File.ReadAllText(path);
            Assert.Contains("run-1", contents, System.StringComparison.Ordinal);
            Assert.DoesNotContain("secret-prompt", contents, System.StringComparison.Ordinal);
            Assert.DoesNotContain("secret-output", contents, System.StringComparison.Ordinal);
            Assert.Contains("succeeded", contents, System.StringComparison.Ordinal);
        }
        finally
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }
}

using System.Threading.Tasks;
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
}

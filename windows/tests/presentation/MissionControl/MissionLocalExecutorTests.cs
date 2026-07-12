using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.MissionControl;

public sealed class MissionLocalExecutorTests
{
    [Fact]
    public async Task RunAsync_AllStepsSucceed()
    {
        var exec = new MissionLocalExecutor();
        var steps = new[]
        {
            new MissionLocalStep("a", "echo", "1"),
            new MissionLocalStep("b", "echo", "2"),
        };
        MissionLocalExecutionResult result = await exec.RunAsync(
            steps,
            (step, _) => Task.FromResult(MissionLocalStepResult.Ok()));
        Assert.True(result.Succeeded);
        Assert.Equal(new[] { "a", "b" }, result.CompletedStepIds);
    }

    [Fact]
    public async Task RunAsync_StopsOnFirstFailure()
    {
        var exec = new MissionLocalExecutor();
        var steps = new[]
        {
            new MissionLocalStep("a", "echo", "1"),
            new MissionLocalStep("b", "fail", "x"),
            new MissionLocalStep("c", "echo", "3"),
        };
        MissionLocalExecutionResult result = await exec.RunAsync(
            steps,
            (step, _) => Task.FromResult(
                step.Id == "b" ? MissionLocalStepResult.Fail("boom") : MissionLocalStepResult.Ok()));
        Assert.False(result.Succeeded);
        Assert.Equal(new[] { "a" }, result.CompletedStepIds);
        Assert.Equal("b", result.FailedStepId);
        Assert.Equal("boom", result.Error);
    }
}

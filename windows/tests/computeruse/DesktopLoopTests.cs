using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Loop;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class DesktopLoopTests
{
    [Fact]
    public void Dispatch_WhenKillSwitchActive_DeniesWithoutSynthesize()
    {
        var flag = new InMemoryKillSwitchFlag();
        flag.Activate("test");
        var kill = new KillSwitchStateMachine(flag);
        var input = new RecordingSynthesizer();
        var loop = new ComputerUseDesktopLoop(input, kill);

        ComputerUseLoopResult result = loop.Click(10, 20);
        Assert.False(result.Succeeded);
        Assert.Equal(ComputerUseDenyReason.KillSwitch, result.DenyReason);
        Assert.Equal(0, input.Calls);
    }

    [Fact]
    public void Dispatch_WhenAllowed_SynthesizesClick()
    {
        var flag = new InMemoryKillSwitchFlag();
        var kill = new KillSwitchStateMachine(flag);
        var input = new RecordingSynthesizer();
        var loop = new ComputerUseDesktopLoop(input, kill);

        ComputerUseLoopResult result = loop.Click(3, 4);
        Assert.True(result.Succeeded);
        Assert.Equal(1, input.Calls);
        Assert.Equal(MacInputAction.Kind.Click, input.Last!.ActionKind);
        Assert.Equal(3, input.Last.DisplayX);
        Assert.Equal(4, input.Last.DisplayY);
    }

    private sealed class RecordingSynthesizer : IInputSynthesizer
    {
        public int Calls { get; private set; }

        public MacInputAction? Last { get; private set; }

        public bool RoutesThroughSignedDriver => false;

        public InputSynthesisResult Synthesize(MacInputAction action)
        {
            Calls++;
            Last = action;
            return new InputSynthesisResult(true, "ok");
        }
    }
}

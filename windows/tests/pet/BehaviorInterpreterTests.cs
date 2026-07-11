using System.Collections.Generic;
using OpenBurnBar.App.Pet.Behavior;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests;

public sealed class BehaviorInterpreterTests
{
    [Fact]
    public void RealClaudeCodeGraph_FullChatCycle_WalksIdleListenThinkSpeakReact()
    {
        var graph = PetTestData.LoadClaudeCodeGraph();
        var interp = new BehaviorInterpreter(graph);

        Assert.Equal("idle", interp.Current);

        Assert.Equal("listen", interp.Fire(PetBehaviorTrigger.CursorNear));   // idle  -> listen
        Assert.Equal("think", interp.Fire(PetBehaviorTrigger.SendPressed));   // listen -> think
        Assert.Equal("speak", interp.Fire(PetBehaviorTrigger.StreamStart));   // think  -> speak
        Assert.Equal("react", interp.Fire(PetBehaviorTrigger.ResultLanded));  // speak  -> react
        Assert.Equal("listen", interp.Fire(PetBehaviorTrigger.InputFocused)); // react  -> listen
        Assert.Equal("idle", interp.Fire(PetBehaviorTrigger.IdleElapsed));    // listen -> idle
    }

    [Fact]
    public void RealClaudeCodeGraph_FallbackFired_AlsoLeavesSpeakToReact()
    {
        var interp = new BehaviorInterpreter(PetTestData.LoadClaudeCodeGraph());
        interp.Fire(PetBehaviorTrigger.CursorNear);
        interp.Fire(PetBehaviorTrigger.SendPressed);
        interp.Fire(PetBehaviorTrigger.StreamStart);
        Assert.Equal("speak", interp.Current);
        Assert.Equal("react", interp.Fire(PetBehaviorTrigger.FallbackFired)); // speak -> react (fallback path)
    }

    [Fact]
    public void NoMatchingTransition_ReturnsNull_AndStaysPut()
    {
        var interp = new BehaviorInterpreter(PetTestData.LoadClaudeCodeGraph());
        // From idle, streamStart has no edge.
        Assert.Null(interp.Fire(PetBehaviorTrigger.StreamStart));
        Assert.Equal("idle", interp.Current);
    }

    [Fact]
    public void LogicalState_MapsCanonicalNodes()
    {
        var interp = new BehaviorInterpreter(PetTestData.LoadClaudeCodeGraph());
        Assert.Equal(PetLogicalState.Idle, interp.LogicalState);
        interp.Fire(PetBehaviorTrigger.CursorNear);
        Assert.Equal(PetLogicalState.Listen, interp.LogicalState);
    }

    [Fact]
    public void WeightedSelection_IsDeterministicUnderSeed()
    {
        var graph = PetTestData.TwoWayWeighted(wa: 3, wb: 1);
        var a = new BehaviorInterpreter(graph, seed: 20260703);
        var b = new BehaviorInterpreter(graph, seed: 20260703);

        var seqA = new List<string>();
        var seqB = new List<string>();
        for (var i = 0; i < 50; i++)
        {
            seqA.Add(a.Fire(PetBehaviorTrigger.CooldownElapsed)!); // s -> a|b
            a.Fire(PetBehaviorTrigger.ResultLanded);               // back to s
            seqB.Add(b.Fire(PetBehaviorTrigger.CooldownElapsed)!);
            b.Fire(PetBehaviorTrigger.ResultLanded);
        }

        Assert.Equal(seqA, seqB);           // same seed -> identical stream
        Assert.Contains("a", seqA);          // both branches reachable
        Assert.Contains("b", seqA);
    }

    [Fact]
    public void WeightedSelection_HonoursWeightBias()
    {
        // 9:1 bias should pick "a" far more often than "b" over many draws.
        var graph = PetTestData.TwoWayWeighted(wa: 9, wb: 1);
        var interp = new BehaviorInterpreter(graph, seed: 5);
        var countA = 0;
        var total = 4000;
        for (var i = 0; i < total; i++)
        {
            if (interp.Fire(PetBehaviorTrigger.CooldownElapsed) == "a")
            {
                countA++;
            }
            interp.Fire(PetBehaviorTrigger.ResultLanded);
        }
        // Expect ~90%; allow a wide band so the test is not flaky.
        Assert.InRange(countA / (double)total, 0.80, 0.98);
    }

    [Fact]
    public void ZeroWeightBranch_IsNeverSelected()
    {
        var graph = PetTestData.TwoWayWeighted(wa: 0, wb: 5);
        var interp = new BehaviorInterpreter(graph, seed: 1);
        for (var i = 0; i < 500; i++)
        {
            Assert.Equal("b", interp.Fire(PetBehaviorTrigger.CooldownElapsed));
            interp.Fire(PetBehaviorTrigger.ResultLanded);
        }
    }

    [Fact]
    public void Reset_ReturnsToInitial()
    {
        var interp = new BehaviorInterpreter(PetTestData.LoadClaudeCodeGraph());
        interp.Fire(PetBehaviorTrigger.CursorNear);
        Assert.Equal("listen", interp.Current);
        interp.Reset();
        Assert.Equal("idle", interp.Current);
    }

    [Fact]
    public void UnknownTrigger_RoundTripsThroughOther()
    {
        var custom = PetBehaviorTrigger.FromRawValue("teleport");
        Assert.Equal(PetBehaviorTriggerKind.Other, custom.Kind);
        Assert.Equal("teleport", custom.RawValue);
        // A graph edge keyed on the custom trigger fires on the same custom trigger.
        var graph = new PetBehaviorGraph("idle", new[]
        {
            new PetBehaviorTransition("idle", "wander", custom),
        });
        var interp = new BehaviorInterpreter(graph);
        Assert.Equal("wander", interp.Fire(PetBehaviorTrigger.FromRawValue("teleport")));
    }

    [Fact]
    public void StateChanged_FiresOnTransition()
    {
        var interp = new BehaviorInterpreter(PetTestData.LoadClaudeCodeGraph());
        string? seen = null;
        interp.StateChanged += s => seen = s;
        interp.Fire(PetBehaviorTrigger.CursorNear);
        Assert.Equal("listen", seen);
    }
}

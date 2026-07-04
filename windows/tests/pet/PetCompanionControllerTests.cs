using System.Collections.Generic;
using OpenBurnBar.App.Pet;
using OpenBurnBar.App.Pet.Behavior;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests;

public sealed class PetCompanionControllerTests
{
    private static PetCompanionController NewController(out ChatSessionStateMachine chat)
    {
        chat = new ChatSessionStateMachine();
        return new PetCompanionController(PetTestData.LoadClaudeCodeGraph(), chat, PetTestData.LoadClaudeCode());
    }

    [Fact]
    public void Activity_StartsIdle()
    {
        using var c = NewController(out _);
        Assert.Equal(PetActivityState.Idle, c.Activity);
        Assert.Equal("idle", c.CurrentLogicalNode);
    }

    [Fact]
    public void EngagingChat_MovesActivityToActive()
    {
        using var c = NewController(out _);
        c.Bridge.NotifyCursorNear(); // idle -> listen
        Assert.Equal("listen", c.CurrentLogicalNode);
        Assert.Equal(PetActivityState.Active, c.Activity);
    }

    [Fact]
    public void Summon_OverridesToSummon_ThenReleaseReverts()
    {
        using var c = NewController(out _);
        var events = new List<PetActivityState>();
        c.ActivityChanged += a => events.Add(a);

        c.Summon();
        Assert.Equal(PetActivityState.Summon, c.Activity);

        c.ReleaseSummon();
        // After release, the pet is in "listen" (summon pulled it via cursorNear) -> Active.
        Assert.Equal(PetActivityState.Active, c.Activity);

        Assert.Contains(PetActivityState.Summon, events);
        Assert.Contains(PetActivityState.Active, events);
    }

    [Fact]
    public void DrivingBackToIdle_ReturnsActivityToIdle()
    {
        using var c = NewController(out _);
        c.Bridge.NotifyCursorNear(); // -> listen (Active)
        Assert.Equal(PetActivityState.Active, c.Activity);
        c.Bridge.NotifyIdleElapsed(); // listen -> idle (Idle)
        Assert.Equal("idle", c.CurrentLogicalNode);
        Assert.Equal(PetActivityState.Idle, c.Activity);
    }

    [Fact]
    public void ActivityChanged_OnlyFiresOnRealDelta()
    {
        using var c = NewController(out _);
        var events = new List<PetActivityState>();
        c.ActivityChanged += a => events.Add(a);

        // idle -> listen -> think -> speak are all "Active" after the first Idle->Active
        // transition; only ONE Active event should be emitted across them.
        c.Bridge.NotifyCursorNear();  // Idle -> Active
        c.Bridge.NotifyInputFocused(); // listen has no inputFocused edge -> no move

        Assert.Equal(new[] { PetActivityState.Active }, events);
    }

    [Fact]
    public void CurrentClip_ResolvesToAPlayableClip()
    {
        using var c = NewController(out _);
        // claudecode's clip inventory (atlas states) contains "idle"; every logical
        // node resolves to a real clip (never null for a pet with clips).
        Assert.NotNull(c.CurrentClip);
    }
}

using System.Collections.Generic;
using OpenBurnBar.App.Pet;
using OpenBurnBar.App.Pet.Behavior;
using OpenBurnBar.App.Pet.Chat;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests;

public sealed class PetChatEventBridgeTests
{
    private static (BehaviorInterpreter interp, ChatSessionStateMachine chat, PetChatEventBridge bridge) NewRig()
    {
        var interp = new BehaviorInterpreter(PetTestData.LoadClaudeCodeGraph());
        var chat = new ChatSessionStateMachine();
        var bridge = new PetChatEventBridge(interp, chat);
        return (interp, chat, bridge);
    }

    [Fact]
    public void ChatLifecycle_DrivesGraph_IdleListenThinkSpeakReact()
    {
        var (interp, chat, bridge) = NewRig();

        bridge.NotifyCursorNear();                 // idle -> listen
        Assert.Equal("listen", interp.Current);

        var user = chat.TryBeginUserTurn("what is this?"); // SendInFlight -> sendPressed -> think
        Assert.NotNull(user);
        Assert.Equal("think", interp.Current);

        chat.BeginAssistantStream();               // Phase Streaming -> streamStart -> speak
        Assert.Equal("speak", interp.Current);

        chat.Ingest(new ChatStreamEvent.Text("hello"));    // streamToken (speak stays)
        Assert.Equal("speak", interp.Current);

        chat.CompleteStream();                     // settled(completed) -> resultLanded -> react
        Assert.Equal("react", interp.Current);
    }

    [Fact]
    public void Cancel_DoesNotLandResult_PartialStays()
    {
        var (interp, chat, bridge) = NewRig();
        bridge.NotifyCursorNear();
        chat.TryBeginUserTurn("hi");
        chat.BeginAssistantStream();
        chat.Ingest(new ChatStreamEvent.Text("partial"));
        Assert.Equal("speak", interp.Current);

        chat.CancelGeneration();                   // settled(cancelled) -> NO resultLanded
        Assert.Equal("speak", interp.Current);
    }

    [Fact]
    public void Failure_LandsResult_PetReacts()
    {
        var (interp, chat, bridge) = NewRig();
        bridge.NotifyCursorNear();
        chat.TryBeginUserTurn("hi");
        chat.BeginAssistantStream();
        Assert.Equal("speak", interp.Current);

        chat.FailStream(cancelled: false, errorMessage: "boom"); // resultLanded -> react
        Assert.Equal("react", interp.Current);
    }

    [Fact]
    public void TriggerFired_ReportsEachRoutedTrigger()
    {
        var (_, chat, bridge) = NewRig();
        var fired = new List<PetBehaviorTrigger>();
        bridge.TriggerFired += (t, _) => fired.Add(t);

        bridge.NotifyCursorNear();
        chat.TryBeginUserTurn("hi");
        chat.BeginAssistantStream();
        chat.CompleteStream();

        Assert.Contains(PetBehaviorTrigger.CursorNear, fired);
        Assert.Contains(PetBehaviorTrigger.SendPressed, fired);
        Assert.Contains(PetBehaviorTrigger.StreamStart, fired);
        Assert.Contains(PetBehaviorTrigger.ResultLanded, fired);
    }

    [Fact]
    public void Dispose_StopsRoutingChatEvents()
    {
        var (interp, chat, bridge) = NewRig();
        bridge.NotifyCursorNear();
        bridge.Dispose();
        // After dispose, the send no longer drives the graph.
        chat.TryBeginUserTurn("hi");
        Assert.Equal("listen", interp.Current);
    }
}

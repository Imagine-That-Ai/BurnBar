using System;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.Integrations.Cast.Protocol;
using OpenBurnBar.Integrations.Cast.Session;
using Xunit;

namespace OpenBurnBar.Integrations.Cast.Tests;

public sealed class CastReceiverStateMachineTests
{
    private const string Url = "https://dash.test/board";

    private static CastInboundEvent Active(string session, string? transport, string? app)
        => new()
        {
            Kind = CastInboundKind.ReceiverStatusActive,
            SessionId = session,
            TransportId = transport,
            AppId = app,
        };

    private static CastInboundEvent Idle()
        => new() { Kind = CastInboundKind.ReceiverStatusIdle };

    private static CastInboundEvent LaunchError(string reason)
        => new() { Kind = CastInboundKind.LaunchError, LaunchErrorReason = reason };

    [Fact]
    public void Start_OpensChannelThenQueriesStatus()
    {
        var machine = new CastReceiverStateMachine(Url);
        var step = machine.Start();

        Assert.Equal(CastCastPhase.QueryingStatus, step.Phase);
        Assert.Equal(2, step.Outbound.Count);
        Assert.Equal(CastReceiverProtocol.NamespaceConnection, step.Outbound[0].Namespace);
        Assert.Equal(CastReceiverProtocol.NamespaceReceiver, step.Outbound[1].Namespace);
    }

    [Fact]
    public void IdleReceiver_LaunchesDashCastDirectly()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();

        var step = machine.OnEvent(Idle());
        Assert.Equal(CastCastPhase.Launching, step.Phase);
        var launch = Assert.Single(step.Outbound);
        using var doc = JsonDocument.Parse(launch.PayloadUtf8);
        Assert.Equal("LAUNCH", doc.RootElement.GetProperty("type").GetString());
    }

    [Fact]
    public void StaleSession_IsStoppedBeforeRelaunch()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();

        var stop = machine.OnEvent(Active("old-session", "transport-1", "OtherApp"));
        Assert.Equal(CastCastPhase.StoppingStale, stop.Phase);
        using var doc = JsonDocument.Parse(Assert.Single(stop.Outbound).PayloadUtf8);
        Assert.Equal("STOP", doc.RootElement.GetProperty("type").GetString());
        Assert.Equal("old-session", doc.RootElement.GetProperty("sessionId").GetString());

        // After the STOP acknowledges, we LAUNCH fresh.
        var launch = machine.OnEvent(Active("old-session", "transport-1", "OtherApp"));
        Assert.Equal(CastCastPhase.Launching, launch.Phase);
    }

    [Fact]
    public void ExistingDashCastSession_IsAlsoStoppedNeverReused()
    {
        // The hard rule: a reported-active DashCast session may be visually stuck
        // on its splash, so it is STOPped, not reused.
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();

        var step = machine.OnEvent(Active("dash-session", "transport-x", CastReceiverProtocol.DashCastAppId));
        Assert.Equal(CastCastPhase.StoppingStale, step.Phase);
        using var doc = JsonDocument.Parse(Assert.Single(step.Outbound).PayloadUtf8);
        Assert.Equal("STOP", doc.RootElement.GetProperty("type").GetString());
    }

    [Fact]
    public void SuccessfulLaunch_ConnectsTransportAndEmitsTheThreeAttemptLoadPlan()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();
        machine.OnEvent(Idle()); // → Launching

        var step = machine.OnEvent(Active("new-session", "transport-77", CastReceiverProtocol.DashCastAppId));

        Assert.Equal(CastCastPhase.Streaming, step.Phase);
        Assert.True(step.StartHeartbeat);
        Assert.Equal("transport-77", machine.TransportId);

        // Transport CONNECT.
        var connect = Assert.Single(step.Outbound);
        Assert.Equal(CastReceiverProtocol.NamespaceConnection, connect.Namespace);
        Assert.Equal("transport-77", connect.DestinationId);

        // 3 LOAD attempts: force false/true/true at 0/600/1500 ms.
        Assert.Equal(3, step.LoadPlan.Count);
        Assert.Equal(new[] { false, true, true }, step.LoadPlan.Select(a => a.Force).ToArray());
        Assert.Equal(TimeSpan.Zero, step.LoadPlan[0].Delay);
        Assert.Equal(TimeSpan.FromMilliseconds(600), step.LoadPlan[1].Delay);
        Assert.Equal(TimeSpan.FromMilliseconds(1_500), step.LoadPlan[2].Delay);
        foreach (var attempt in step.LoadPlan)
        {
            Assert.Equal(CastReceiverProtocol.NamespaceDashCast, attempt.Message.Namespace);
            Assert.Equal("transport-77", attempt.Message.DestinationId);
            using var doc = JsonDocument.Parse(attempt.Message.PayloadUtf8);
            Assert.Equal(Url, doc.RootElement.GetProperty("url").GetString());
            Assert.Equal(attempt.Force, doc.RootElement.GetProperty("force").GetBoolean());
        }
    }

    [Fact]
    public void LaunchError_NotFound_MapsToAFriendlyMessage()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();
        machine.OnEvent(Idle());

        var step = machine.OnEvent(LaunchError("NOT_FOUND"));
        Assert.Equal(CastCastPhase.Failed, step.Phase);
        Assert.Equal("This device can't display web pages. Pick a Nest Hub or Chromecast.", step.FailureReason);
    }

    [Fact]
    public void LaunchError_OtherReason_SurfacesTheRawReason()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();
        machine.OnEvent(Idle());

        var step = machine.OnEvent(LaunchError("INVALID_PARAMETER"));
        Assert.Equal(CastCastPhase.Failed, step.Phase);
        Assert.Equal("INVALID_PARAMETER", step.FailureReason);
    }

    [Fact]
    public void Launch_MissingTransport_Fails()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();
        machine.OnEvent(Idle());

        var step = machine.OnEvent(Active("s", transport: null, app: CastReceiverProtocol.DashCastAppId));
        Assert.Equal(CastCastPhase.Failed, step.Phase);
        Assert.Equal("Missing transport id after LAUNCH", step.FailureReason);
    }

    [Fact]
    public void Launch_IdleResponse_FailsWithNoSessions()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();
        machine.OnEvent(Idle());

        var step = machine.OnEvent(Idle());
        Assert.Equal(CastCastPhase.Failed, step.Phase);
        Assert.Equal("Receiver returned no sessions", step.FailureReason);
    }

    [Fact]
    public void Ping_IsAnsweredWithPongInAnyPhase()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();

        var step = machine.OnEvent(new CastInboundEvent { Kind = CastInboundKind.Ping });
        var pong = Assert.Single(step.Outbound);
        using var doc = JsonDocument.Parse(pong.PayloadUtf8);
        Assert.Equal("PONG", doc.RootElement.GetProperty("type").GetString());
        // Phase is unchanged by a heartbeat.
        Assert.Equal(CastCastPhase.QueryingStatus, step.Phase);
    }

    [Fact]
    public void OnNoResponse_InQueryingStatus_ProceedsToLaunch()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();
        var step = machine.OnNoResponse();
        Assert.Equal(CastCastPhase.Launching, step.Phase);
    }

    [Fact]
    public void OnNoResponse_InLaunching_TimesOut()
    {
        var machine = new CastReceiverStateMachine(Url);
        machine.Start();
        machine.OnEvent(Idle());
        var step = machine.OnNoResponse();
        Assert.Equal(CastCastPhase.Failed, step.Phase);
        Assert.Equal("Hub didn't respond in time", step.FailureReason);
    }

    [Fact]
    public void NextRequestId_IsMonotonicFromOne()
    {
        var machine = new CastReceiverStateMachine(Url);
        Assert.Equal(1, machine.NextRequestId());
        Assert.Equal(2, machine.NextRequestId());
        Assert.Equal(3, machine.NextRequestId());
    }
}

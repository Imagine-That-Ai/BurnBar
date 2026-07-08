using System;
using System.Linq;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Connect/disconnect ordering + rollback parity for the session state machine.</summary>
public sealed class SessionStateMachineTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 6, 12, 0, 0, TimeSpan.Zero);

    private static readonly string[] ConnectOrder =
    {
        "ValidateConfiguration",
        "EnsureSupportDirectory",
        "RefreshSystemHealth",
        "GenerateRotationToken",
        "StartSecretBroker",
        "WriteProxyScript",
        "WriteProxyConfig",
        "StartProxy",
        "StartTunnel",
        "ApplyCursorSettings",
        "VerifyPublicEndpoint",
    };

    private static CursorConnectorSession NewSession(RecordingSessionSteps steps, out CursorConnectorConfig config, out ConnectorHealthSnapshot health)
    {
        config = CursorConnectorConfig.CreateDefault();
        health = new ConnectorHealthSnapshot();
        return new CursorConnectorSession(steps, config, health, new FixedClock(Now));
    }

    [Fact]
    public void Connect_RunsStepsInOrderAndMarksConnected()
    {
        var steps = new RecordingSessionSteps();
        var session = NewSession(steps, out var config, out _);

        var state = session.Connect();

        Assert.Equal(ConnectorSessionState.Connected, state);
        Assert.Equal(ConnectOrder, steps.Calls.ToArray());
        Assert.True(config.IsEnabled);
        Assert.Equal("Connected to Cursor", config.StatusMessage);
        Assert.Equal(Now, config.LastAppliedAt);
        Assert.Null(session.LastError);
    }

    [Fact]
    public void Connect_FailureRollsBackInOrder()
    {
        var steps = new RecordingSessionSteps(throwAt: "StartTunnel");
        var session = NewSession(steps, out var config, out _);

        var state = session.Connect();

        Assert.Equal(ConnectorSessionState.Failed, state);
        Assert.False(config.IsEnabled);
        Assert.Equal("Connection failed", config.StatusMessage);
        Assert.Equal("boom:StartTunnel", session.LastError);

        // Teardown order after the failed StartTunnel: broker, tunnel, proxy, restore.
        Assert.Equal(
            new[] { "StopSecretBroker", "StopTunnel", "StopProxy", "RestoreCursorSettings" },
            steps.Calls.SkipWhile(call => call != "StartTunnel").Skip(1).ToArray());
    }

    [Fact]
    public void Connect_FailedRollbackAlsoFailing_SurfacesBothErrors()
    {
        var steps = new RecordingSessionSteps(throwAt: "StartProxy", throwOnRestore: true);
        var session = NewSession(steps, out var config, out _);

        session.Connect();

        Assert.Equal("Connection failed (Cursor settings may need a manual reset)", config.StatusMessage);
        Assert.Contains("boom:StartProxy", session.LastError);
        Assert.Contains("restore-failed", session.LastError);
    }

    [Fact]
    public void Connect_ValidationFailure_DoesNotStartAnything()
    {
        var steps = new RecordingSessionSteps(throwAt: "ValidateConfiguration");
        var session = NewSession(steps, out _, out _);

        session.Connect();

        Assert.DoesNotContain("StartSecretBroker", steps.Calls);
        Assert.DoesNotContain("StartTunnel", steps.Calls);
        // Rollback still runs (idempotent stops + restore).
        Assert.Contains("RestoreCursorSettings", steps.Calls);
    }

    [Fact]
    public void Disconnect_StopsEverythingAndClearsTunnel()
    {
        var steps = new RecordingSessionSteps();
        var session = NewSession(steps, out var config, out var health);
        config.IsEnabled = true;
        config.Tunnel.PublicBaseURL = "https://x.trycloudflare.com/v1";
        health.PublicBaseURLReachable = true;

        var state = session.Disconnect();

        Assert.Equal(ConnectorSessionState.Disconnected, state);
        Assert.Equal(
            new[] { "StopTunnel", "StopProxy", "StopSecretBroker", "RestoreCursorSettings" },
            steps.Calls.ToArray());
        Assert.False(config.IsEnabled);
        Assert.Null(config.Tunnel.PublicBaseURL);
        Assert.Equal("Disconnected", config.StatusMessage);
        Assert.False(health.PublicBaseURLReachable);
    }
}

using System;
using System.Collections.Generic;
using OpenBurnBar.Integrations.Cast.Session;
using Xunit;

namespace OpenBurnBar.Integrations.Cast.Tests;

public sealed class CastReconnectPlannerTests
{
    [Fact]
    public void BackoffSchedule_IsExponentialOneToEightSeconds()
    {
        Assert.Equal(4, CastReconnectPlanner.MaxAttempts);
        Assert.Equal(
            new[]
            {
                TimeSpan.FromSeconds(1),
                TimeSpan.FromSeconds(2),
                TimeSpan.FromSeconds(4),
                TimeSpan.FromSeconds(8),
            },
            CastReconnectPlanner.BackoffSchedule);
    }

    [Fact]
    public void BackoffAfter_RejectsOutOfRangeIndex()
    {
        Assert.Equal(TimeSpan.FromSeconds(4), CastReconnectPlanner.BackoffAfter(2));
        Assert.Throws<ArgumentOutOfRangeException>(() => CastReconnectPlanner.BackoffAfter(4));
        Assert.Throws<ArgumentOutOfRangeException>(() => CastReconnectPlanner.BackoffAfter(-1));
    }

    [Fact]
    public void Resolve_FirstSuccessfulAttemptWins()
    {
        var attempts = new List<CastAttemptOutcome>
        {
            CastAttemptOutcome.Failed("nope"),
            CastAttemptOutcome.Ok("session-123"),
        };

        var result = CastReconnectPlanner.Resolve("Living Room Hub", attempts, HomeAssistantOutcome.Skipped);
        Assert.Equal(CastRecoveryResultKind.Success, result.Kind);
        Assert.Equal("session-123", result.SessionId);
    }

    [Fact]
    public void Resolve_AllFailedWithSkippedRecovery_ReportsLastError()
    {
        var attempts = new List<CastAttemptOutcome>
        {
            CastAttemptOutcome.Failed("first"),
            CastAttemptOutcome.Failed("final error"),
        };

        var result = CastReconnectPlanner.Resolve("Hub", attempts, HomeAssistantOutcome.Skipped);
        Assert.Equal(CastRecoveryResultKind.Failure, result.Kind);
        Assert.Equal("final error", result.Message);
        Assert.Equal(4, result.AttemptsMade);
    }

    [Fact]
    public void Resolve_TimeoutSetsTheStandardTimeoutReason()
    {
        var attempts = new List<CastAttemptOutcome> { CastAttemptOutcome.TimedOut() };
        var result = CastReconnectPlanner.Resolve("Hub", attempts, HomeAssistantOutcome.Skipped);
        Assert.Equal(CastReconnectPlanner.TimeoutReason, result.Message);
    }

    [Fact]
    public void Resolve_AllFailedThenHomeAssistantTriggered_IsRecovered()
    {
        var attempts = new List<CastAttemptOutcome> { CastAttemptOutcome.Failed("boom") };
        var result = CastReconnectPlanner.Resolve("Living Room Hub", attempts, HomeAssistantOutcome.Triggered);

        Assert.Equal(CastRecoveryResultKind.RecoveredViaHomeAssistant, result.Kind);
        Assert.Contains("Living Room Hub", result.Message);
        Assert.Contains("Home Assistant", result.Message);
    }

    [Fact]
    public void Resolve_AllFailedThenHomeAssistantFailed_CombinesBothReasons()
    {
        var attempts = new List<CastAttemptOutcome> { CastAttemptOutcome.Failed("native down") };
        var result = CastReconnectPlanner.Resolve(
            "Hub",
            attempts,
            HomeAssistantOutcome.Fail("webhook 500"));

        Assert.Equal(CastRecoveryResultKind.Failure, result.Kind);
        Assert.Contains("native down", result.Message);
        Assert.Contains("Home Assistant recovery also failed: webhook 500", result.Message);
        Assert.Equal(4, result.AttemptsMade);
    }
}

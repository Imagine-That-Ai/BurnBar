using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.MissionControl;

/// <summary>Locks the snapshot derivation ported from
/// <c>MissionConsoleMacHost.rebuildSnapshot</c> + its adapters (MissionConsoleMacHost.swift):
/// phase mapping, health counts, burn-per-hour weighting, approval asks, project ordering.</summary>
public sealed class MissionSnapshotBuilderTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);

    private static MissionRecord Record(
        string id,
        MissionRecordState state,
        MissionApprovalState approval = MissionApprovalState.None,
        double burn = 0,
        double updatedMinutesAgo = 1,
        string project = "burnbar",
        string? worker = null) =>
        new(id, $"Mission {id}", project, state, approval, Now.AddMinutes(-updatedMinutesAgo), burn, worker);

    private static readonly IReadOnlyList<MissionRuntime> Catalog = new[]
    {
        new MissionRuntime("claude", "Claude Code", "CLD", "claudeCode", RuntimeAvailability.Online),
        new MissionRuntime("codex", "Codex CLI", "CDX", "codex", RuntimeAvailability.Online),
        new MissionRuntime("ollama", "Ollama", "OLM", "ollama", RuntimeAvailability.Unknown),
    };

    private static MissionConsoleSnapshot Build(params MissionRecord[] records) =>
        MissionSnapshotBuilder.Build(
            records,
            Array.Empty<MissionControllerEvent>(),
            Catalog,
            new MissionRuntimeSnapshot(RuntimeSnapshotSource.Daemon, Now),
            Now);

    [Fact]
    public void CompletedMissionsAreNotLiveTiles()
    {
        var snap = Build(
            Record("a", MissionRecordState.Running),
            Record("b", MissionRecordState.Completed));
        Assert.Single(snap.ActiveTiles);
        Assert.Equal("a", snap.ActiveTiles[0].Id);
    }

    [Fact]
    public void HealthCountsPartitionByState()
    {
        var snap = Build(
            Record("r", MissionRecordState.Running),
            Record("p", MissionRecordState.Partial),
            Record("q", MissionRecordState.Planned),
            Record("b", MissionRecordState.Blocked),
            Record("c", MissionRecordState.Completed));
        Assert.Equal(2, snap.Health.OpenMissions);   // running + partial
        Assert.Equal(1, snap.Health.QueuedMissions); // planned
        Assert.Equal(1, snap.Health.BlockedMissions);
    }

    [Fact]
    public void RunningWithoutWorkerIsStarting_WithWorkerIsRunning()
    {
        Assert.Equal(MissionTilePhase.Starting,
            MissionSnapshotBuilder.ResolvePhase(Record("x", MissionRecordState.Running, worker: null)));
        Assert.Equal(MissionTilePhase.Running,
            MissionSnapshotBuilder.ResolvePhase(Record("x", MissionRecordState.Running, worker: "Claude Code")));
    }

    [Fact]
    public void PendingApprovalMapsToAwaitingApproval_UnlessBlocked()
    {
        Assert.Equal(MissionTilePhase.AwaitingApproval,
            MissionSnapshotBuilder.ResolvePhase(Record("x", MissionRecordState.Running, MissionApprovalState.Pending)));
        // Blocked overrides the awaiting-approval mapping.
        Assert.Equal(MissionTilePhase.Blocked,
            MissionSnapshotBuilder.ResolvePhase(Record("x", MissionRecordState.Blocked, MissionApprovalState.Pending)));
    }

    [Fact]
    public void ApprovalAsks_OnlyPendingNonCompleted()
    {
        var snap = Build(
            Record("a", MissionRecordState.Running, MissionApprovalState.Pending),
            Record("b", MissionRecordState.Completed, MissionApprovalState.Pending),
            Record("c", MissionRecordState.Running, MissionApprovalState.None));
        Assert.Single(snap.ApprovalAsks);
        Assert.Equal("a", snap.ApprovalAsks[0].MissionId);
        Assert.Equal("approval-a", snap.ApprovalAsks[0].Id);
    }

    [Fact]
    public void RuntimeIdGuess_InfersFromWorkerName()
    {
        Assert.Equal("claude", MissionSnapshotBuilder.RuntimeIdGuess("Claude Code"));
        Assert.Equal("codex", MissionSnapshotBuilder.RuntimeIdGuess("GPT-5 / OpenAI"));
        Assert.Equal("hermes", MissionSnapshotBuilder.RuntimeIdGuess("Hermes Relay"));
        Assert.Equal("openclaw", MissionSnapshotBuilder.RuntimeIdGuess("openclaw-worker"));
        Assert.Null(MissionSnapshotBuilder.RuntimeIdGuess(null));
        Assert.Null(MissionSnapshotBuilder.RuntimeIdGuess("mystery-agent"));
    }

    [Fact]
    public void ProgressFraction_MonotonicByState()
    {
        Assert.Equal(0.05, MissionSnapshotBuilder.ProgressFraction(MissionRecordState.Planned));
        Assert.Equal(0.35, MissionSnapshotBuilder.ProgressFraction(MissionRecordState.Running));
        Assert.Equal(0.7, MissionSnapshotBuilder.ProgressFraction(MissionRecordState.Partial));
        Assert.Equal(1.0, MissionSnapshotBuilder.ProgressFraction(MissionRecordState.Completed));
    }

    [Fact]
    public void BurnPerHour_WeightsRecentUpdatesAndCaps()
    {
        // A mission that burned $1 half an hour ago -> ~$2/hr equivalent.
        double perHour = MissionSnapshotBuilder.ComputeBurnPerHour(
            new[] { Record("a", MissionRecordState.Running, burn: 1.0, updatedMinutesAgo: 30) },
            Now);
        Assert.InRange(perHour, 1.9, 2.1);

        // Fresh (<60s) updates use raw cost as a floor.
        double fresh = MissionSnapshotBuilder.ComputeBurnPerHour(
            new[] { Record("a", MissionRecordState.Running, burn: 0.5, updatedMinutesAgo: 0.5) },
            Now);
        Assert.Equal(0.5, fresh, 3);

        // Stale (>1h) updates are excluded.
        double stale = MissionSnapshotBuilder.ComputeBurnPerHour(
            new[] { Record("a", MissionRecordState.Running, burn: 5.0, updatedMinutesAgo: 90) },
            Now);
        Assert.Equal(0.0, stale, 3);
    }

    [Fact]
    public void BurnPerHour_CapsAt99()
    {
        var heavy = Enumerable.Range(0, 50)
            .Select(i => Record($"m{i}", MissionRecordState.Running, burn: 100, updatedMinutesAgo: 30))
            .ToArray();
        Assert.Equal(99.0, MissionSnapshotBuilder.ComputeBurnPerHour(heavy, Now), 3);
    }

    [Fact]
    public void KnownProjects_SortedDistinct_RecentProjects_OrderPreservingCappedAtFour()
    {
        var snap = Build(
            Record("a", MissionRecordState.Running, project: "zeta", updatedMinutesAgo: 1),
            Record("b", MissionRecordState.Running, project: "alpha", updatedMinutesAgo: 2),
            Record("c", MissionRecordState.Running, project: "zeta", updatedMinutesAgo: 3),
            Record("d", MissionRecordState.Running, project: "mid", updatedMinutesAgo: 4),
            Record("e", MissionRecordState.Running, project: "last", updatedMinutesAgo: 5),
            Record("f", MissionRecordState.Running, project: "sixth", updatedMinutesAgo: 6));
        // Known projects: alphabetical + distinct.
        Assert.Equal(new[] { "alpha", "last", "mid", "sixth", "zeta" }, snap.KnownProjects.ToArray());
        // Recent projects: most-recent-first, de-duped, capped at 4.
        Assert.Equal(new[] { "zeta", "alpha", "mid", "last" }, snap.RecentProjects.ToArray());
    }

    [Fact]
    public void OnlineRuntimeCount_ReflectsCatalogAvailability()
    {
        var snap = Build(Record("a", MissionRecordState.Running));
        Assert.Equal(2, snap.Health.OnlineRuntimes);  // claude + codex
        Assert.Equal(3, snap.Health.TotalRuntimes);
    }

    [Fact]
    public void DaemonState_ResolvesFromSource()
    {
        Assert.Equal(DaemonState.Live,
            MissionSnapshotBuilder.ResolveDaemonState(new MissionRuntimeSnapshot(RuntimeSnapshotSource.Daemon, Now)));
        Assert.Equal(DaemonState.Stale,
            MissionSnapshotBuilder.ResolveDaemonState(new MissionRuntimeSnapshot(RuntimeSnapshotSource.Mirrored, Now)));
        Assert.Equal(DaemonState.Unknown,
            MissionSnapshotBuilder.ResolveDaemonState(new MissionRuntimeSnapshot(RuntimeSnapshotSource.Inferred, null)));
        Assert.Equal(DaemonState.Stale,
            MissionSnapshotBuilder.ResolveDaemonState(new MissionRuntimeSnapshot(RuntimeSnapshotSource.Inferred, Now)));
    }

    [Fact]
    public void Ticker_ReplayFailureFlagsError()
    {
        var events = new[]
        {
            new MissionControllerEvent("e1", Now, MissionEventCategory.Replay, "Replay", "step FAILED to apply"),
            new MissionControllerEvent("e2", Now, MissionEventCategory.Mission, "Started", "mission underway"),
        };
        var snap = MissionSnapshotBuilder.Build(
            Array.Empty<MissionRecord>(), events, Catalog,
            new MissionRuntimeSnapshot(RuntimeSnapshotSource.Daemon, Now), Now);
        Assert.True(snap.RecentTicker[0].IsError);
        Assert.Equal(MissionTickerKind.ToolResult, snap.RecentTicker[0].Kind);
        Assert.False(snap.RecentTicker[1].IsError);
        Assert.Equal(MissionTickerKind.Status, snap.RecentTicker[1].Kind);
    }
}

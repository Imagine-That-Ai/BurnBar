using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from MissionConsoleMacHost.rebuildSnapshot + its adapters
// (AgentLens/Views/Dashboard/MissionConsoleMacHost.swift). Turns raw controller mission
// records + recent events + the runtime catalog into the MissionConsoleSnapshot the
// console renders. Pure and now-injectable so the phase mapping, health counts,
// burn-per-hour weighting, and project ordering are all unit-testable on macOS.

/// <summary>Builds a <see cref="MissionConsoleSnapshot"/> from controller records.</summary>
public static class MissionSnapshotBuilder
{
    private const double MaxBurnPerHour = 99.0;

    /// <summary>Assemble the console snapshot. <paramref name="runtimes"/> is the runtime
    /// catalog the host advertises (used for online/total counts + the constellation).</summary>
    public static MissionConsoleSnapshot Build(
        IReadOnlyList<MissionRecord> missions,
        IReadOnlyList<MissionControllerEvent> recentEvents,
        IReadOnlyList<MissionRuntime> runtimes,
        MissionRuntimeSnapshot runtimeSnapshot,
        DateTimeOffset now)
    {
        missions ??= Array.Empty<MissionRecord>();
        recentEvents ??= Array.Empty<MissionControllerEvent>();
        runtimes ??= Array.Empty<MissionRuntime>();

        var liveTiles = missions
            .Select(ActiveTile)
            .Where(t => t is not null)
            .Select(t => t!)
            .ToList();

        var approvalAsks = missions
            .Where(m => m.Approval == MissionApprovalState.Pending && m.State != MissionRecordState.Completed)
            .Select(ApprovalAsk)
            .ToList();

        var knownProjects = missions
            .Select(m => m.ProjectName)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(p => p, StringComparer.Ordinal)
            .ToList();

        var recentProjects = UniqueOrderPreserving(
                missions
                    .OrderByDescending(m => m.UpdatedAt)
                    .Select(m => m.ProjectName))
            .Take(4)
            .ToList();

        var ticker = recentEvents.Select(TickerEntry).ToList();

        double burnToday = missions.Sum(m => m.BurnCostUsd);
        double burnPerHour = ComputeBurnPerHour(missions, now);

        DaemonState daemonState = ResolveDaemonState(runtimeSnapshot);
        DateTimeOffset? lastRefresh = runtimeSnapshot.UpdatedAt;

        int onlineRuntimes = runtimes.Count(r => r.Availability == RuntimeAvailability.Online);
        int totalRuntimes = runtimes.Count;

        var health = new MissionSystemHealth(
            daemonState: daemonState,
            lastRefresh: lastRefresh,
            openMissions: missions.Count(m => m.State is MissionRecordState.Running or MissionRecordState.Partial),
            queuedMissions: missions.Count(m => m.State == MissionRecordState.Planned),
            blockedMissions: missions.Count(m => m.State == MissionRecordState.Blocked),
            burnTodayUsd: burnToday,
            burnPerHourUsd: burnPerHour,
            onlineRuntimes: onlineRuntimes,
            totalRuntimes: totalRuntimes);

        return new MissionConsoleSnapshot(
            health: health,
            runtimes: runtimes,
            activeTiles: liveTiles,
            recentTicker: ticker,
            approvalAsks: approvalAsks,
            knownProjects: knownProjects,
            recentProjects: recentProjects);
    }

    /// <summary>Mirrors <c>activeTile(from:)</c>. Returns null for completed missions.</summary>
    public static MissionActiveTile? ActiveTile(MissionRecord mission)
    {
        if (mission.State == MissionRecordState.Completed)
        {
            return null;
        }

        MissionTilePhase phase = ResolvePhase(mission);

        string runtimeDisplay = NonEmpty(mission.ActiveWorkerName) ?? "Mac fleet";
        string? lastSnippet =
            NonEmpty(mission.PacketSummary)
            ?? NonEmpty(mission.LatestResultSummary)
            ?? NonEmpty(mission.LatestAuditSummary);

        return new MissionActiveTile(
            id: mission.Id,
            title: mission.Title,
            runtimeId: RuntimeIdGuess(mission.ActiveWorkerName),
            runtimeDisplayLabel: runtimeDisplay,
            phase: phase,
            phaseDetail: NonEmpty(mission.LatestTakeoverReason),
            currentToolName: null,
            lastEventSnippet: lastSnippet,
            startedAt: mission.UpdatedAt,
            burnSoFarUsd: mission.BurnCostUsd,
            progressFraction: ProgressFraction(mission.State),
            approvalPending: mission.Approval == MissionApprovalState.Pending
                && mission.State != MissionRecordState.Completed);
    }

    /// <summary>Mirrors the Swift phase-mapping closure in <c>activeTile(from:)</c>.</summary>
    public static MissionTilePhase ResolvePhase(MissionRecord mission)
    {
        if (mission.Approval == MissionApprovalState.Pending && mission.State != MissionRecordState.Blocked)
        {
            return MissionTilePhase.AwaitingApproval;
        }

        return mission.State switch
        {
            MissionRecordState.Planned => MissionTilePhase.Queued,
            MissionRecordState.Running => string.IsNullOrEmpty(mission.ActiveWorkerName)
                ? MissionTilePhase.Starting
                : MissionTilePhase.Running,
            MissionRecordState.Partial => MissionTilePhase.Running,
            MissionRecordState.Blocked => MissionTilePhase.Blocked,
            MissionRecordState.Completed => MissionTilePhase.Completed,
            _ => MissionTilePhase.Running,
        };
    }

    /// <summary>Mirrors <c>progressFraction(for:)</c>.</summary>
    public static double ProgressFraction(MissionRecordState state) => state switch
    {
        MissionRecordState.Planned => 0.05,
        MissionRecordState.Running => 0.35,
        MissionRecordState.Partial => 0.7,
        MissionRecordState.Blocked => 0.5,
        MissionRecordState.Completed => 1.0,
        _ => 0.35,
    };

    /// <summary>Mirrors <c>runtimeIDGuess(for:)</c>.</summary>
    public static string? RuntimeIdGuess(string? activeWorkerName)
    {
        if (string.IsNullOrEmpty(activeWorkerName))
        {
            return null;
        }

        string name = activeWorkerName!.ToLowerInvariant();
        if (name.Contains("claude"))
        {
            return "claude";
        }

        if (name.Contains("codex") || name.Contains("gpt") || name.Contains("openai"))
        {
            return "codex";
        }

        if (name.Contains("hermes"))
        {
            return "hermes";
        }

        if (name.Contains("pi ") || name == "pi" || name.Contains("piagent"))
        {
            return "pi";
        }

        if (name.Contains("openclaw") || name.Contains("claw"))
        {
            return "openclaw";
        }

        if (name.Contains("ollama"))
        {
            return "ollama";
        }

        return null;
    }

    /// <summary>Mirrors <c>approvalAsk(from:)</c>.</summary>
    public static MissionApprovalAsk ApprovalAsk(MissionRecord mission)
    {
        string message =
            NonEmpty(mission.LatestAuditSummary)
            ?? NonEmpty(mission.PacketSummary)
            ?? "This mission is awaiting your approval before the agent can proceed.";

        return new MissionApprovalAsk(
            id: $"approval-{mission.Id}",
            missionId: mission.Id,
            title: $"Approve {mission.Title}?",
            message: message,
            runtimeId: RuntimeIdGuess(mission.ActiveWorkerName),
            runtimeDisplayLabel: NonEmpty(mission.ActiveWorkerName) ?? "Mac fleet",
            requestedAt: mission.UpdatedAt);
    }

    /// <summary>Mirrors <c>tickerEntry(from:)</c>.</summary>
    public static MissionTickerEntry TickerEntry(MissionControllerEvent evt)
    {
        MissionTickerKind kind = evt.Category == MissionEventCategory.Replay
            ? MissionTickerKind.ToolResult
            : MissionTickerKind.Status;

        bool isReplayFailure = evt.Category == MissionEventCategory.Replay
            && new[] { evt.Title, evt.Summary, evt.Detail ?? string.Empty }
                .Any(s => s.IndexOf("fail", StringComparison.OrdinalIgnoreCase) >= 0);

        return new MissionTickerEntry(
            id: evt.Id,
            timestamp: evt.CreatedAt,
            kind: kind,
            phase: evt.Category.ToString(),
            title: NonEmpty(evt.Title),
            message: evt.Summary,
            toolName: null,
            pathDetail: NonEmpty(evt.Detail),
            missionId: null,
            runtimeId: null,
            isError: isReplayFailure);
    }

    /// <summary>Mirrors <c>computeBurnPerHour(missions:)</c>: weight each mission's burn by
    /// how recently it updated within the trailing hour, capped at $99/hr.</summary>
    public static double ComputeBurnPerHour(IReadOnlyList<MissionRecord> missions, DateTimeOffset now)
    {
        double perHour = 0.0;
        foreach (MissionRecord mission in missions)
        {
            double elapsed = (now - mission.UpdatedAt).TotalSeconds;
            if (elapsed < 0 || elapsed >= 3_600)
            {
                continue;
            }

            if (elapsed > 60)
            {
                perHour += mission.BurnCostUsd * (3_600 / elapsed);
            }
            else
            {
                // Brand-new updates haven't accumulated yet — raw cost is a floor.
                perHour += mission.BurnCostUsd;
            }
        }

        return Math.Min(perHour, MaxBurnPerHour);
    }

    /// <summary>Mirrors the daemon-state switch in <c>rebuildSnapshot</c>.</summary>
    public static DaemonState ResolveDaemonState(MissionRuntimeSnapshot snapshot) => snapshot.Source switch
    {
        RuntimeSnapshotSource.Daemon => DaemonState.Live,
        RuntimeSnapshotSource.Mirrored => DaemonState.Stale,
        RuntimeSnapshotSource.Inferred => snapshot.UpdatedAt is null ? DaemonState.Unknown : DaemonState.Stale,
        _ => DaemonState.Unknown,
    };

    private static IEnumerable<string> UniqueOrderPreserving(IEnumerable<string> source)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (string item in source)
        {
            if (seen.Add(item))
            {
                yield return item;
            }
        }
    }

    private static string? NonEmpty(string? value)
    {
        if (value is null)
        {
            return null;
        }

        string trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }
}

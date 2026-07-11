using System;

namespace OpenBurnBar.App.Presentation.MissionControl;

// The portable INPUT model the snapshot builder adapts into a MissionConsoleSnapshot —
// the dependency-free subset of the macOS OpenBurnBarControllerMissionRecord /
// OpenBurnBarControllerEvent (AgentLens/Services/OpenBurnBarOperating/*) and the Firestore
// cli_agent_mission_requests documents the Windows host will decode. Keeping this a plain
// value type lets MissionSnapshotBuilder be unit-tested against synthetic records on macOS.

/// <summary>Lifecycle state of a controller mission. Mirrors the macOS mission-record
/// state enum used by <c>MissionConsoleMacHost</c>.</summary>
public enum MissionRecordState
{
    Planned,
    Running,
    Partial,
    Blocked,
    Completed,
}

/// <summary>Approval posture of a mission record. Mirrors the <c>mission.approval</c>
/// field the host reads (<c>.pending</c> gates the approval asks).</summary>
public enum MissionApprovalState
{
    None,
    Pending,
    Approved,
}

/// <summary>Provenance of the runtime snapshot. Mirrors <c>runtime.source</c>
/// (daemon = live, mirrored = stale, inferred = stale/unknown).</summary>
public enum RuntimeSnapshotSource
{
    Daemon,
    Mirrored,
    Inferred,
}

/// <summary>Category of a controller event, driving the ticker mapping. Mirrors the macOS
/// <c>OpenBurnBarControllerEvent.category</c>.</summary>
public enum MissionEventCategory
{
    Controller,
    Mission,
    Question,
    Followup,
    Notification,
    Governance,
    Replay,
}

/// <summary>A single controller mission the builder adapts into a live tile / approval ask.</summary>
public sealed class MissionRecord
{
    public MissionRecord(
        string id,
        string title,
        string projectName,
        MissionRecordState state,
        MissionApprovalState approval,
        DateTimeOffset updatedAt,
        double burnCostUsd = 0,
        string? activeWorkerName = null,
        string? packetSummary = null,
        string? latestResultSummary = null,
        string? latestAuditSummary = null,
        string? latestTakeoverReason = null)
    {
        Id = id;
        Title = title;
        ProjectName = projectName;
        State = state;
        Approval = approval;
        UpdatedAt = updatedAt;
        BurnCostUsd = burnCostUsd;
        ActiveWorkerName = activeWorkerName;
        PacketSummary = packetSummary;
        LatestResultSummary = latestResultSummary;
        LatestAuditSummary = latestAuditSummary;
        LatestTakeoverReason = latestTakeoverReason;
    }

    public string Id { get; }
    public string Title { get; }
    public string ProjectName { get; }
    public MissionRecordState State { get; }
    public MissionApprovalState Approval { get; }
    public DateTimeOffset UpdatedAt { get; }
    public double BurnCostUsd { get; }
    public string? ActiveWorkerName { get; }
    public string? PacketSummary { get; }
    public string? LatestResultSummary { get; }
    public string? LatestAuditSummary { get; }
    public string? LatestTakeoverReason { get; }
}

/// <summary>A recent controller event the builder maps into a ticker entry.</summary>
public sealed class MissionControllerEvent
{
    public MissionControllerEvent(
        string id,
        DateTimeOffset createdAt,
        MissionEventCategory category,
        string title,
        string summary,
        string? detail = null)
    {
        Id = id;
        CreatedAt = createdAt;
        Category = category;
        Title = title;
        Summary = summary;
        Detail = detail;
    }

    public string Id { get; }
    public DateTimeOffset CreatedAt { get; }
    public MissionEventCategory Category { get; }
    public string Title { get; }
    public string Summary { get; }
    public string? Detail { get; }
}

/// <summary>The runtime-snapshot envelope the builder reads (source + freshness).
/// Mirrors the fields <c>MissionConsoleMacHost.rebuildSnapshot</c> pulls off
/// <c>operatingLayer.snapshot.controllerRuntime</c>.</summary>
public sealed class MissionRuntimeSnapshot
{
    public MissionRuntimeSnapshot(
        RuntimeSnapshotSource source,
        DateTimeOffset? updatedAt)
    {
        Source = source;
        UpdatedAt = updatedAt;
    }

    public RuntimeSnapshotSource Source { get; }

    /// <summary>Null models the macOS <c>.distantPast</c> "never observed" sentinel.</summary>
    public DateTimeOffset? UpdatedAt { get; }
}

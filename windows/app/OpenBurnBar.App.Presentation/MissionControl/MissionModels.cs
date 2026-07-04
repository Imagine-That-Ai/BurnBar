using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from OpenBurnBarCore/.../Views/MissionControl/MissionConsoleTypes.swift.
// The display value-types the console renders: runtimes, live tiles, the activity ticker,
// approval asks, the forecast band, system health, and the console snapshot + dispatch
// envelope. All are dependency-free records so hosts (Firestore on Windows, the daemon on
// macOS) adapt their native state into these, and the WinUI XAML x:Binds to them.

/// <summary>Availability of a runtime. Mirrors <c>MissionConsoleRuntime.Availability</c>.</summary>
public enum RuntimeAvailability
{
    Online,
    Offline,
    Unknown,
}

/// <summary>An agent runtime the console can dispatch to. Mirrors
/// <c>MissionConsoleRuntime</c>. <see cref="ProviderKey"/> is the stable id the WinUI
/// layer maps through <c>ProviderBrand</c> for the provider-tinted accent.</summary>
public sealed class MissionRuntime
{
    public MissionRuntime(
        string id,
        string displayName,
        string callSign,
        string providerKey,
        RuntimeAvailability availability = RuntimeAvailability.Unknown,
        double? recentMedianBurnUsd = null,
        int recentSampleSize = 0,
        string? tagline = null,
        double pricingFactor = 1.0)
    {
        Id = id;
        DisplayName = displayName;
        CallSign = callSign;
        ProviderKey = providerKey;
        Availability = availability;
        RecentMedianBurnUsd = recentMedianBurnUsd;
        RecentSampleSize = recentSampleSize;
        Tagline = tagline;
        PricingFactor = pricingFactor;
    }

    public string Id { get; }
    public string DisplayName { get; }

    /// <summary>2-4 character mono call-sign (e.g. "CLD", "CDX", "HRM").</summary>
    public string CallSign { get; }

    /// <summary>Provider identity key (e.g. "claudeCode", "codex", "hermes", "factory").</summary>
    public string ProviderKey { get; }

    public RuntimeAvailability Availability { get; }
    public double? RecentMedianBurnUsd { get; }
    public int RecentSampleSize { get; }
    public string? Tagline { get; }
    public double PricingFactor { get; }

    /// <summary>The synthetic "let the planner pick" runtime. Mirrors
    /// <c>MissionConsoleRuntime.auto</c>.</summary>
    public static MissionRuntime Auto { get; } = new(
        id: "auto",
        displayName: "Auto-route",
        callSign: "AUTO",
        providerKey: "factory",
        availability: RuntimeAvailability.Online,
        recentMedianBurnUsd: null,
        recentSampleSize: 0,
        tagline: "Let the planner pick the best agent for this kind.",
        pricingFactor: 1.0);
}

/// <summary>Lifecycle phase of a live mission tile. Mirrors
/// <c>MissionConsoleActiveTile.Phase</c>.</summary>
public enum MissionTilePhase
{
    Queued,
    Starting,
    Running,
    Tooling,
    AwaitingApproval,
    Streaming,
    Completing,
    Completed,
    Failed,
    Blocked,
    MacOffline,
    Cancelled,
}

/// <summary>Phase display + classification helpers. Mirrors the Swift computed
/// properties on <c>MissionConsoleActiveTile.Phase</c>.</summary>
public static class MissionTilePhaseInfo
{
    public static string DisplayLabel(MissionTilePhase phase) => phase switch
    {
        MissionTilePhase.Queued => "Queued",
        MissionTilePhase.Starting => "Starting",
        MissionTilePhase.Running => "Running",
        MissionTilePhase.Tooling => "Tooling",
        MissionTilePhase.AwaitingApproval => "Awaiting approval",
        MissionTilePhase.Streaming => "Streaming",
        MissionTilePhase.Completing => "Completing",
        MissionTilePhase.Completed => "Completed",
        MissionTilePhase.Failed => "Failed",
        MissionTilePhase.Blocked => "Blocked",
        MissionTilePhase.MacOffline => "Mac offline",
        MissionTilePhase.Cancelled => "Cancelled",
        _ => "Running",
    };

    public static bool IsLive(MissionTilePhase phase) => phase switch
    {
        MissionTilePhase.Queued or MissionTilePhase.Starting or MissionTilePhase.Running
            or MissionTilePhase.Tooling or MissionTilePhase.Streaming or MissionTilePhase.Completing
            or MissionTilePhase.AwaitingApproval => true,
        _ => false,
    };

    public static bool IsProblem(MissionTilePhase phase) => phase switch
    {
        MissionTilePhase.Failed or MissionTilePhase.Blocked or MissionTilePhase.MacOffline
            or MissionTilePhase.Cancelled => true,
        _ => false,
    };
}

/// <summary>One live mission tile in the situation room. Mirrors
/// <c>MissionConsoleActiveTile</c>.</summary>
public sealed class MissionActiveTile
{
    public MissionActiveTile(
        string id,
        string title,
        string? runtimeId,
        string runtimeDisplayLabel,
        MissionTilePhase phase,
        string? phaseDetail = null,
        string? currentToolName = null,
        string? lastEventSnippet = null,
        DateTimeOffset? startedAt = null,
        double burnSoFarUsd = 0,
        double? progressFraction = null,
        bool approvalPending = false)
    {
        Id = id;
        Title = title;
        RuntimeId = runtimeId;
        RuntimeDisplayLabel = runtimeDisplayLabel;
        Phase = phase;
        PhaseDetail = phaseDetail;
        CurrentToolName = currentToolName;
        LastEventSnippet = lastEventSnippet;
        StartedAt = startedAt;
        BurnSoFarUsd = burnSoFarUsd;
        ProgressFraction = progressFraction;
        ApprovalPending = approvalPending;
    }

    public string Id { get; }
    public string Title { get; }
    public string? RuntimeId { get; }
    public string RuntimeDisplayLabel { get; }
    public MissionTilePhase Phase { get; }
    public string? PhaseDetail { get; }
    public string? CurrentToolName { get; }
    public string? LastEventSnippet { get; }
    public DateTimeOffset? StartedAt { get; }
    public double BurnSoFarUsd { get; }
    public double? ProgressFraction { get; }
    public bool ApprovalPending { get; }

    // XAML-friendly derived surface (x:Bind can't call the static helpers on templates).
    public string PhaseLabel => MissionTilePhaseInfo.DisplayLabel(Phase);
    public bool IsProblem => MissionTilePhaseInfo.IsProblem(Phase);
    public bool IsLive => MissionTilePhaseInfo.IsLive(Phase);
    public string BurnLabel => MissionFormatting.Cost(BurnSoFarUsd, BurnSoFarUsd < 1);

    /// <summary>Progress as a 0..100 percentage for a determinate progress bar (0 when unknown).</summary>
    public double ProgressPercent => (ProgressFraction ?? 0) * 100.0;
    public bool HasSnippet => !string.IsNullOrEmpty(LastEventSnippet);
    public bool HasPhaseDetail => !string.IsNullOrEmpty(PhaseDetail);
    public bool HasToolName => !string.IsNullOrEmpty(CurrentToolName);
}

/// <summary>Category of an activity-ticker line. Mirrors
/// <c>MissionConsoleTickerEntry.Kind</c>.</summary>
public enum MissionTickerKind
{
    Status,
    ToolCall,
    ToolResult,
    LlmResponse,
    FinalAnswer,
    ChangedFile,
    Artifact,
    Error,
    Approval,
}

/// <summary>One line in the live activity ticker. Mirrors
/// <c>MissionConsoleTickerEntry</c>.</summary>
public sealed class MissionTickerEntry
{
    public MissionTickerEntry(
        string id,
        DateTimeOffset timestamp,
        MissionTickerKind kind,
        string phase,
        string? title,
        string message,
        string? toolName = null,
        string? pathDetail = null,
        string? missionId = null,
        string? runtimeId = null,
        bool isError = false)
    {
        Id = id;
        Timestamp = timestamp;
        Kind = kind;
        Phase = phase;
        Title = title;
        Message = message;
        ToolName = toolName;
        PathDetail = pathDetail;
        MissionId = missionId;
        RuntimeId = runtimeId;
        IsError = isError;
    }

    public string Id { get; }
    public DateTimeOffset Timestamp { get; }
    public MissionTickerKind Kind { get; }
    public string Phase { get; }
    public string? Title { get; }
    public string Message { get; }
    public string? ToolName { get; }
    public string? PathDetail { get; }
    public string? MissionId { get; }
    public string? RuntimeId { get; }
    public bool IsError { get; }

    public string TimeLabel => MissionFormatting.RelativeTime(Timestamp, DateTimeOffset.Now);
    public bool HasTitle => !string.IsNullOrEmpty(Title);
    public bool HasPathDetail => !string.IsNullOrEmpty(PathDetail);
}

/// <summary>An approval the captain must answer. Mirrors <c>MissionConsoleApprovalAsk</c>.</summary>
public sealed class MissionApprovalAsk
{
    public MissionApprovalAsk(
        string id,
        string missionId,
        string title,
        string message,
        string? runtimeId,
        string runtimeDisplayLabel,
        DateTimeOffset requestedAt)
    {
        Id = id;
        MissionId = missionId;
        Title = title;
        Message = message;
        RuntimeId = runtimeId;
        RuntimeDisplayLabel = runtimeDisplayLabel;
        RequestedAt = requestedAt;
    }

    public string Id { get; }
    public string MissionId { get; }
    public string Title { get; }
    public string Message { get; }
    public string? RuntimeId { get; }
    public string RuntimeDisplayLabel { get; }
    public DateTimeOffset RequestedAt { get; }

    public string RequestedLabel => MissionFormatting.RelativeTime(RequestedAt, DateTimeOffset.Now);
}

/// <summary>A pre-dispatch cost/token/ETA band. Mirrors <c>MissionConsoleForecast</c>.</summary>
public readonly struct MissionForecast : IEquatable<MissionForecast>
{
    public MissionForecast(
        int tokensLow,
        int tokensHigh,
        double costLowUsd,
        double costHighUsd,
        double etaLowSeconds,
        double etaHighSeconds)
    {
        TokensLow = tokensLow;
        TokensHigh = tokensHigh;
        CostLowUsd = costLowUsd;
        CostHighUsd = costHighUsd;
        EtaLowSeconds = etaLowSeconds;
        EtaHighSeconds = etaHighSeconds;
    }

    public int TokensLow { get; }
    public int TokensHigh { get; }
    public double CostLowUsd { get; }
    public double CostHighUsd { get; }
    public double EtaLowSeconds { get; }
    public double EtaHighSeconds { get; }

    public static MissionForecast Zero { get; } = new(0, 0, 0, 0, 0, 0);

    public string TokenRangeLabel => MissionFormatting.TokenRange(TokensLow, TokensHigh);
    public string CostRangeLabel => MissionFormatting.CostRange(CostLowUsd, CostHighUsd);
    public string EtaRangeLabel => MissionFormatting.DurationRange(EtaLowSeconds, EtaHighSeconds);

    /// <summary>Whether the projected high cost breaches the $1 amber threshold.</summary>
    public bool IsCostElevated => CostHighUsd > 1.0;

    public bool Equals(MissionForecast other) =>
        TokensLow == other.TokensLow &&
        TokensHigh == other.TokensHigh &&
        CostLowUsd.Equals(other.CostLowUsd) &&
        CostHighUsd.Equals(other.CostHighUsd) &&
        EtaLowSeconds.Equals(other.EtaLowSeconds) &&
        EtaHighSeconds.Equals(other.EtaHighSeconds);

    public override bool Equals(object? obj) => obj is MissionForecast other && Equals(other);

    public override int GetHashCode() =>
        HashCode.Combine(TokensLow, TokensHigh, CostLowUsd, CostHighUsd, EtaLowSeconds, EtaHighSeconds);

    public static bool operator ==(MissionForecast a, MissionForecast b) => a.Equals(b);

    public static bool operator !=(MissionForecast a, MissionForecast b) => !a.Equals(b);
}

/// <summary>Overall daemon/runtime state. Mirrors
/// <c>MissionConsoleSystemHealth.DaemonState</c>.</summary>
public enum DaemonState
{
    Live,
    Stale,
    MacOffline,
    Unknown,
}

/// <summary>Console header vitals. Mirrors <c>MissionConsoleSystemHealth</c>.</summary>
public sealed class MissionSystemHealth
{
    public MissionSystemHealth(
        DaemonState daemonState,
        DateTimeOffset? lastRefresh,
        int openMissions,
        int queuedMissions,
        int blockedMissions,
        double burnTodayUsd,
        double burnPerHourUsd,
        int onlineRuntimes,
        int totalRuntimes)
    {
        DaemonState = daemonState;
        LastRefresh = lastRefresh;
        OpenMissions = openMissions;
        QueuedMissions = queuedMissions;
        BlockedMissions = blockedMissions;
        BurnTodayUsd = burnTodayUsd;
        BurnPerHourUsd = burnPerHourUsd;
        OnlineRuntimes = onlineRuntimes;
        TotalRuntimes = totalRuntimes;
    }

    public DaemonState DaemonState { get; }
    public DateTimeOffset? LastRefresh { get; }
    public int OpenMissions { get; }
    public int QueuedMissions { get; }
    public int BlockedMissions { get; }
    public double BurnTodayUsd { get; }
    public double BurnPerHourUsd { get; }
    public int OnlineRuntimes { get; }
    public int TotalRuntimes { get; }

    public static MissionSystemHealth Empty { get; } = new(
        DaemonState.Unknown, null, 0, 0, 0, 0, 0, 0, 0);
}

/// <summary>The complete console read model. Mirrors <c>MissionConsoleSnapshot</c>.</summary>
public sealed class MissionConsoleSnapshot
{
    public MissionConsoleSnapshot(
        MissionSystemHealth health,
        IReadOnlyList<MissionRuntime> runtimes,
        IReadOnlyList<MissionActiveTile> activeTiles,
        IReadOnlyList<MissionTickerEntry> recentTicker,
        IReadOnlyList<MissionApprovalAsk> approvalAsks,
        IReadOnlyList<string> knownProjects,
        IReadOnlyList<string> recentProjects,
        IReadOnlyList<double>? burnHistorySpark = null)
    {
        Health = health;
        Runtimes = runtimes;
        ActiveTiles = activeTiles;
        RecentTicker = recentTicker;
        ApprovalAsks = approvalAsks;
        KnownProjects = knownProjects;
        RecentProjects = recentProjects;
        BurnHistorySpark = burnHistorySpark ?? Array.Empty<double>();
    }

    public MissionSystemHealth Health { get; }
    public IReadOnlyList<MissionRuntime> Runtimes { get; }
    public IReadOnlyList<MissionActiveTile> ActiveTiles { get; }
    public IReadOnlyList<MissionTickerEntry> RecentTicker { get; }
    public IReadOnlyList<MissionApprovalAsk> ApprovalAsks { get; }
    public IReadOnlyList<string> KnownProjects { get; }
    public IReadOnlyList<string> RecentProjects { get; }
    public IReadOnlyList<double> BurnHistorySpark { get; }

    public static MissionConsoleSnapshot Empty { get; } = new(
        MissionSystemHealth.Empty,
        Array.Empty<MissionRuntime>(),
        Array.Empty<MissionActiveTile>(),
        Array.Empty<MissionTickerEntry>(),
        Array.Empty<MissionApprovalAsk>(),
        Array.Empty<string>(),
        Array.Empty<string>());
}

/// <summary>The dispatch envelope the console emits. Mirrors
/// <c>MissionConsoleDispatchRequest</c> (Firestore-facing fields the phone attaches are
/// carried opaquely by the host, not the console draft).</summary>
public sealed class MissionDispatchRequest
{
    public MissionDispatchRequest(
        string title,
        string prompt,
        MissionKind kind,
        string runtimeId,
        string? targetProject,
        MissionDepth depth,
        MissionApprovalMode approvalMode,
        bool commandsAllowed,
        bool fileEditsAllowed,
        string? sourceSurface = null)
    {
        Title = title;
        Prompt = prompt;
        Kind = kind;
        RuntimeId = runtimeId;
        TargetProject = targetProject;
        Depth = depth;
        ApprovalMode = approvalMode;
        CommandsAllowed = commandsAllowed;
        FileEditsAllowed = fileEditsAllowed;
        SourceSurface = sourceSurface;
    }

    public string Title { get; }
    public string Prompt { get; }
    public MissionKind Kind { get; }
    public string RuntimeId { get; }
    public string? TargetProject { get; }
    public MissionDepth Depth { get; }
    public MissionApprovalMode ApprovalMode { get; }
    public bool CommandsAllowed { get; }
    public bool FileEditsAllowed { get; }
    public string? SourceSurface { get; }
}

/// <summary>The result of a dispatch. Mirrors <c>MissionConsoleDispatchOutcome</c>.</summary>
public readonly struct MissionDispatchOutcome
{
    private MissionDispatchOutcome(bool dispatched, string? missionId, string? failureMessage)
    {
        Dispatched = dispatched;
        MissionId = missionId;
        FailureMessage = failureMessage;
    }

    public bool Dispatched { get; }
    public string? MissionId { get; }
    public string? FailureMessage { get; }

    public static MissionDispatchOutcome Success(string missionId) => new(true, missionId, null);

    public static MissionDispatchOutcome Failed(string message) => new(false, null, message);
}

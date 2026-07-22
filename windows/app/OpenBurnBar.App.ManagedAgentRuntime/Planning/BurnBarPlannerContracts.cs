using System;
using System.Collections.Generic;
using System.Text.Json;

namespace OpenBurnBar.App.ManagedAgentRuntime.Planning;

public enum BurnBarAgentIntentKind
{
    ReplaceStringInFile,
    RunTerminal,
    InspectWorkspace,
    Generic,
}

public enum BurnBarToolRisk
{
    Low,
    Medium,
    High,
}

public enum BurnBarToolKind
{
    ReadFile,
    SearchWorkspace,
    ApplyPatch,
    RunTerminal,
    BrowserClick,
    BrowserFill,
    BrowserGoto,
    BrowserKey,
    BrowserSelect,
    BrowserScreenshot,
    BrowserExtract,
    MacInputClick,
    MacInputType,
    MacInputKey,
    MacInputShortcut,
    MacInputDragDrop,
    MacInputScroll,
    MacInputPointerMove,
    MacInspectAccessibility,
}

public sealed record BurnBarTextReplacement(string From, string To);

public sealed record BurnBarTerminalCommandIntent(
    string Command,
    string? Cwd = null,
    string? Name = null,
    bool? PreserveFocus = null);

public sealed record BurnBarAgentIntent(
    BurnBarAgentIntentKind Kind,
    string Objective,
    string Summary,
    string? TargetPath = null,
    string? SearchQuery = null,
    BurnBarTextReplacement? Replacement = null,
    BurnBarTerminalCommandIntent? TerminalCommand = null,
    IReadOnlyList<BurnBarToolKind>? RequestedTools = null,
    JsonElement? ToolArguments = null);

public sealed record BurnBarPlannerInput(
    int SchemaVersion,
    string MissionId,
    BurnBarAgentIntent NormalizedIntent,
    IReadOnlyList<string> Constraints,
    BurnBarToolRisk RiskLevel,
    IReadOnlyList<string> DesiredOutputs);

public enum BurnBarPlanStepStatus
{
    Pending,
    InProgress,
    Completed,
    Failed,
}

public sealed record BurnBarPlanStep(
    string Title,
    string Detail,
    BurnBarPlanStepStatus Status = BurnBarPlanStepStatus.Pending);

public sealed record BurnBarPlanOutline(
    string Objective,
    IReadOnlyList<BurnBarPlanStep> Steps);

public sealed record BurnBarPlannedRun(
    BurnBarAgentIntent Intent,
    BurnBarPlanOutline Outline,
    IReadOnlyList<string> Constraints,
    BurnBarToolRisk RiskLevel,
    IReadOnlyList<string> DesiredOutputs);

public sealed class BurnBarPlannerException : ArgumentException
{
    public BurnBarPlannerException(string code, string message)
        : base(message)
    {
        Code = string.IsNullOrWhiteSpace(code) ? "invalid_planner_input" : code;
    }

    public string Code { get; }
}

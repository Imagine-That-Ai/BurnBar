using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace OpenBurnBar.App.ManagedAgentRuntime.Planning;

internal static class BurnBarPlannerWire
{
    private static readonly IReadOnlyDictionary<string, BurnBarToolKind> ToolKinds =
        new Dictionary<string, BurnBarToolKind>(StringComparer.Ordinal)
        {
            ["read_file"] = BurnBarToolKind.ReadFile,
            ["search_workspace"] = BurnBarToolKind.SearchWorkspace,
            ["apply_patch"] = BurnBarToolKind.ApplyPatch,
            ["run_terminal"] = BurnBarToolKind.RunTerminal,
            ["browser_click"] = BurnBarToolKind.BrowserClick,
            ["browser_fill"] = BurnBarToolKind.BrowserFill,
            ["browser_goto"] = BurnBarToolKind.BrowserGoto,
            ["browser_key"] = BurnBarToolKind.BrowserKey,
            ["browser_select"] = BurnBarToolKind.BrowserSelect,
            ["browser_screenshot"] = BurnBarToolKind.BrowserScreenshot,
            ["browser_extract"] = BurnBarToolKind.BrowserExtract,
            ["mac_input_click"] = BurnBarToolKind.MacInputClick,
            ["mac_input_type"] = BurnBarToolKind.MacInputType,
            ["mac_input_key"] = BurnBarToolKind.MacInputKey,
            ["mac_input_shortcut"] = BurnBarToolKind.MacInputShortcut,
            ["mac_input_drag_drop"] = BurnBarToolKind.MacInputDragDrop,
            ["mac_input_scroll"] = BurnBarToolKind.MacInputScroll,
            ["mac_input_pointer_move"] = BurnBarToolKind.MacInputPointerMove,
            ["mac_inspect_accessibility"] = BurnBarToolKind.MacInspectAccessibility,
        };

    public static bool TryToolKind(string? value, out BurnBarToolKind kind) =>
        ToolKinds.TryGetValue(value ?? string.Empty, out kind);

    public static string ToolKind(BurnBarToolKind kind) =>
        ToolKinds.First(item => item.Value == kind).Key;

    public static BurnBarAgentIntentKind IntentKind(string value) => value switch
    {
        "replace_string_in_file" => BurnBarAgentIntentKind.ReplaceStringInFile,
        "run_terminal" => BurnBarAgentIntentKind.RunTerminal,
        "inspect_workspace" => BurnBarAgentIntentKind.InspectWorkspace,
        "generic" => BurnBarAgentIntentKind.Generic,
        _ => throw new BurnBarPlannerException("invalid_intent", $"Unsupported intent kind '{value}'."),
    };

    public static string IntentKind(BurnBarAgentIntentKind kind) => kind switch
    {
        BurnBarAgentIntentKind.ReplaceStringInFile => "replace_string_in_file",
        BurnBarAgentIntentKind.RunTerminal => "run_terminal",
        BurnBarAgentIntentKind.InspectWorkspace => "inspect_workspace",
        _ => "generic",
    };

    public static BurnBarToolRisk Risk(string value) => value switch
    {
        "low" => BurnBarToolRisk.Low,
        "medium" => BurnBarToolRisk.Medium,
        "high" => BurnBarToolRisk.High,
        _ => throw new BurnBarPlannerException("invalid_planner_input", $"Unsupported risk level '{value}'."),
    };

    public static string Risk(BurnBarToolRisk risk) => risk.ToString().ToLowerInvariant();

    public static string StepStatus(BurnBarPlanStepStatus status) => status switch
    {
        BurnBarPlanStepStatus.InProgress => "in_progress",
        _ => status.ToString().ToLowerInvariant(),
    };

    public static object PlannedRun(BurnBarPlannedRun planned) => new
    {
        intent = Intent(planned.Intent),
        outline = new
        {
            objective = planned.Outline.Objective,
            steps = planned.Outline.Steps.Select(step => new
            {
                title = step.Title,
                detail = step.Detail,
                status = StepStatus(step.Status),
            }).ToArray(),
        },
        constraints = planned.Constraints,
        riskLevel = Risk(planned.RiskLevel),
        desiredOutputs = planned.DesiredOutputs,
    };

    private static object Intent(BurnBarAgentIntent intent) => new
    {
        kind = IntentKind(intent.Kind),
        objective = intent.Objective,
        summary = intent.Summary,
        targetPath = intent.TargetPath,
        searchQuery = intent.SearchQuery,
        replacement = intent.Replacement is null
            ? null
            : new { from = intent.Replacement.From, to = intent.Replacement.To },
        terminalCommand = intent.TerminalCommand is null
            ? null
            : new
            {
                command = intent.TerminalCommand.Command,
                cwd = intent.TerminalCommand.Cwd,
                name = intent.TerminalCommand.Name,
                preserveFocus = intent.TerminalCommand.PreserveFocus,
            },
        requestedTools = intent.RequestedTools?.Select(ToolKind).ToArray(),
        toolArguments = intent.ToolArguments,
    };

    public static JsonElement CloneOrEmptyObject(JsonElement? element) =>
        element is { ValueKind: JsonValueKind.Object } value
            ? value.Clone()
            : JsonSerializer.SerializeToElement(new { });
}

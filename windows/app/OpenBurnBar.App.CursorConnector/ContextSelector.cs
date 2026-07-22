using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace OpenBurnBar.App.CursorConnector;

public enum AgentIntentKind { Generic, InspectWorkspace, ReplaceStringInFile, RunTerminal }

public sealed record TextReplacement(string From, string To);
public sealed record TerminalCommand(string Command, string? Cwd = null, string? Name = null, bool? PreserveFocus = null);

public sealed record AgentIntent(
    AgentIntentKind Kind,
    string Objective,
    string Summary,
    string? TargetPath = null,
    string? SearchQuery = null,
    TextReplacement? Replacement = null,
    TerminalCommand? Terminal = null,
    IReadOnlyList<string>? RequestedTools = null,
    JsonElement? ToolArguments = null);

public sealed record ContextSelectionState(int WorkflowStep, string? LastReadContent, bool ToolAlreadyCompleted);
public sealed record ContextAction(string Tool, JsonElement Arguments);
public sealed record AgentContextSnapshot(
    IReadOnlyList<string> CandidatePaths,
    string? ActiveFilePath,
    string? LastReadFilePath,
    string? LastReadContent,
    IReadOnlyList<string> SearchHints,
    string? ReplacementTargetPath,
    IReadOnlyList<string> SearchResultPaths);

public sealed class ContextSelector
{
    public AgentContextSnapshot MakeSnapshot(AgentIntent intent, ContextSelectionState state,
        string? lastReadFilePath, IReadOnlyList<string> searchResultPaths)
    {
        ArgumentNullException.ThrowIfNull(intent);
        var candidates = new[] { intent.TargetPath, lastReadFilePath }
            .Concat(searchResultPaths.Cast<string?>())
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Select(path => path!)
            .Distinct(StringComparer.Ordinal).ToArray();
        var hints = new[] { intent.SearchQuery, intent.Objective, intent.Summary }
            .Where(value => !string.IsNullOrWhiteSpace(value)).Select(value => value!).ToArray();
        return new AgentContextSnapshot(candidates, intent.TargetPath, lastReadFilePath, state.LastReadContent,
            hints, intent.Kind == AgentIntentKind.ReplaceStringInFile ? intent.TargetPath : null, searchResultPaths);
    }

    public ContextAction? NextAction(AgentIntent intent, ContextSelectionState state)
    {
        ArgumentNullException.ThrowIfNull(intent);
        return intent.Kind switch
        {
            AgentIntentKind.ReplaceStringInFile => NextReplacement(intent, state),
            AgentIntentKind.RunTerminal => state.ToolAlreadyCompleted ? null : new ContextAction("run_terminal", TerminalArguments(intent)),
            AgentIntentKind.InspectWorkspace => NextInspection(intent, state),
            AgentIntentKind.Generic => NextGeneric(intent, state),
            _ => throw new ArgumentOutOfRangeException(nameof(intent)),
        };
    }

    private static ContextAction? NextReplacement(AgentIntent intent, ContextSelectionState state)
    {
        if (string.IsNullOrWhiteSpace(intent.TargetPath)) throw new ArgumentException("Context selection requires a target path.");
        if (intent.Replacement is null) throw new ArgumentException("Context selection requires replacement text.");
        if (state.WorkflowStep == 0) return Action("read_file", new { path = intent.TargetPath });
        if (state.WorkflowStep != 1) return null;
        if (state.LastReadContent is null) throw new ArgumentException("Context selection requires previously-read file content.");
        string updated = state.LastReadContent.Replace(intent.Replacement.From, intent.Replacement.To, StringComparison.Ordinal);
        if (string.Equals(updated, state.LastReadContent, StringComparison.Ordinal))
            throw new ArgumentException($"Could not find '{intent.Replacement.From}' in the previously-read file.");
        return Action("apply_patch", new { changes = new[] { new { path = intent.TargetPath, text = updated } } });
    }

    private static ContextAction? NextInspection(AgentIntent intent, ContextSelectionState state)
    {
        if (state.ToolAlreadyCompleted) return null;
        if (!string.IsNullOrWhiteSpace(intent.SearchQuery)) return Action("search_workspace", new { query = intent.SearchQuery });
        return !string.IsNullOrWhiteSpace(intent.TargetPath) ? Action("read_file", new { path = intent.TargetPath }) : null;
    }

    private static ContextAction? NextGeneric(AgentIntent intent, ContextSelectionState state)
    {
        if (state.ToolAlreadyCompleted || intent.RequestedTools is not { Count: > 0 }) return null;
        string tool = intent.RequestedTools[0];
        return tool switch
        {
            "read_file" when string.IsNullOrWhiteSpace(intent.TargetPath) => throw new ArgumentException("Context selection requires a target path."),
            "read_file" => Action(tool, new { path = intent.TargetPath }),
            "search_workspace" => Action(tool, new { query = intent.SearchQuery ?? intent.Objective }),
            _ when intent.ToolArguments is JsonElement arguments => new ContextAction(tool, arguments.Clone()),
            _ => null,
        };
    }

    private static JsonElement TerminalArguments(AgentIntent intent)
    {
        if (intent.ToolArguments is JsonElement arguments) return arguments.Clone();
        if (intent.Terminal is null) return JsonSerializer.SerializeToElement(new { });
        return JsonSerializer.SerializeToElement(new
        {
            command = intent.Terminal.Command,
            cwd = intent.Terminal.Cwd,
            name = intent.Terminal.Name,
            preserveFocus = intent.Terminal.PreserveFocus,
        });
    }

    private static ContextAction Action(string tool, object arguments) =>
        new(tool, JsonSerializer.SerializeToElement(arguments));
}

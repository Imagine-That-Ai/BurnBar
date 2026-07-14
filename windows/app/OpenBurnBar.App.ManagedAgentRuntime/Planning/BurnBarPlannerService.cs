using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.ManagedAgentRuntime.Planning;

/// <summary>
/// Side-effect-free Windows composition of the macOS planner contract. It
/// normalizes request metadata into typed intent and produces deterministic
/// outlines; execution remains behind separately approved tool handlers.
/// </summary>
public sealed partial class BurnBarPlannerService
{
    private const int MaxTextCharacters = 32 * 1024;
    private const int MaxListItems = 128;

    public BurnBarPlannedRun PlanRaw(string prompt, JsonElement? metadata = null)
    {
        prompt ??= string.Empty;
        EnsureBounded(prompt, "prompt");
        JsonElement metadataObject = BurnBarPlannerWire.CloneOrEmptyObject(metadata);
        BurnBarAgentIntent intent = NormalizeIntent(prompt, metadataObject);
        return new BurnBarPlannedRun(
            intent,
            MakePlanOutline(intent),
            Array.Empty<string>(),
            BurnBarToolRisk.Low,
            Array.Empty<string>());
    }

    public BurnBarPlannedRun PlanTyped(BurnBarPlannerInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (input.Constraints.Count == 0)
        {
            throw new BurnBarPlannerException(
                "invalid_planner_input",
                "constraints cannot be empty. At least one constraint must be specified.");
        }

        if (input.DesiredOutputs.Count == 0)
        {
            throw new BurnBarPlannerException(
                "invalid_planner_input",
                "desiredOutputs cannot be empty. At least one desired output must be specified.");
        }

        if (input.SchemaVersion != 1)
        {
            throw new BurnBarPlannerException(
                "unsupported_schema_version",
                $"Planner input has unsupported schema version {input.SchemaVersion}.");
        }

        EnsureBounded(input.MissionId, "missionId");
        EnsureStringList(input.Constraints, "constraints");
        EnsureStringList(input.DesiredOutputs, "desiredOutputs");
        ValidateIntent(input.NormalizedIntent);
        return new BurnBarPlannedRun(
            input.NormalizedIntent,
            MakePlanOutline(input.NormalizedIntent),
            input.Constraints.ToArray(),
            input.RiskLevel,
            input.DesiredOutputs.ToArray());
    }

    public BurnBarPlannerInput ParseTypedInput(JsonElement input)
    {
        if (input.ValueKind != JsonValueKind.Object)
        {
            throw new BurnBarPlannerException("invalid_planner_input", "input must be an object.");
        }

        int schemaVersion = input.TryGetProperty("schemaVersion", out JsonElement schemaElement)
            && schemaElement.TryGetInt32(out int parsedSchema)
            ? parsedSchema
            : 1;
        string missionId = RequiredString(input, "missionID", "missionId");
        if (!input.TryGetProperty("normalizedIntent", out JsonElement intentElement))
        {
            throw new BurnBarPlannerException(
                "invalid_planner_input",
                "normalizedIntent is required.");
        }

        IReadOnlyList<string> constraints = StringList(input, "constraints");
        IReadOnlyList<string> desiredOutputs = StringList(input, "desiredOutputs");
        string risk = RequiredString(input, "riskLevel");
        return new BurnBarPlannerInput(
            schemaVersion,
            missionId,
            ParseIntent(intentElement, inferRequestedTools: false),
            constraints,
            BurnBarPlannerWire.Risk(risk),
            desiredOutputs);
    }

    public BurnBarAgentIntent ParseNormalizedIntent(JsonElement intent) =>
        ParseIntent(intent, inferRequestedTools: true);

    private static BurnBarAgentIntent NormalizeIntent(string prompt, JsonElement metadata)
    {
        if (metadata.TryGetProperty("agentIntent", out JsonElement explicitIntent))
        {
            return ParseIntent(explicitIntent, inferRequestedTools: true);
        }

        if (TryMetadata(metadata, "workspaceWorkflow", "workflow", out JsonElement workflow))
        {
            return IntentFromWorkflow(prompt, workflow);
        }

        if (metadata.TryGetProperty("toolKind", out JsonElement toolElement)
            && toolElement.ValueKind == JsonValueKind.String
            && BurnBarPlannerWire.TryToolKind(toolElement.GetString(), out BurnBarToolKind toolKind))
        {
            JsonElement? arguments = metadata.TryGetProperty("toolArguments", out JsonElement argumentElement)
                ? argumentElement.Clone()
                : null;
            return IntentFromTool(prompt, metadata, toolKind, arguments);
        }

        BurnBarAgentIntent? promptIntent = IntentFromPrompt(prompt, metadata);
        return promptIntent ?? new BurnBarAgentIntent(
            BurnBarAgentIntentKind.Generic,
            prompt,
            "Investigate the request, perform the next useful action, and verify the outcome.");
    }

    private static BurnBarAgentIntent IntentFromWorkflow(string prompt, JsonElement workflow)
    {
        string type = RequiredString(workflow, "type");
        if (!string.Equals(type, "replace_string_in_file", StringComparison.Ordinal))
        {
            throw new BurnBarPlannerException(
                "unsupported_workflow",
                $"Planner does not support workflow type '{type}'.");
        }

        return new BurnBarAgentIntent(
            BurnBarAgentIntentKind.ReplaceStringInFile,
            prompt,
            "Inspect the target file, replace the requested text, and verify the edit.",
            TargetPath: RequiredString(workflow, "path"),
            Replacement: new BurnBarTextReplacement(
                RequiredString(workflow, "from"),
                RequiredString(workflow, "to")),
            RequestedTools: new[] { BurnBarToolKind.ReadFile, BurnBarToolKind.ApplyPatch });
    }

    private static BurnBarAgentIntent IntentFromTool(
        string prompt,
        JsonElement metadata,
        BurnBarToolKind toolKind,
        JsonElement? arguments)
    {
        if (toolKind == BurnBarToolKind.RunTerminal)
        {
            JsonElement objectArguments = BurnBarPlannerWire.CloneOrEmptyObject(arguments);
            string command = RequiredString(objectArguments, "command");
            return new BurnBarAgentIntent(
                BurnBarAgentIntentKind.RunTerminal,
                prompt,
                "Prepare and execute the requested terminal command, then verify the outcome.",
                TerminalCommand: new BurnBarTerminalCommandIntent(
                    command,
                    OptionalString(objectArguments, "cwd"),
                    OptionalString(objectArguments, "name"),
                    OptionalBoolean(objectArguments, "preserveFocus")),
                RequestedTools: new[] { BurnBarToolKind.RunTerminal },
                ToolArguments: arguments);
        }

        if (toolKind == BurnBarToolKind.SearchWorkspace)
        {
            string? query = arguments is { ValueKind: JsonValueKind.Object } value
                ? OptionalString(value, "query")
                : null;
            return new BurnBarAgentIntent(
                BurnBarAgentIntentKind.InspectWorkspace,
                prompt,
                "Search the workspace and inspect the most relevant matches.",
                SearchQuery: query,
                RequestedTools: new[] { BurnBarToolKind.SearchWorkspace },
                ToolArguments: arguments);
        }

        return new BurnBarAgentIntent(
            BurnBarAgentIntentKind.Generic,
            prompt,
            "Execute the requested workspace tool and verify the result.",
            TargetPath: OptionalString(metadata, "filePath")
                ?? OptionalString(metadata, "path"),
            RequestedTools: new[] { toolKind },
            ToolArguments: arguments);
    }

    private static BurnBarAgentIntent ParseIntent(JsonElement element, bool inferRequestedTools)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new BurnBarPlannerException("invalid_intent", "agentIntent must be an object.");
        }

        BurnBarAgentIntentKind kind = BurnBarPlannerWire.IntentKind(RequiredString(element, "kind"));
        IReadOnlyList<BurnBarToolKind>? requestedTools = null;
        if (element.TryGetProperty("requestedTools", out JsonElement toolsElement)
            && toolsElement.ValueKind != JsonValueKind.Null)
        {
            if (toolsElement.ValueKind != JsonValueKind.Array || toolsElement.GetArrayLength() > MaxListItems)
            {
                throw new BurnBarPlannerException("invalid_intent", "requestedTools must be a bounded array.");
            }

            var tools = new List<BurnBarToolKind>();
            foreach (JsonElement toolElement in toolsElement.EnumerateArray())
            {
                if (toolElement.ValueKind != JsonValueKind.String
                    || !BurnBarPlannerWire.TryToolKind(toolElement.GetString(), out BurnBarToolKind tool))
                {
                    throw new BurnBarPlannerException("invalid_intent", "requestedTools contains an unsupported tool.");
                }

                tools.Add(tool);
            }

            requestedTools = tools;
        }
        else if (inferRequestedTools)
        {
            requestedTools = InferredRequestedTools(kind);
        }

        BurnBarTextReplacement? replacement = null;
        if (element.TryGetProperty("replacement", out JsonElement replacementElement)
            && replacementElement.ValueKind != JsonValueKind.Null)
        {
            replacement = new BurnBarTextReplacement(
                RequiredString(replacementElement, "from"),
                RequiredString(replacementElement, "to"));
        }

        BurnBarTerminalCommandIntent? terminal = null;
        if (element.TryGetProperty("terminalCommand", out JsonElement terminalElement)
            && terminalElement.ValueKind != JsonValueKind.Null)
        {
            terminal = new BurnBarTerminalCommandIntent(
                RequiredString(terminalElement, "command"),
                OptionalString(terminalElement, "cwd"),
                OptionalString(terminalElement, "name"),
                OptionalBoolean(terminalElement, "preserveFocus"));
        }

        JsonElement? toolArguments = element.TryGetProperty("toolArguments", out JsonElement argumentElement)
            ? argumentElement.Clone()
            : null;
        var intent = new BurnBarAgentIntent(
            kind,
            RequiredString(element, "objective"),
            RequiredString(element, "summary"),
            OptionalString(element, "targetPath"),
            OptionalString(element, "searchQuery"),
            replacement,
            terminal,
            requestedTools,
            toolArguments);
        ValidateIntent(intent);
        return intent;
    }

    private static BurnBarAgentIntent? IntentFromPrompt(string prompt, JsonElement metadata)
    {
        string trimmedPrompt = prompt.Trim();
        if (trimmedPrompt.Length == 0)
        {
            return null;
        }

        string? activeFilePath = OptionalString(metadata, "activeFilePath")
            ?? OptionalString(metadata, "filePath")
            ?? OptionalString(metadata, "path");
        string? selectedText = OptionalString(metadata, "activeSelectionText");
        BurnBarTextReplacement? replacement = ParseReplacement(trimmedPrompt, selectedText);
        if (replacement is not null && activeFilePath is not null)
        {
            return new BurnBarAgentIntent(
                BurnBarAgentIntentKind.ReplaceStringInFile,
                trimmedPrompt,
                "Inspect the active file, replace the requested text, and verify the edit.",
                activeFilePath,
                Replacement: replacement,
                RequestedTools: new[] { BurnBarToolKind.ReadFile, BurnBarToolKind.ApplyPatch });
        }

        string? command = FirstCapture(trimmedPrompt, TerminalPatterns());
        if (command is not null)
        {
            return new BurnBarAgentIntent(
                BurnBarAgentIntentKind.RunTerminal,
                trimmedPrompt,
                "Run the requested terminal command and verify the result.",
                TerminalCommand: new BurnBarTerminalCommandIntent(command, ParentDirectory(activeFilePath)),
                RequestedTools: new[] { BurnBarToolKind.RunTerminal });
        }

        string? query = FirstCapture(trimmedPrompt, SearchPatterns());
        if (query is not null)
        {
            return new BurnBarAgentIntent(
                BurnBarAgentIntentKind.InspectWorkspace,
                trimmedPrompt,
                "Search the workspace and inspect the most relevant files.",
                SearchQuery: query,
                RequestedTools: new[] { BurnBarToolKind.SearchWorkspace });
        }

        string lower = trimmedPrompt.ToLowerInvariant();
        if (activeFilePath is not null
            && (lower.Contains("read ", StringComparison.Ordinal)
                || lower.Contains("inspect ", StringComparison.Ordinal)
                || lower.Contains("open ", StringComparison.Ordinal)))
        {
            return new BurnBarAgentIntent(
                BurnBarAgentIntentKind.Generic,
                trimmedPrompt,
                "Read the active file and verify the relevant context.",
                activeFilePath,
                RequestedTools: new[] { BurnBarToolKind.ReadFile });
        }

        return null;
    }

    private static BurnBarTextReplacement? ParseReplacement(string prompt, string? selectedText)
    {
        foreach (Regex pattern in ReplacementPatterns())
        {
            Match match = pattern.Match(prompt);
            if (match.Success)
            {
                return new BurnBarTextReplacement(match.Groups[1].Value, match.Groups[2].Value);
            }
        }

        Match selectedMatch = SelectionReplacementPattern().Match(prompt);
        return !string.IsNullOrEmpty(selectedText) && selectedMatch.Success
            ? new BurnBarTextReplacement(selectedText, selectedMatch.Groups[1].Value)
            : null;
    }

    private static string? FirstCapture(string input, IEnumerable<Regex> patterns)
    {
        foreach (Regex pattern in patterns)
        {
            Match match = pattern.Match(input);
            if (match.Success && !string.IsNullOrWhiteSpace(match.Groups[1].Value))
            {
                return match.Groups[1].Value.Trim();
            }
        }

        return null;
    }

    private static BurnBarPlanOutline MakePlanOutline(BurnBarAgentIntent intent)
    {
        (string Title, string Detail)[] steps = intent.Kind switch
        {
            BurnBarAgentIntentKind.ReplaceStringInFile => new[]
            {
                ("Inspect target file", "Read the target file and confirm the existing text before editing."),
                ("Apply requested edit", "Replace the requested text in the target file using the workspace companion."),
                ("Verify result", "Confirm the replacement was applied and the run can complete safely."),
            },
            BurnBarAgentIntentKind.RunTerminal => new[]
            {
                ("Prepare terminal action", "Check the command intent, working directory, and approval requirements."),
                ("Execute command", "Run the terminal command through the workspace companion."),
                ("Verify outcome", "Capture the result and confirm the run can continue or complete."),
            },
            BurnBarAgentIntentKind.InspectWorkspace => new[]
            {
                ("Search the workspace", "Search for the highest-signal files and symbols related to the request."),
                ("Inspect relevant context", "Read the most relevant files before taking any follow-up action."),
                ("Summarize findings", "Use the gathered context to decide the next explicit action or final answer."),
            },
            _ => new[]
            {
                ("Understand the request", "Inspect the minimum relevant context needed to avoid guessing."),
                ("Execute the next action", "Use the appropriate tool or model step to make concrete progress."),
                ("Verify completion", "Confirm the requested outcome was achieved before finalizing the run."),
            },
        };
        return new BurnBarPlanOutline(
            intent.Objective,
            steps.Select(step => new BurnBarPlanStep(step.Title, step.Detail)).ToArray());
    }

    private static IReadOnlyList<BurnBarToolKind> InferredRequestedTools(BurnBarAgentIntentKind kind) => kind switch
    {
        BurnBarAgentIntentKind.InspectWorkspace => new[] { BurnBarToolKind.SearchWorkspace },
        BurnBarAgentIntentKind.ReplaceStringInFile => new[] { BurnBarToolKind.ReadFile, BurnBarToolKind.ApplyPatch },
        BurnBarAgentIntentKind.RunTerminal => new[] { BurnBarToolKind.RunTerminal },
        _ => Array.Empty<BurnBarToolKind>(),
    };

    private static void ValidateIntent(BurnBarAgentIntent intent)
    {
        EnsureBounded(intent.Objective, "objective");
        EnsureBounded(intent.Summary, "summary");
        if (intent.TargetPath is not null) EnsureBounded(intent.TargetPath, "targetPath");
        if (intent.SearchQuery is not null) EnsureBounded(intent.SearchQuery, "searchQuery");
        if (intent.Replacement is not null)
        {
            EnsureBounded(intent.Replacement.From, "replacement.from");
            EnsureBounded(intent.Replacement.To, "replacement.to");
        }
        if (intent.TerminalCommand is not null)
        {
            EnsureBounded(intent.TerminalCommand.Command, "terminalCommand.command");
            if (intent.TerminalCommand.Cwd is not null) EnsureBounded(intent.TerminalCommand.Cwd, "terminalCommand.cwd");
        }
    }

    private static IReadOnlyList<string> StringList(JsonElement parent, string property)
    {
        if (!parent.TryGetProperty(property, out JsonElement array) || array.ValueKind != JsonValueKind.Array)
        {
            throw new BurnBarPlannerException("invalid_planner_input", $"{property} must be an array.");
        }
        if (array.GetArrayLength() > MaxListItems)
        {
            throw new BurnBarPlannerException("invalid_planner_input", $"{property} exceeds the item limit.");
        }

        var values = new List<string>();
        foreach (JsonElement item in array.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(item.GetString()))
            {
                throw new BurnBarPlannerException("invalid_planner_input", $"{property} entries must be non-empty strings.");
            }
            string value = item.GetString()!;
            EnsureBounded(value, property);
            values.Add(value);
        }
        return values;
    }

    private static string RequiredString(JsonElement parent, params string[] properties)
    {
        foreach (string property in properties)
        {
            string? value = OptionalString(parent, property);
            if (value is not null) return value;
        }
        throw new BurnBarPlannerException("invalid_planner_input", $"{properties[0]} is required.");
    }

    private static string? OptionalString(JsonElement parent, string property)
    {
        if (parent.ValueKind != JsonValueKind.Object
            || !parent.TryGetProperty(property, out JsonElement value)
            || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(value.GetString()))
        {
            throw new BurnBarPlannerException("invalid_planner_input", $"{property} must be a non-empty string.");
        }
        string result = value.GetString()!;
        EnsureBounded(result, property);
        return result;
    }

    private static bool? OptionalBoolean(JsonElement parent, string property)
    {
        if (!parent.TryGetProperty(property, out JsonElement value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new BurnBarPlannerException("invalid_planner_input", $"{property} must be a boolean.");
        }
        return value.GetBoolean();
    }

    private static bool TryMetadata(JsonElement metadata, string first, string second, out JsonElement value)
    {
        if (metadata.TryGetProperty(first, out value)) return true;
        return metadata.TryGetProperty(second, out value);
    }

    private static void EnsureStringList(IReadOnlyList<string> values, string name)
    {
        if (values.Count > MaxListItems)
        {
            throw new BurnBarPlannerException("invalid_planner_input", $"{name} exceeds the item limit.");
        }
        foreach (string value in values)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new BurnBarPlannerException("invalid_planner_input", $"{name} entries must be non-empty.");
            }
            EnsureBounded(value, name);
        }
    }

    private static void EnsureBounded(string value, string name)
    {
        if (value.Length > MaxTextCharacters)
        {
            throw new BurnBarPlannerException("invalid_planner_input", $"{name} exceeds the safety limit.");
        }
    }

    private static string? ParentDirectory(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        int separator = Math.Max(path.LastIndexOf('/'), path.LastIndexOf('\\'));
        return separator <= 0 ? null : path[..separator];
    }

    [GeneratedRegex("(?i)\\breplace\\s+[\"']([^\"']+)[\"']\\s+with\\s+[\"']([^\"']+)[\"']", RegexOptions.CultureInvariant, 250)]
    private static partial Regex ReplacePattern();

    [GeneratedRegex("(?i)\\bchange\\s+[\"']([^\"']+)[\"']\\s+to\\s+[\"']([^\"']+)[\"']", RegexOptions.CultureInvariant, 250)]
    private static partial Regex ChangePattern();

    [GeneratedRegex("(?i)\\bchange\\s+(?:it|this|selection|this selection)\\s+to\\s+[\"']([^\"']+)[\"']", RegexOptions.CultureInvariant, 250)]
    private static partial Regex SelectionReplacementPattern();

    [GeneratedRegex("(?i)^\\s*run\\s+(.+)$", RegexOptions.CultureInvariant, 250)]
    private static partial Regex RunPattern();

    [GeneratedRegex("(?i)^\\s*execute\\s+(.+)$", RegexOptions.CultureInvariant, 250)]
    private static partial Regex ExecutePattern();

    [GeneratedRegex("(?i)\\bsearch\\s+for\\s+(.+)$", RegexOptions.CultureInvariant, 250)]
    private static partial Regex SearchPattern();

    [GeneratedRegex("(?i)\\bfind\\s+(.+)$", RegexOptions.CultureInvariant, 250)]
    private static partial Regex FindPattern();

    [GeneratedRegex("(?i)\\blook\\s+for\\s+(.+)$", RegexOptions.CultureInvariant, 250)]
    private static partial Regex LookPattern();

    private static IEnumerable<Regex> ReplacementPatterns() => new[] { ReplacePattern(), ChangePattern() };
    private static IEnumerable<Regex> TerminalPatterns() => new[] { RunPattern(), ExecutePattern() };
    private static IEnumerable<Regex> SearchPatterns() => new[] { SearchPattern(), FindPattern(), LookPattern() };
}

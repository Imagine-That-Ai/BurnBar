using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;

namespace OpenBurnBar.App.ManagedAgentRuntime.Run;

public sealed record HeadlessAgentLoopOutcome(
    HeadlessAgentLoopDecision Decision,
    IReadOnlyList<ModelCompletionResult> ProviderResults);

public sealed class HeadlessAgentLoopService
{
    public const int DefaultMaximumIterations = 8;
    public const int MaximumDecisionCharacters = 1024 * 1024;
    public const int MaximumArgumentBytes = 256 * 1024;
    public const int MaximumRationaleCharacters = 32 * 1024;
    public const int MaximumContextCharacters = 256 * 1024;

    private readonly int _maximumIterations;

    public HeadlessAgentLoopService(int maximumIterations = DefaultMaximumIterations)
    {
        if (maximumIterations is < 1 or > 64)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumIterations));
        }
        _maximumIterations = maximumIterations;
    }

    public async Task<HeadlessAgentLoopOutcome> DecideNextActionAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        HeadlessAgentContextSnapshot context,
        IReadOnlyList<HeadlessRunJournalEntry> journalTail,
        ModelRoute route,
        IModelCompletionExecutor executor,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(checkpoint);
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(journalTail);
        ArgumentNullException.ThrowIfNull(route);
        ArgumentNullException.ThrowIfNull(executor);
        if (checkpoint.LoopState.IterationCount >= _maximumIterations)
        {
            throw new HeadlessAgentRunException(
                "agent_loop_max_iterations",
                $"The headless agent exceeded {_maximumIterations} model decisions.");
        }

        string prompt = BuildPrompt(checkpoint, context, journalTail);
        ModelCompletionResult first = await CompleteAsync(
            route,
            executor,
            prompt,
            repairMode: false,
            cancellationToken).ConfigureAwait(false);
        var results = new List<ModelCompletionResult> { first };
        if (!first.Succeeded)
        {
            return new HeadlessAgentLoopOutcome(FailureForProvider(first.StatusCode), results);
        }
        string firstOutput = ExtractAssistantText(first.Body);
        if (TryParseDecision(firstOutput, context, checkpoint.LoopState, out HeadlessAgentLoopDecision? decision))
        {
            return new HeadlessAgentLoopOutcome(decision!, results);
        }

        ModelCompletionResult repaired = await CompleteAsync(
            route,
            executor,
            prompt,
            repairMode: true,
            cancellationToken).ConfigureAwait(false);
        results.Add(repaired);
        if (!repaired.Succeeded)
        {
            return new HeadlessAgentLoopOutcome(FailureForProvider(repaired.StatusCode), results);
        }
        string repairedOutput = ExtractAssistantText(repaired.Body);
        if (TryParseDecision(repairedOutput, context, checkpoint.LoopState, out decision))
        {
            return new HeadlessAgentLoopOutcome(decision!, results);
        }

        return new HeadlessAgentLoopOutcome(new HeadlessAgentLoopDecision(
            HeadlessAgentLoopAction.Fail,
            null,
            null,
            "The model returned invalid single-action JSON after one repair attempt.",
            "OpenBurnBar could not validate the model's next action."), results);
    }

    private static Task<ModelCompletionResult> CompleteAsync(
        ModelRoute route,
        IModelCompletionExecutor executor,
        string prompt,
        bool repairMode,
        CancellationToken cancellationToken)
    {
        string system = SystemPrompt(repairMode);
        byte[] body = JsonSerializer.SerializeToUtf8Bytes(new
        {
            model = route.Model,
            messages = new[]
            {
                new { role = "system", content = system },
                new { role = "user", content = prompt },
            },
            response_format = new { type = "json_object" },
            temperature = 0,
            max_tokens = 2048,
            stream = false,
        });
        return executor.ExecuteAsync(route, body, cancellationToken);
    }

    private static string SystemPrompt(bool repairMode)
    {
        const string prompt = """
            You are OpenBurnBar's daemon-side coding agent loop.
            Respond with exactly one JSON object and no surrounding prose.
            Allowed actions:
            - complete
            - search_workspace
            - read_file
            - apply_patch
            - run_terminal
            - browser_goto
            - browser_click
            - browser_fill
            - browser_key
            - browser_select
            - browser_screenshot
            - browser_extract
            - request_approval
            - fail

            Required keys:
            - action
            - rationale
            Optional keys:
            - requestedTool
            - arguments
            - message

            Browser action arguments:
            - browser_goto: {"url":"https://example.com"}
            - browser_click: {"selector":"button[type=submit]"} or {"positionX":100,"positionY":200}
            - browser_fill: {"selector":"input[name=q]","text":"query"}
            - browser_key: {"key":"Enter"}
            - browser_select: {"selector":"select","value":"option"}
            - browser_screenshot: {}
            - browser_extract: {"selector":"main"} or {}
            """;
        return repairMode
            ? prompt + "\nYour previous response was invalid. Output strict JSON only."
            : prompt;
    }

    private static string BuildPrompt(
        HeadlessAgentRunCheckpoint checkpoint,
        HeadlessAgentContextSnapshot context,
        IReadOnlyList<HeadlessRunJournalEntry> journalTail)
    {
        string plan = string.Join("\n", checkpoint.PlanOutline.Steps.Select((step, index) =>
            $"{index + 1}. [{BurnBarPlannerWire.StepStatus(step.Status)}] {step.Title}: {step.Detail}"));
        string recent = string.Join("\n", journalTail
            .Where(entry => entry.RunId == checkpoint.RunId)
            .TakeLast(6)
            .Select(entry => $"{entry.StepId ?? "state"} @ {entry.State}"));
        string readContent = Bound(context.LastReadContent ?? "none", MaximumContextCharacters);
        return $"""
            Objective:
            {checkpoint.OriginalPrompt}

            Intent:
            {checkpoint.Intent.Summary}

            Plan:
            {plan}

            Loop iteration:
            {checkpoint.LoopState.IterationCount}

            Context:
            Candidate paths: {string.Join(", ", context.CandidatePaths)}
            Active file: {context.ActiveFilePath ?? "none"}
            Last read file: {context.LastReadFilePath ?? "none"}
            Last read content:
            {readContent}
            Search hints: {string.Join(" | ", context.SearchHints)}
            Search result paths: {string.Join(", ", context.SearchResultPaths)}

            Recent journal:
            {(recent.Length == 0 ? "none" : recent)}
            """;
    }

    internal static bool TryParseDecision(
        string rawOutput,
        HeadlessAgentContextSnapshot context,
        HeadlessAgentLoopState loopState,
        out HeadlessAgentLoopDecision? decision)
    {
        decision = null;
        if (string.IsNullOrWhiteSpace(rawOutput) || rawOutput.Length > MaximumDecisionCharacters)
        {
            return false;
        }
        string? json = ExtractJsonObject(rawOutput);
        if (json is null) return false;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !TryRequiredString(root, "action", out string? rawAction)
                || !TryRequiredString(root, "rationale", out string? rationale)
                || rationale!.Length > MaximumRationaleCharacters
                || !TryAction(rawAction!, out HeadlessAgentLoopAction action))
            {
                return false;
            }
            string? message = OptionalString(root, "message");
            if (message?.Length > MaximumRationaleCharacters) return false;
            BurnBarToolKind? requestedTool = null;
            string? rawTool = OptionalString(root, "requestedTool");
            if (rawTool is not null)
            {
                if (!BurnBarPlannerWire.TryToolKind(rawTool, out BurnBarToolKind parsedTool)) return false;
                requestedTool = parsedTool;
            }
            JsonElement? arguments = null;
            if (root.TryGetProperty("arguments", out JsonElement argumentElement)
                && argumentElement.ValueKind != JsonValueKind.Null)
            {
                if (argumentElement.ValueKind != JsonValueKind.Object
                    || Encoding.UTF8.GetByteCount(argumentElement.GetRawText()) > MaximumArgumentBytes)
                {
                    return false;
                }
                arguments = argumentElement.Clone();
            }

            if (!NormalizeAndValidate(
                    action,
                    requestedTool,
                    arguments,
                    context,
                    out BurnBarToolKind? normalizedTool,
                    out JsonElement? normalizedArguments))
            {
                return false;
            }
            if (action == HeadlessAgentLoopAction.SearchWorkspace
                && Query(normalizedArguments) == Query(loopState.LastDecision?.Arguments)
                && context.SearchResultPaths.SequenceEqual(
                    loopState.LastContextSnapshot?.SearchResultPaths ?? Array.Empty<string>(),
                    StringComparer.Ordinal)
                && loopState.IterationCount >= 2)
            {
                decision = new HeadlessAgentLoopDecision(
                    HeadlessAgentLoopAction.Fail,
                    null,
                    null,
                    "Repeated identical search with no new context.",
                    "OpenBurnBar detected repeated search churn without new progress.");
                return true;
            }
            decision = new HeadlessAgentLoopDecision(
                action,
                normalizedTool,
                normalizedArguments,
                rationale,
                message);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool NormalizeAndValidate(
        HeadlessAgentLoopAction action,
        BurnBarToolKind? requestedTool,
        JsonElement? arguments,
        HeadlessAgentContextSnapshot context,
        out BurnBarToolKind? normalizedTool,
        out JsonElement? normalizedArguments)
    {
        normalizedTool = requestedTool ?? ToolFor(action);
        normalizedArguments = arguments;
        switch (action)
        {
            case HeadlessAgentLoopAction.SearchWorkspace:
                return HasString(arguments, "query");
            case HeadlessAgentLoopAction.ReadFile:
                string? path = String(arguments, "path")
                    ?? context.ActiveFilePath
                    ?? context.CandidatePaths.FirstOrDefault();
                if (path is null) return false;
                normalizedTool = BurnBarToolKind.ReadFile;
                normalizedArguments = JsonSerializer.SerializeToElement(new { path });
                return true;
            case HeadlessAgentLoopAction.ApplyPatch:
                return HasProperty(arguments, "changes");
            case HeadlessAgentLoopAction.RunTerminal:
                return HasString(arguments, "command");
            case HeadlessAgentLoopAction.BrowserGoto:
                return HasString(arguments, "url");
            case HeadlessAgentLoopAction.BrowserClick:
                return HasString(arguments, "selector")
                    || (HasInt(arguments, "positionX") && HasInt(arguments, "positionY"));
            case HeadlessAgentLoopAction.BrowserFill:
                return HasString(arguments, "selector") && HasString(arguments, "text");
            case HeadlessAgentLoopAction.BrowserKey:
                return HasString(arguments, "key");
            case HeadlessAgentLoopAction.BrowserSelect:
                return HasString(arguments, "selector") && HasString(arguments, "value");
            case HeadlessAgentLoopAction.BrowserScreenshot:
            case HeadlessAgentLoopAction.BrowserExtract:
                normalizedArguments ??= JsonSerializer.SerializeToElement(new { });
                return true;
            case HeadlessAgentLoopAction.RequestApproval:
                return requestedTool is not null;
            case HeadlessAgentLoopAction.Complete:
            case HeadlessAgentLoopAction.Fail:
                return true;
            default:
                return false;
        }
    }

    private static BurnBarToolKind? ToolFor(HeadlessAgentLoopAction action) => action switch
    {
        HeadlessAgentLoopAction.SearchWorkspace => BurnBarToolKind.SearchWorkspace,
        HeadlessAgentLoopAction.ReadFile => BurnBarToolKind.ReadFile,
        HeadlessAgentLoopAction.ApplyPatch => BurnBarToolKind.ApplyPatch,
        HeadlessAgentLoopAction.RunTerminal => BurnBarToolKind.RunTerminal,
        HeadlessAgentLoopAction.BrowserClick => BurnBarToolKind.BrowserClick,
        HeadlessAgentLoopAction.BrowserFill => BurnBarToolKind.BrowserFill,
        HeadlessAgentLoopAction.BrowserGoto => BurnBarToolKind.BrowserGoto,
        HeadlessAgentLoopAction.BrowserKey => BurnBarToolKind.BrowserKey,
        HeadlessAgentLoopAction.BrowserSelect => BurnBarToolKind.BrowserSelect,
        HeadlessAgentLoopAction.BrowserScreenshot => BurnBarToolKind.BrowserScreenshot,
        HeadlessAgentLoopAction.BrowserExtract => BurnBarToolKind.BrowserExtract,
        _ => null,
    };

    internal static string ExtractAssistantText(byte[] body)
    {
        if (body.Length == 0) return string.Empty;
        string raw = Encoding.UTF8.GetString(body);
        if (raw.Length > MaximumDecisionCharacters) return string.Empty;
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            JsonElement root = document.RootElement;
            if (root.TryGetProperty("choices", out JsonElement choices)
                && choices.ValueKind == JsonValueKind.Array
                && choices.GetArrayLength() > 0)
            {
                JsonElement first = choices[0];
                if (first.TryGetProperty("message", out JsonElement message)
                    && message.TryGetProperty("content", out JsonElement content))
                {
                    return ContentText(content);
                }
                if (first.TryGetProperty("text", out JsonElement text)
                    && text.ValueKind == JsonValueKind.String)
                {
                    return text.GetString() ?? string.Empty;
                }
            }
        }
        catch (JsonException)
        {
            return raw;
        }
        return raw;
    }

    private static string ContentText(JsonElement content)
    {
        if (content.ValueKind == JsonValueKind.String) return content.GetString() ?? string.Empty;
        if (content.ValueKind != JsonValueKind.Array) return string.Empty;
        var parts = new List<string>();
        foreach (JsonElement item in content.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.Object
                && item.TryGetProperty("text", out JsonElement text)
                && text.ValueKind == JsonValueKind.String)
            {
                parts.Add(text.GetString() ?? string.Empty);
            }
        }
        return string.Join("\n", parts);
    }

    private static HeadlessAgentLoopDecision FailureForProvider(int statusCode) => new(
        HeadlessAgentLoopAction.Fail,
        null,
        null,
        $"The selected provider returned status {statusCode}.",
        $"OpenBurnBar's model provider is unavailable (HTTP {statusCode}).");

    private static string? ExtractJsonObject(string output)
    {
        int start = output.IndexOf('{');
        if (start < 0) return null;
        int depth = 0;
        bool inString = false;
        bool escaped = false;
        for (int index = start; index < output.Length; index++)
        {
            char value = output[index];
            if (inString)
            {
                if (escaped) escaped = false;
                else if (value == '\\') escaped = true;
                else if (value == '"') inString = false;
                continue;
            }
            if (value == '"') inString = true;
            else if (value == '{') depth++;
            else if (value == '}' && --depth == 0) return output[start..(index + 1)];
        }
        return null;
    }

    private static bool TryAction(string value, out HeadlessAgentLoopAction action)
    {
        action = value switch
        {
            "complete" => HeadlessAgentLoopAction.Complete,
            "search_workspace" => HeadlessAgentLoopAction.SearchWorkspace,
            "read_file" => HeadlessAgentLoopAction.ReadFile,
            "apply_patch" => HeadlessAgentLoopAction.ApplyPatch,
            "run_terminal" => HeadlessAgentLoopAction.RunTerminal,
            "browser_click" => HeadlessAgentLoopAction.BrowserClick,
            "browser_fill" => HeadlessAgentLoopAction.BrowserFill,
            "browser_goto" => HeadlessAgentLoopAction.BrowserGoto,
            "browser_key" => HeadlessAgentLoopAction.BrowserKey,
            "browser_select" => HeadlessAgentLoopAction.BrowserSelect,
            "browser_screenshot" => HeadlessAgentLoopAction.BrowserScreenshot,
            "browser_extract" => HeadlessAgentLoopAction.BrowserExtract,
            "request_approval" => HeadlessAgentLoopAction.RequestApproval,
            "fail" => HeadlessAgentLoopAction.Fail,
            _ => (HeadlessAgentLoopAction)(-1),
        };
        return (int)action >= 0;
    }

    private static bool TryRequiredString(JsonElement parent, string property, out string? value)
    {
        value = OptionalString(parent, property);
        return value is not null;
    }

    private static string? OptionalString(JsonElement parent, string property) =>
        parent.TryGetProperty(property, out JsonElement value)
        && value.ValueKind == JsonValueKind.String
        && !string.IsNullOrWhiteSpace(value.GetString())
            ? value.GetString()!.Trim()
            : null;

    private static bool HasProperty(JsonElement? arguments, string property) =>
        arguments is { ValueKind: JsonValueKind.Object } value && value.TryGetProperty(property, out _);

    private static bool HasString(JsonElement? arguments, string property) => String(arguments, property) is not null;

    private static string? String(JsonElement? arguments, string property) =>
        arguments is { ValueKind: JsonValueKind.Object } value
        && value.TryGetProperty(property, out JsonElement item)
        && item.ValueKind == JsonValueKind.String
        && !string.IsNullOrWhiteSpace(item.GetString())
            ? item.GetString()
            : null;

    private static bool HasInt(JsonElement? arguments, string property) =>
        arguments is { ValueKind: JsonValueKind.Object } value
        && value.TryGetProperty(property, out JsonElement item)
        && item.TryGetInt32(out _);

    private static string? Query(JsonElement? arguments) => String(arguments, "query");

    private static string Bound(string value, int maximumCharacters) =>
        value.Length <= maximumCharacters ? value : value[..maximumCharacters];
}

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;

namespace OpenBurnBar.App.ManagedAgentRuntime.Run;

public sealed partial class HeadlessAgentRunService
{
    private const int MaximumProviderFailovers = 3;
    private const int MaximumContextPaths = 128;

    private async Task ProcessRunAsync(string runId, CancellationToken cancellationToken)
    {
        SemaphoreSlim gate = RunGate(runId);
        HeadlessAgentRunCheckpoint? modelCheckpoint = null;
        HeadlessAgentContextSnapshot? modelContext = null;
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            HeadlessAgentRunCheckpoint checkpoint = await RequireRunAsync(runId, cancellationToken).ConfigureAwait(false);
            if (HeadlessAgentRunStateMachine.IsTerminal(checkpoint.Phase)
                || checkpoint.Phase is HeadlessAgentRunPhase.AwaitingApproval
                    or HeadlessAgentRunPhase.WaitingOnCompanion)
            {
                return;
            }

            if (checkpoint.Phase != HeadlessAgentRunPhase.ModelStreaming)
            {
                checkpoint = await ContinueExecutionLockedAsync(checkpoint, cancellationToken).ConfigureAwait(false);
            }
            if (checkpoint.Phase == HeadlessAgentRunPhase.ModelStreaming)
            {
                modelCheckpoint = checkpoint;
                modelContext = CurrentContext(checkpoint);
            }
        }
        finally
        {
            gate.Release();
        }

        if (modelCheckpoint is not null && modelContext is not null)
        {
            await ExecuteModelDecisionAsync(modelCheckpoint, modelContext, cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task<HeadlessAgentRunCheckpoint> ContinueExecutionLockedAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        CancellationToken cancellationToken)
    {
        if (checkpoint.RequiresApproval
            && !checkpoint.RunLevelApprovalCompleted
            && checkpoint.ApprovalRequest is null)
        {
            BurnBarToolKind tool = checkpoint.Intent.RequestedTools is { Count: > 0 } tools
                ? tools[^1]
                : BurnBarToolKind.ApplyPatch;
            checkpoint = RequestApproval(
                checkpoint,
                tool,
                $"Approve {BurnBarPlannerWire.ToolKind(tool)}",
                _policy.ApprovalDescriptor(true, checkpoint.Intent, tool)?.Message
                    ?? "OpenBurnBar requires approval before continuing.",
                pendingInvocation: null);
            await PersistAsync(checkpoint, "approval_requested", cancellationToken).ConfigureAwait(false);
            return checkpoint;
        }

        switch (checkpoint.Intent.Kind)
        {
            case BurnBarAgentIntentKind.ReplaceStringInFile:
                return await ContinueReplacementAsync(checkpoint, cancellationToken).ConfigureAwait(false);
            case BurnBarAgentIntentKind.RunTerminal:
                if (checkpoint.CompanionToolCompleted)
                {
                    return await CompleteAsync(checkpoint, cancellationToken).ConfigureAwait(false);
                }
                return await QueueToolAsync(
                    checkpoint,
                    BurnBarToolKind.RunTerminal,
                    TerminalArguments(checkpoint.Intent),
                    cancellationToken).ConfigureAwait(false);
            case BurnBarAgentIntentKind.InspectWorkspace:
                if (checkpoint.WorkflowStep == 0
                    && checkpoint.Intent.RequestedTools is { Count: > 0 } inspectTools
                    && checkpoint.Intent.ToolArguments is JsonElement inspectArguments)
                {
                    return await QueueToolAsync(
                        checkpoint,
                        inspectTools[0],
                        inspectArguments,
                        cancellationToken).ConfigureAwait(false);
                }
                break;
            case BurnBarAgentIntentKind.Generic:
                if (checkpoint.Intent.RequestedTools is { Count: 1 } genericTools
                    && checkpoint.Intent.ToolArguments is JsonElement genericArguments)
                {
                    if (checkpoint.CompanionToolCompleted)
                    {
                        return await CompleteAsync(checkpoint, cancellationToken).ConfigureAwait(false);
                    }
                    return await QueueToolAsync(
                        checkpoint,
                        genericTools[0],
                        genericArguments,
                        cancellationToken).ConfigureAwait(false);
                }
                break;
        }

        checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.ModelStreaming);
        await PersistAsync(checkpoint, "model_started", cancellationToken).ConfigureAwait(false);
        return checkpoint;
    }

    private async Task<HeadlessAgentRunCheckpoint> ContinueReplacementAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        CancellationToken cancellationToken)
    {
        string path = checkpoint.Intent.TargetPath
            ?? throw new HeadlessAgentRunException("replacement_path_missing", "The replacement workflow has no target path.");
        BurnBarTextReplacement replacement = checkpoint.Intent.Replacement
            ?? throw new HeadlessAgentRunException("replacement_missing", "The replacement workflow has no replacement text.");
        if (checkpoint.WorkflowStep == 0)
        {
            return await QueueToolAsync(
                checkpoint,
                BurnBarToolKind.ReadFile,
                JsonSerializer.SerializeToElement(new { path }),
                cancellationToken).ConfigureAwait(false);
        }
        if (checkpoint.WorkflowStep == 1)
        {
            string content = checkpoint.WorkflowReadContent
                ?? throw new HeadlessAgentRunException("replacement_content_missing", "The replacement workflow has no file content.");
            int first = content.IndexOf(replacement.From, StringComparison.Ordinal);
            if (first < 0)
            {
                throw new HeadlessAgentRunException("replacement_text_not_found", "The requested source text was not found in the target file.");
            }
            if (content.IndexOf(replacement.From, first + replacement.From.Length, StringComparison.Ordinal) >= 0)
            {
                throw new HeadlessAgentRunException("replacement_text_ambiguous", "The requested source text appears more than once in the target file.");
            }
            string updated = content[..first] + replacement.To + content[(first + replacement.From.Length)..];
            JsonElement arguments = JsonSerializer.SerializeToElement(new
            {
                changes = new[] { new { path, content = updated } },
            });
            return await QueueToolAsync(checkpoint, BurnBarToolKind.ApplyPatch, arguments, cancellationToken)
                .ConfigureAwait(false);
        }
        return await CompleteAsync(checkpoint, cancellationToken).ConfigureAwait(false);
    }

    private async Task ExecuteModelDecisionAsync(
        HeadlessAgentRunCheckpoint modelCheckpoint,
        HeadlessAgentContextSnapshot context,
        CancellationToken cancellationToken)
    {
        IReadOnlyList<HeadlessRunJournalEntry> allJournal = await _journal
            .ReadAllAsync(cancellationToken)
            .ConfigureAwait(false);
        HeadlessAgentLoopOutcome? outcome = null;
        var attemptedRoutes = new HashSet<string>(StringComparer.Ordinal);
        for (int failover = 0; failover < MaximumProviderFailovers; failover++)
        {
            ModelRouteDecision selection = _router.SelectForModel(modelCheckpoint.ModelId, allowDegrade: false);
            if (selection.FailedClosed || !selection.Route.IsExecutable || !attemptedRoutes.Add(selection.Route.Id))
            {
                break;
            }
            DateTimeOffset startedAt = _now();
            outcome = await _loop.DecideNextActionAsync(
                modelCheckpoint,
                context,
                allJournal,
                selection.Route,
                _executor,
                cancellationToken).ConfigureAwait(false);
            foreach (ModelCompletionResult result in outcome.ProviderResults)
            {
                _router.RecordOutcome(selection.Route, result, selection.Degraded);
                RecordProviderTelemetry(startedAt, modelCheckpoint.ModelId, selection, result);
                startedAt = _now();
            }
            if (outcome.ProviderResults.Count > 0 && outcome.ProviderResults.All(result => result.Succeeded))
            {
                break;
            }
            outcome = null;
        }

        HeadlessAgentLoopDecision decision = outcome?.Decision ?? new HeadlessAgentLoopDecision(
            HeadlessAgentLoopAction.Fail,
            null,
            null,
            "No healthy exact-model provider route completed the decision request.",
            "OpenBurnBar could not reach a healthy provider for the requested model.");

        SemaphoreSlim gate = RunGate(modelCheckpoint.RunId);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            HeadlessAgentRunCheckpoint checkpoint = await RequireRunAsync(modelCheckpoint.RunId, cancellationToken)
                .ConfigureAwait(false);
            if (checkpoint.Phase != HeadlessAgentRunPhase.ModelStreaming)
            {
                return;
            }
            checkpoint = checkpoint with
            {
                LoopState = new HeadlessAgentLoopState(
                    checkpoint.LoopState.IterationCount + 1,
                    decision,
                    context,
                    decision.RequestedTool ?? checkpoint.LoopState.LastExecutedTool,
                    decision.Action == HeadlessAgentLoopAction.RunTerminal),
            };
            await ApplyModelDecisionLockedAsync(checkpoint, decision, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<HeadlessAgentRunCheckpoint> ApplyModelDecisionLockedAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        HeadlessAgentLoopDecision decision,
        CancellationToken cancellationToken)
    {
        switch (decision.Action)
        {
            case HeadlessAgentLoopAction.Complete:
                return await CompleteAsync(checkpoint, cancellationToken).ConfigureAwait(false);
            case HeadlessAgentLoopAction.Fail:
                checkpoint = checkpoint with
                {
                    ErrorMessage = Bound(
                        decision.Message ?? "OpenBurnBar's agent loop reported an unrecoverable failure.",
                        MaximumPromptCharacters),
                };
                checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Failed);
                await PersistAsync(checkpoint, "run_failed", cancellationToken, "agent_loop_failed").ConfigureAwait(false);
                return checkpoint;
            case HeadlessAgentLoopAction.RequestApproval:
                if (!_policy.ShouldHonorModelRequestedApproval(decision.RequestedTool)
                    || decision.RequestedTool is null)
                {
                    checkpoint = checkpoint with
                    {
                        ErrorMessage = "The model requested approval for an unsupported or low-risk action.",
                    };
                    checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Failed);
                    await PersistAsync(checkpoint, "run_failed", cancellationToken, "invalid_model_approval")
                        .ConfigureAwait(false);
                    return checkpoint;
                }
                checkpoint = RequestApproval(
                    checkpoint,
                    decision.RequestedTool.Value,
                    $"Approve {BurnBarPlannerWire.ToolKind(decision.RequestedTool.Value)}",
                    decision.Message ?? "OpenBurnBar paused because the model requested approval before continuing.",
                    pendingInvocation: null);
                await PersistAsync(checkpoint, "approval_requested", cancellationToken).ConfigureAwait(false);
                return checkpoint;
            default:
                if (decision.RequestedTool is null || decision.Arguments is null)
                {
                    throw new HeadlessAgentRunException("invalid_model_tool", "The model tool action is incomplete.");
                }
                return await QueueToolAsync(
                    checkpoint,
                    decision.RequestedTool.Value,
                    decision.Arguments.Value,
                    cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task<HeadlessAgentRunCheckpoint> QueueToolAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        BurnBarToolKind tool,
        JsonElement arguments,
        CancellationToken cancellationToken)
    {
        ValidateToolArguments(arguments);
        if (checkpoint.PendingToolCall is not null || checkpoint.PendingApprovalToolInvocation is not null)
        {
            throw new HeadlessAgentRunException("tool_call_already_active", "The run already has an active tool call.");
        }
        var invocation = new HeadlessAgentToolCall(
            Guid.NewGuid().ToString("N"),
            checkpoint.RunId,
            tool,
            arguments.Clone(),
            BurnBarToolCallStatus.Pending,
            "agent_loop",
            _now(),
            ApprovalId: RequiresMandatoryApproval(tool)
                ? checkpoint.ApprovedToolAuthorizationId
                : null);

        if (RequiresMandatoryApproval(tool) && !checkpoint.ApprovalResolvedForAttempt)
        {
            BurnBarApprovalDescriptor approval = _policy.ApprovalDescriptor(true, checkpoint.Intent, tool)
                ?? throw new HeadlessAgentRunException("approval_policy_failed", "Approval policy did not describe a risky tool.");
            checkpoint = RequestApproval(
                checkpoint,
                tool,
                approval.Title,
                approval.Message,
                invocation with { Status = BurnBarToolCallStatus.AwaitingApproval });
            await PersistAsync(checkpoint, "approval_requested", cancellationToken).ConfigureAwait(false);
            return checkpoint;
        }
        if (RequiresMandatoryApproval(tool))
        {
            checkpoint = checkpoint with
            {
                ApprovalResolvedForAttempt = false,
                ApprovedToolAuthorizationId = null,
            };
        }
        checkpoint = QueueApprovedTool(checkpoint, invocation);
        await PersistAsync(checkpoint, "tool_queued", cancellationToken).ConfigureAwait(false);
        return checkpoint;
    }

    private HeadlessAgentRunCheckpoint QueueApprovedTool(
        HeadlessAgentRunCheckpoint checkpoint,
        HeadlessAgentToolCall invocation)
    {
        HeadlessAgentToolCall pending = invocation with
        {
            Status = BurnBarToolCallStatus.Pending,
            ClaimedBy = null,
            ClaimedAt = null,
            CompletedAt = null,
            Output = null,
            Error = null,
        };
        checkpoint = checkpoint with
        {
            PendingToolCall = pending,
            PendingApprovalToolInvocation = null,
            ApprovalRequest = null,
        };
        return Transition(checkpoint, HeadlessAgentRunPhase.WaitingOnCompanion);
    }

    private HeadlessAgentRunCheckpoint RequestApproval(
        HeadlessAgentRunCheckpoint checkpoint,
        BurnBarToolKind tool,
        string title,
        string message,
        HeadlessAgentToolCall? pendingInvocation)
    {
        var approval = new HeadlessAgentApprovalRequest(
            Guid.NewGuid().ToString("N"),
            checkpoint.RunId,
            tool,
            Bound(title, MaximumPromptCharacters),
            Bound(message, MaximumPromptCharacters),
            _now());
        checkpoint = checkpoint with
        {
            ApprovalRequest = approval,
            PendingApprovalToolInvocation = pendingInvocation,
            ApprovedToolAuthorizationId = null,
        };
        return Transition(checkpoint, HeadlessAgentRunPhase.AwaitingApproval);
    }

    private HeadlessAgentRunCheckpoint ApplySuccessfulToolResult(
        HeadlessAgentRunCheckpoint checkpoint,
        HeadlessAgentToolCall call)
    {
        HeadlessAgentContextSnapshot context = CurrentContext(checkpoint);
        string? lastReadPath = context.LastReadFilePath;
        string? lastReadContent = checkpoint.WorkflowReadContent;
        IReadOnlyList<string> searchResults = context.SearchResultPaths;
        if (call.Tool == BurnBarToolKind.ReadFile && call.Output is JsonElement readOutput)
        {
            string? path = OptionalString(readOutput, "path");
            string? content = OptionalString(readOutput, "content", trim: false);
            if (path is null || content is null)
            {
                throw new HeadlessAgentRunException("invalid_read_output", "A successful read_file result requires path and content.");
            }
            lastReadPath = path;
            lastReadContent = content;
        }
        else if (call.Tool == BurnBarToolKind.SearchWorkspace && call.Output is JsonElement searchOutput)
        {
            searchResults = SearchResultPaths(searchOutput);
        }

        int workflowStep = checkpoint.WorkflowStep;
        bool companionCompleted = checkpoint.CompanionToolCompleted;
        switch (checkpoint.Intent.Kind)
        {
            case BurnBarAgentIntentKind.ReplaceStringInFile:
                workflowStep = call.Tool switch
                {
                    BurnBarToolKind.ReadFile => Math.Max(workflowStep, 1),
                    BurnBarToolKind.ApplyPatch => Math.Max(workflowStep, 2),
                    _ => workflowStep,
                };
                break;
            case BurnBarAgentIntentKind.InspectWorkspace:
                workflowStep = Math.Max(workflowStep, 1);
                break;
            case BurnBarAgentIntentKind.RunTerminal:
                companionCompleted = true;
                break;
            case BurnBarAgentIntentKind.Generic when checkpoint.Intent.RequestedTools is { Count: 1 }:
                companionCompleted = true;
                workflowStep = Math.Max(workflowStep, 1);
                break;
        }
        context = context with
        {
            LastReadFilePath = lastReadPath,
            LastReadContent = lastReadContent,
            SearchResultPaths = searchResults,
        };
        return checkpoint with
        {
            WorkflowStep = workflowStep,
            WorkflowReadContent = lastReadContent,
            CompanionToolCompleted = companionCompleted,
            LoopState = checkpoint.LoopState with
            {
                LastContextSnapshot = context,
                LastExecutedTool = call.Tool,
                TerminalPending = false,
            },
        };
    }

    private async Task<HeadlessAgentRunCheckpoint> RecoverToolFailureAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        HeadlessAgentToolCall call,
        CancellationToken cancellationToken)
    {
        HeadlessAgentToolError error = call.Error
            ?? new HeadlessAgentToolError(BurnBarToolExecutionErrorCode.Unknown, "The companion reported a failed tool call.");
        checkpoint = checkpoint with { LastRecoveryReason = error.Code.ToString() };
        if (error.Code is BurnBarToolExecutionErrorCode.TrustGated
            or BurnBarToolExecutionErrorCode.NoWorkspace
            or BurnBarToolExecutionErrorCode.RemoteUnsupported)
        {
            checkpoint = RequestApproval(
                checkpoint,
                call.Tool,
                $"Workspace action required for {BurnBarPlannerWire.ToolKind(call.Tool)}",
                Bound(error.Message, MaximumPromptCharacters),
                pendingInvocation: null);
            await PersistAsync(checkpoint, "recovery_approval_requested", cancellationToken).ConfigureAwait(false);
            return checkpoint;
        }
        if (error.Code == BurnBarToolExecutionErrorCode.ApplyFailed && checkpoint.Attempt == 1)
        {
            checkpoint = checkpoint with
            {
                Attempt = 2,
                ApprovalResolvedForAttempt = false,
                ApprovedToolAuthorizationId = null,
                ErrorMessage = null,
            };
            checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Planning);
            await PersistAsync(checkpoint, "recovery_retry", cancellationToken).ConfigureAwait(false);
            return checkpoint;
        }

        checkpoint = checkpoint with { ErrorMessage = Bound(error.Message, MaximumPromptCharacters) };
        checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Failed);
        await PersistAsync(checkpoint, "run_failed", cancellationToken, "tool_failed").ConfigureAwait(false);
        return checkpoint;
    }

    private async Task<HeadlessAgentRunCheckpoint> CompleteAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        CancellationToken cancellationToken)
    {
        checkpoint = checkpoint with { ErrorMessage = null, ApprovalRequest = null };
        checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Completed);
        await PersistAsync(checkpoint, "run_completed", cancellationToken).ConfigureAwait(false);
        return checkpoint;
    }

    private HeadlessAgentContextSnapshot CurrentContext(HeadlessAgentRunCheckpoint checkpoint)
    {
        HeadlessAgentContextSnapshot? previous = checkpoint.LoopState.LastContextSnapshot;
        IReadOnlyList<string> candidates = MetadataStringList(checkpoint.Metadata, "candidatePaths");
        if (candidates.Count == 0) candidates = MetadataStringList(checkpoint.Metadata, "workspaceFiles");
        string? activePath = MetadataString(checkpoint.Metadata, "activeFilePath")
            ?? MetadataString(checkpoint.Metadata, "filePath")
            ?? MetadataString(checkpoint.Metadata, "path")
            ?? checkpoint.Intent.TargetPath;
        IReadOnlyList<string> hints = MetadataStringList(checkpoint.Metadata, "searchHints");
        if (!string.IsNullOrWhiteSpace(checkpoint.Intent.SearchQuery))
        {
            hints = hints.Concat(new[] { checkpoint.Intent.SearchQuery! }).Distinct(StringComparer.Ordinal).Take(MaximumContextPaths).ToArray();
        }
        return new HeadlessAgentContextSnapshot(
            candidates,
            activePath,
            previous?.LastReadFilePath,
            checkpoint.WorkflowReadContent ?? previous?.LastReadContent,
            hints,
            checkpoint.Intent.TargetPath,
            previous?.SearchResultPaths ?? Array.Empty<string>());
    }

    private void RecordProviderTelemetry(
        DateTimeOffset startedAt,
        string clientModel,
        ModelRouteDecision selection,
        ModelCompletionResult result)
    {
        DateTimeOffset completedAt = _now();
        ModelRoute route = selection.Route;
        ModelRouteRoutingMetadata metadata = route.Routing ?? new ModelRouteRoutingMetadata();
        _router.TelemetryStore.Append(new GatewayRouteLogEntry(
            Guid.NewGuid().ToString("N"),
            startedAt,
            completedAt,
            Math.Max((long)(completedAt - startedAt).TotalMilliseconds, 0),
            "/internal/headless-agent",
            clientModel,
            route.Model,
            route.Id,
            route.Vendor,
            metadata.CredentialSlotId,
            metadata.CanonicalModelId,
            metadata.FormatFamily ?? route.Vendor,
            metadata.EndpointProfileId,
            selection.Degraded,
            result.Succeeded,
            result.StatusCode,
            result.ContentType.StartsWith("text/event-stream", StringComparison.OrdinalIgnoreCase),
            result.Succeeded ? GatewayUsageParser.Parse(result) : null));
    }

    private static bool RequiresMandatoryApproval(BurnBarToolKind tool) => tool is not
        BurnBarToolKind.ReadFile and not BurnBarToolKind.SearchWorkspace;

    private static void ValidateToolArguments(JsonElement arguments)
    {
        if (arguments.ValueKind != JsonValueKind.Object
            || System.Text.Encoding.UTF8.GetByteCount(arguments.GetRawText()) > HeadlessAgentLoopService.MaximumArgumentBytes)
        {
            throw new HeadlessAgentRunException("tool_arguments_too_large", "Tool arguments must be an object within the size limit.");
        }
    }

    private static JsonElement TerminalArguments(BurnBarAgentIntent intent)
    {
        if (intent.ToolArguments is JsonElement existing) return existing.Clone();
        BurnBarTerminalCommandIntent terminal = intent.TerminalCommand
            ?? throw new HeadlessAgentRunException("terminal_command_missing", "The terminal intent has no command.");
        return JsonSerializer.SerializeToElement(new
        {
            command = terminal.Command,
            cwd = terminal.Cwd,
            name = terminal.Name,
            preserveFocus = terminal.PreserveFocus,
        });
    }

    private static IReadOnlyList<string> SearchResultPaths(JsonElement output)
    {
        if (output.ValueKind != JsonValueKind.Object
            || !output.TryGetProperty("matches", out JsonElement matches)
            || matches.ValueKind != JsonValueKind.Array)
        {
            throw new HeadlessAgentRunException("invalid_search_output", "A successful search result requires a matches array.");
        }
        var paths = new List<string>();
        foreach (JsonElement match in matches.EnumerateArray().Take(MaximumContextPaths))
        {
            string? path = OptionalString(match, "path");
            if (path is not null && path.Length <= MaximumPromptCharacters) paths.Add(path);
        }
        return paths.Distinct(StringComparer.Ordinal).ToArray();
    }

    private static IReadOnlyList<string> MetadataStringList(JsonElement metadata, string property)
    {
        if (metadata.ValueKind != JsonValueKind.Object
            || !metadata.TryGetProperty(property, out JsonElement array)
            || array.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<string>();
        }
        return array.EnumerateArray()
            .Take(MaximumContextPaths)
            .Where(item => item.ValueKind == JsonValueKind.String)
            .Select(item => item.GetString())
            .Where(value => !string.IsNullOrWhiteSpace(value) && value!.Length <= MaximumPromptCharacters)
            .Select(value => value!)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
    }

    private static string? MetadataString(JsonElement metadata, string property) =>
        OptionalString(metadata, property);

    private static string? OptionalString(JsonElement parent, string property, bool trim = true)
    {
        if (parent.ValueKind != JsonValueKind.Object
            || !parent.TryGetProperty(property, out JsonElement value)
            || value.ValueKind != JsonValueKind.String)
        {
            return null;
        }
        string? text = value.GetString();
        if (text is null || (trim && string.IsNullOrWhiteSpace(text))) return null;
        return trim ? text.Trim() : text;
    }
}

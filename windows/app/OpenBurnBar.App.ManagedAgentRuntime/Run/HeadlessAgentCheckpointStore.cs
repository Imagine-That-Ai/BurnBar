using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;

namespace OpenBurnBar.App.ManagedAgentRuntime.Run;

public interface IHeadlessAgentCheckpointStore
{
    Task SaveAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        CancellationToken cancellationToken = default);

    Task<HeadlessAgentRunCheckpoint?> LoadAsync(
        string runId,
        CancellationToken cancellationToken = default);

    Task DeleteAsync(
        string runId,
        CancellationToken cancellationToken = default);
}

public static class HeadlessAgentCheckpointCodec
{
    public const int MaximumCheckpointBytes = 2 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) },
    };

    public static byte[] Serialize(HeadlessAgentRunCheckpoint checkpoint)
    {
        ArgumentNullException.ThrowIfNull(checkpoint);
        ValidateCheckpoint(checkpoint);
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(checkpoint, JsonOptions);
        if (bytes.Length > MaximumCheckpointBytes)
        {
            throw new InvalidDataException("The protected headless-agent checkpoint exceeds the size limit.");
        }
        return bytes;
    }

    public static HeadlessAgentRunCheckpoint Deserialize(string runId, ReadOnlySpan<byte> bytes)
    {
        ValidateRunId(runId);
        if (bytes.Length == 0 || bytes.Length > MaximumCheckpointBytes)
        {
            throw new InvalidDataException("The protected headless-agent checkpoint has an invalid size.");
        }
        try
        {
            HeadlessAgentRunCheckpoint checkpoint = JsonSerializer.Deserialize<HeadlessAgentRunCheckpoint>(
                bytes,
                JsonOptions) ?? throw new InvalidDataException("The protected headless-agent checkpoint is null.");
            if (!string.Equals(checkpoint.RunId, runId, StringComparison.Ordinal))
            {
                throw new InvalidDataException("The protected headless-agent checkpoint run id does not match.");
            }
            ValidateCheckpoint(checkpoint);
            return checkpoint;
        }
        catch (JsonException error)
        {
            throw new InvalidDataException("The protected headless-agent checkpoint is corrupt.", error);
        }
    }

    public static void ValidateRunId(string runId)
    {
        if (string.IsNullOrWhiteSpace(runId)
            || runId.Length > 128
            || runId.Any(char.IsControl)
            || runId.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
            || runId.IndexOfAny("<>:\"/\\|?*".ToCharArray()) >= 0)
        {
            throw new ArgumentException("A bounded, path-safe run id is required.", nameof(runId));
        }
    }

    private static void ValidateCheckpoint(HeadlessAgentRunCheckpoint checkpoint)
    {
        if (checkpoint.Intent is null || checkpoint.PlanOutline is null || checkpoint.LoopState is null)
        {
            throw new InvalidDataException("The protected headless-agent checkpoint is missing required state.");
        }
        ValidateRunId(checkpoint.RunId);
        ValidateText(checkpoint.ClientId, 128, "client id");
        ValidateText(checkpoint.SessionId, 128, "session id");
        ValidateText(checkpoint.ModelId, 256, "model id");
        ValidateText(checkpoint.OriginalPrompt, 32 * 1024, "prompt");
        if (!Enum.IsDefined(checkpoint.Phase)
            || checkpoint.Attempt is < 1 or > 1024
            || checkpoint.WorkflowStep is < 0 or > 1024
            || checkpoint.LoopState.IterationCount is < 0 or > 64)
        {
            throw new InvalidDataException("The protected headless-agent checkpoint contains invalid state.");
        }
        if (checkpoint.Metadata.ValueKind != JsonValueKind.Object
            || Encoding.UTF8.GetByteCount(checkpoint.Metadata.GetRawText()) > 256 * 1024)
        {
            throw new InvalidDataException("The protected headless-agent checkpoint metadata is invalid.");
        }
        ValidateOptionalText(checkpoint.ErrorMessage, 32 * 1024, "error message");
        ValidateOptionalText(checkpoint.WorkflowReadContent, 256 * 1024, "read content", allowControls: true, allowEmpty: true);
        ValidateOptionalText(checkpoint.ApprovedToolAuthorizationId, 128, "approved tool authorization id");
        ValidateApproval(checkpoint.ApprovalRequest);
        ValidateToolCall(checkpoint.PendingApprovalToolInvocation);
        ValidateToolCall(checkpoint.PendingToolCall);
        ValidateToolCall(checkpoint.LastToolCall);
        ValidateNestedRunId(checkpoint.RunId, checkpoint.ApprovalRequest?.RunId, "approval");
        ValidateNestedRunId(checkpoint.RunId, checkpoint.PendingApprovalToolInvocation?.RunId, "pending approval tool");
        ValidateNestedRunId(checkpoint.RunId, checkpoint.PendingToolCall?.RunId, "pending tool");
        ValidateNestedRunId(checkpoint.RunId, checkpoint.LastToolCall?.RunId, "last tool");
        ValidateLoopState(checkpoint.LoopState);
        if (!Enum.IsDefined(checkpoint.Intent.Kind))
        {
            throw new InvalidDataException("The protected headless-agent checkpoint contains an invalid intent kind.");
        }
        ValidateText(checkpoint.Intent.Objective, 32 * 1024, "intent objective");
        ValidateText(checkpoint.Intent.Summary, 32 * 1024, "intent summary");
        ValidateOptionalText(checkpoint.Intent.TargetPath, 32 * 1024, "intent target path");
        ValidateOptionalText(checkpoint.Intent.SearchQuery, 32 * 1024, "intent search query");
        ValidateIntentPayload(checkpoint.Intent);
        ValidateText(checkpoint.PlanOutline.Objective, 32 * 1024, "plan objective");
        if (checkpoint.Intent.RequestedTools?.Count > 128
            || checkpoint.PlanOutline.Steps is null
            || checkpoint.PlanOutline.Steps.Count > 128)
        {
            throw new InvalidDataException("The protected headless-agent checkpoint contains too many plan items.");
        }
        foreach (BurnBarPlanStep step in checkpoint.PlanOutline.Steps)
        {
            if (step is null)
            {
                throw new InvalidDataException("The protected headless-agent checkpoint contains a null plan step.");
            }
            ValidateText(step.Title, 32 * 1024, "plan title");
            ValidateText(step.Detail, 32 * 1024, "plan detail");
            if (!Enum.IsDefined(step.Status))
            {
                throw new InvalidDataException("The protected headless-agent checkpoint contains an invalid plan status.");
            }
        }
    }

    private static void ValidateNestedRunId(string expected, string? actual, string name)
    {
        if (actual is not null && !string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new InvalidDataException($"The protected headless-agent checkpoint {name} run id does not match.");
        }
    }

    private static void ValidateIntentPayload(BurnBarAgentIntent intent)
    {
        if (intent.Replacement is BurnBarTextReplacement replacement)
        {
            ValidateText(replacement.From, 256 * 1024, "replacement source", allowControls: true);
            ValidateText(replacement.To, 256 * 1024, "replacement destination", allowControls: true, allowEmpty: true);
        }
        if (intent.TerminalCommand is BurnBarTerminalCommandIntent terminal)
        {
            ValidateText(terminal.Command, 32 * 1024, "terminal command", allowControls: true);
            ValidateOptionalText(terminal.Cwd, 32 * 1024, "terminal cwd");
            ValidateOptionalText(terminal.Name, 32 * 1024, "terminal name");
        }
        if (intent.RequestedTools is not null)
        {
            foreach (BurnBarToolKind tool in intent.RequestedTools)
            {
                if (!Enum.IsDefined(tool))
                {
                    throw new InvalidDataException("The protected headless-agent checkpoint contains an invalid requested tool.");
                }
            }
        }
        if (intent.ToolArguments is JsonElement arguments
            && (arguments.ValueKind != JsonValueKind.Object
                || Encoding.UTF8.GetByteCount(arguments.GetRawText()) > 256 * 1024))
        {
            throw new InvalidDataException("The protected headless-agent checkpoint intent arguments are invalid.");
        }
    }

    private static void ValidateApproval(HeadlessAgentApprovalRequest? approval)
    {
        if (approval is null) return;
        ValidateText(approval.ApprovalId, 128, "approval id");
        ValidateRunId(approval.RunId);
        ValidateText(approval.Title, 32 * 1024, "approval title");
        ValidateText(approval.Message, 32 * 1024, "approval message");
        if (!Enum.IsDefined(approval.Tool))
        {
            throw new InvalidDataException("The protected headless-agent checkpoint contains an invalid approval tool.");
        }
    }

    private static void ValidateToolCall(HeadlessAgentToolCall? call)
    {
        if (call is null) return;
        ValidateText(call.CallId, 128, "tool call id");
        ValidateRunId(call.RunId);
        ValidateText(call.RequestedBy, 128, "tool requester");
        ValidateOptionalText(call.ClaimedBy, 128, "tool claimant");
        ValidateOptionalText(call.ApprovalId, 128, "tool approval id");
        if (!Enum.IsDefined(call.Tool)
            || !Enum.IsDefined(call.Status)
            || call.Arguments.ValueKind != JsonValueKind.Object
            || Encoding.UTF8.GetByteCount(call.Arguments.GetRawText()) > 256 * 1024
            || (call.Output is JsonElement output
                && Encoding.UTF8.GetByteCount(output.GetRawText()) > 256 * 1024))
        {
            throw new InvalidDataException("The protected headless-agent checkpoint contains an invalid tool call.");
        }
        if (call.Error is HeadlessAgentToolError error)
        {
            if (!Enum.IsDefined(error.Code))
            {
                throw new InvalidDataException("The protected headless-agent checkpoint contains an invalid tool error.");
            }
            ValidateText(error.Message, 32 * 1024, "tool error");
        }
    }

    private static void ValidateLoopState(HeadlessAgentLoopState state)
    {
        if (state.LastDecision is HeadlessAgentLoopDecision decision)
        {
            if (!Enum.IsDefined(decision.Action)
                || (decision.RequestedTool is BurnBarToolKind requestedTool && !Enum.IsDefined(requestedTool))
                || (decision.Arguments is JsonElement arguments
                    && (arguments.ValueKind != JsonValueKind.Object
                        || Encoding.UTF8.GetByteCount(arguments.GetRawText()) > 256 * 1024)))
            {
                throw new InvalidDataException("The protected headless-agent checkpoint contains an invalid loop decision.");
            }
            ValidateText(decision.Rationale, 32 * 1024, "loop rationale");
            ValidateOptionalText(decision.Message, 32 * 1024, "loop message");
        }
        if (state.LastExecutedTool is BurnBarToolKind tool && !Enum.IsDefined(tool))
        {
            throw new InvalidDataException("The protected headless-agent checkpoint contains an invalid executed tool.");
        }
        HeadlessAgentContextSnapshot? context = state.LastContextSnapshot;
        if (context is null) return;
        if (context.CandidatePaths is null || context.SearchHints is null || context.SearchResultPaths is null)
        {
            throw new InvalidDataException("The protected headless-agent checkpoint context is incomplete.");
        }
        ValidateStringList(context.CandidatePaths, "candidate paths");
        ValidateStringList(context.SearchHints, "search hints");
        ValidateStringList(context.SearchResultPaths, "search result paths");
        ValidateOptionalText(context.ActiveFilePath, 32 * 1024, "active file");
        ValidateOptionalText(context.LastReadFilePath, 32 * 1024, "last read file");
        ValidateOptionalText(context.LastReadContent, 256 * 1024, "last read content", allowControls: true, allowEmpty: true);
        ValidateOptionalText(context.ReplacementTargetPath, 32 * 1024, "replacement target");
    }

    private static void ValidateStringList(IReadOnlyList<string> values, string name)
    {
        if (values.Count > 128)
        {
            throw new InvalidDataException($"The protected headless-agent checkpoint has too many {name}.");
        }
        foreach (string value in values) ValidateText(value, 32 * 1024, name);
    }

    private static void ValidateOptionalText(
        string? value,
        int maximum,
        string name,
        bool allowControls = false,
        bool allowEmpty = false)
    {
        if (value is not null) ValidateText(value, maximum, name, allowControls, allowEmpty);
    }

    private static void ValidateText(
        string value,
        int maximum,
        string name,
        bool allowControls = false,
        bool allowEmpty = false)
    {
        if ((!allowEmpty && string.IsNullOrWhiteSpace(value))
            || value.Length > maximum
            || (!allowControls && value.Any(char.IsControl)))
        {
            throw new InvalidDataException($"The protected headless-agent checkpoint {name} is invalid.");
        }
    }
}

public sealed class InMemoryHeadlessAgentCheckpointStore : IHeadlessAgentCheckpointStore
{
    private readonly object _gate = new();
    private readonly Dictionary<string, byte[]> _checkpoints = new(StringComparer.Ordinal);

    public Task SaveAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        byte[] bytes = HeadlessAgentCheckpointCodec.Serialize(checkpoint);
        lock (_gate) _checkpoints[checkpoint.RunId] = bytes;
        return Task.CompletedTask;
    }

    public Task<HeadlessAgentRunCheckpoint?> LoadAsync(
        string runId,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        HeadlessAgentCheckpointCodec.ValidateRunId(runId);
        byte[]? bytes;
        lock (_gate) bytes = _checkpoints.TryGetValue(runId, out byte[]? found) ? (byte[])found.Clone() : null;
        return Task.FromResult(bytes is null
            ? null
            : HeadlessAgentCheckpointCodec.Deserialize(runId, bytes));
    }

    public Task DeleteAsync(
        string runId,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        HeadlessAgentCheckpointCodec.ValidateRunId(runId);
        lock (_gate) _checkpoints.Remove(runId);
        return Task.CompletedTask;
    }
}

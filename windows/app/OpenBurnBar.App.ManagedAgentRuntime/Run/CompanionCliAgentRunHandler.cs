using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;

namespace OpenBurnBar.App.ManagedAgentRuntime.Run;

/// <summary>Bounded wire adapter for durable daemon-side agent runs.</summary>
public sealed class CompanionCliAgentRunHandler
{
    private readonly HeadlessAgentRunService _runs;

    public CompanionCliAgentRunHandler(HeadlessAgentRunService runs)
    {
        _runs = runs ?? throw new ArgumentNullException(nameof(runs));
    }

    public async Task<object?> SubmitAsync(JsonElement request, CancellationToken cancellationToken)
    {
        string runId = RequiredString(request, "runId");
        string clientId = RequiredString(request, "clientId");
        string sessionId = RequiredString(request, "sessionId");
        string prompt = RequiredString(request, "prompt");
        string modelId = RequiredString(request, "modelId", "model");
        bool requiresApproval = OptionalBoolean(request, "requiresApproval") ?? false;
        JsonElement? metadata = request.TryGetProperty("metadata", out JsonElement metadataElement)
            ? metadataElement.Clone()
            : null;
        HeadlessAgentRunSnapshot snapshot = await _runs.SubmitAsync(
            new HeadlessAgentRunRequest(
                runId,
                clientId,
                sessionId,
                prompt,
                modelId,
                requiresApproval,
                metadata),
            cancellationToken).ConfigureAwait(false);
        return ToWireSnapshot(snapshot);
    }

    public async Task<object?> GetAsync(JsonElement request, CancellationToken cancellationToken)
    {
        HeadlessAgentRunDetail detail = await _runs.GetAsync(
            RequiredString(request, "runId"),
            RequiredString(request, "clientId"),
            cancellationToken).ConfigureAwait(false);
        return ToWireDetail(detail);
    }

    public async Task<object?> PollAsync(JsonElement request, CancellationToken cancellationToken)
    {
        DateTimeOffset? updatedAfter = OptionalTimestamp(request, "updatedAfter");
        int limit = OptionalInteger(request, "limit") ?? HeadlessAgentRunService.MaximumPollResults;
        IReadOnlyList<HeadlessAgentRunSnapshot> runs = await _runs.PollAsync(
            RequiredString(request, "clientId"),
            updatedAfter,
            limit,
            cancellationToken).ConfigureAwait(false);
        return runs.Select(ToWireSnapshot).ToArray();
    }

    public async Task<object?> CancelAsync(JsonElement request, CancellationToken cancellationToken)
    {
        HeadlessAgentRunDetail detail = await _runs.CancelAsync(
            RequiredString(request, "runId"),
            RequiredString(request, "clientId"),
            OptionalString(request, "reason"),
            cancellationToken).ConfigureAwait(false);
        return ToWireDetail(detail);
    }

    public async Task<object?> RetryAsync(JsonElement request, CancellationToken cancellationToken)
    {
        HeadlessAgentRunDetail detail = await _runs.RetryAsync(
            RequiredString(request, "runId"),
            RequiredString(request, "clientId"),
            cancellationToken).ConfigureAwait(false);
        return ToWireDetail(detail);
    }

    public async Task<object?> RecoverAsync(JsonElement request, CancellationToken cancellationToken)
    {
        IReadOnlyList<HeadlessAgentRunSnapshot> runs = await _runs.RecoverAsync(
            RequiredString(request, "clientId"),
            cancellationToken).ConfigureAwait(false);
        return runs.Select(ToWireSnapshot).ToArray();
    }

    public async Task<object?> ClaimToolAsync(JsonElement request, CancellationToken cancellationToken)
    {
        HeadlessAgentToolClaimResponse claim = await _runs.ClaimToolAsync(
            RequiredString(request, "runId"),
            RequiredString(request, "clientId"),
            RequiredString(request, "sessionId"),
            cancellationToken).ConfigureAwait(false);
        return new
        {
            disposition = Disposition(claim.Disposition),
            toolCall = claim.ToolCall is null ? null : ToWireToolCall(claim.ToolCall),
        };
    }

    public async Task<object?> SubmitToolResultAsync(JsonElement request, CancellationToken cancellationToken)
    {
        bool succeeded = RequiredBoolean(request, "succeeded");
        JsonElement? output = request.TryGetProperty("output", out JsonElement outputElement)
            && outputElement.ValueKind != JsonValueKind.Null
            ? outputElement.Clone()
            : null;
        HeadlessAgentToolError? error = null;
        if (request.TryGetProperty("error", out JsonElement errorElement)
            && errorElement.ValueKind != JsonValueKind.Null)
        {
            error = new HeadlessAgentToolError(
                ParseToolErrorCode(RequiredString(errorElement, "code")),
                RequiredString(errorElement, "message"));
        }
        HeadlessAgentRunDetail detail = await _runs.SubmitToolResultAsync(
            new HeadlessAgentToolResultSubmission(
                RequiredString(request, "clientId"),
                RequiredString(request, "sessionId"),
                RequiredString(request, "runId"),
                RequiredString(request, "callId"),
                succeeded,
                output,
                error,
                OptionalTimestamp(request, "completedAt") ?? DateTimeOffset.UtcNow),
            cancellationToken).ConfigureAwait(false);
        return ToWireDetail(detail);
    }

    public async Task<object?> RespondToApprovalAsync(JsonElement request, CancellationToken cancellationToken)
    {
        HeadlessAgentRunDetail detail = await _runs.RespondToApprovalAsync(
            new HeadlessAgentApprovalResponse(
                RequiredString(request, "runId"),
                RequiredString(request, "approvalId"),
                RequiredString(request, "clientId"),
                ParseApprovalDecision(RequiredString(request, "decision")),
                OptionalString(request, "note"),
                OptionalTimestamp(request, "respondedAt") ?? DateTimeOffset.UtcNow),
            cancellationToken).ConfigureAwait(false);
        return ToWireDetail(detail);
    }

    private static object ToWireDetail(HeadlessAgentRunDetail detail) => new
    {
        run = ToWireSnapshot(detail.Run),
        approvalRequest = detail.ApprovalRequest is null ? null : new
        {
            approvalId = detail.ApprovalRequest.ApprovalId,
            runId = detail.ApprovalRequest.RunId,
            tool = BurnBarPlannerWire.ToolKind(detail.ApprovalRequest.Tool),
            title = detail.ApprovalRequest.Title,
            message = detail.ApprovalRequest.Message,
            requestedAt = detail.ApprovalRequest.RequestedAt,
        },
        pendingToolCall = detail.PendingToolCall is null ? null : ToWireToolCall(detail.PendingToolCall),
        loopState = new
        {
            iterationCount = detail.LoopState.IterationCount,
            lastExecutedTool = detail.LoopState.LastExecutedTool is BurnBarToolKind tool
                ? BurnBarPlannerWire.ToolKind(tool)
                : null,
            terminalPending = detail.LoopState.TerminalPending,
        },
    };

    private static object ToWireSnapshot(HeadlessAgentRunSnapshot snapshot) => new
    {
        runId = snapshot.RunId,
        clientId = snapshot.ClientId,
        sessionId = snapshot.SessionId,
        phase = Phase(snapshot.Phase),
        modelId = snapshot.ModelId,
        updatedAt = snapshot.UpdatedAt,
        errorMessage = snapshot.ErrorMessage,
        activeApprovalId = snapshot.ActiveApprovalId,
    };

    private static object ToWireToolCall(HeadlessAgentToolCall call) => new
    {
        callId = call.CallId,
        runId = call.RunId,
        tool = BurnBarPlannerWire.ToolKind(call.Tool),
        arguments = call.Arguments,
        status = ToolStatus(call.Status),
        requestedBy = call.RequestedBy,
        requestedAt = call.RequestedAt,
        claimedBy = call.ClaimedBy,
        claimedAt = call.ClaimedAt,
    };

    private static string Phase(HeadlessAgentRunPhase phase) => phase switch
    {
        HeadlessAgentRunPhase.Idle => "idle",
        HeadlessAgentRunPhase.Planning => "planning",
        HeadlessAgentRunPhase.AwaitingApproval => "awaiting_approval",
        HeadlessAgentRunPhase.ExecutingTool => "executing_tool",
        HeadlessAgentRunPhase.WaitingOnCompanion => "waiting_on_companion",
        HeadlessAgentRunPhase.ModelStreaming => "model_streaming",
        HeadlessAgentRunPhase.Completed => "completed",
        HeadlessAgentRunPhase.Failed => "failed",
        HeadlessAgentRunPhase.Cancelled => "cancelled",
        _ => throw new ArgumentOutOfRangeException(nameof(phase)),
    };

    private static string ToolStatus(BurnBarToolCallStatus status) => status switch
    {
        BurnBarToolCallStatus.Pending => "pending",
        BurnBarToolCallStatus.Running => "running",
        BurnBarToolCallStatus.AwaitingApproval => "awaiting_approval",
        BurnBarToolCallStatus.Completed => "completed",
        BurnBarToolCallStatus.Failed => "failed",
        _ => throw new ArgumentOutOfRangeException(nameof(status)),
    };

    private static string Disposition(HeadlessAgentToolDisposition disposition) => disposition switch
    {
        HeadlessAgentToolDisposition.Dispatched => "dispatched",
        HeadlessAgentToolDisposition.NoPendingToolCall => "no_pending_tool_call",
        HeadlessAgentToolDisposition.RunNotFound => "run_not_found",
        _ => throw new ArgumentOutOfRangeException(nameof(disposition)),
    };

    private static HeadlessAgentApprovalDecision ParseApprovalDecision(string value) => value switch
    {
        "approve" => HeadlessAgentApprovalDecision.Approve,
        "reject" => HeadlessAgentApprovalDecision.Reject,
        "cancel" => HeadlessAgentApprovalDecision.Cancel,
        _ => throw new ArgumentException("decision must be approve, reject, or cancel."),
    };

    private static BurnBarToolExecutionErrorCode ParseToolErrorCode(string value) => value switch
    {
        "trust_gated" => BurnBarToolExecutionErrorCode.TrustGated,
        "no_workspace" => BurnBarToolExecutionErrorCode.NoWorkspace,
        "remote_unsupported" => BurnBarToolExecutionErrorCode.RemoteUnsupported,
        "apply_failed" => BurnBarToolExecutionErrorCode.ApplyFailed,
        "terminal_failed" => BurnBarToolExecutionErrorCode.TerminalFailed,
        "unknown" => BurnBarToolExecutionErrorCode.Unknown,
        _ => throw new ArgumentException("error.code is unsupported."),
    };

    private static string RequiredString(JsonElement parent, params string[] names)
    {
        foreach (string name in names)
        {
            string? value = OptionalString(parent, name);
            if (value is not null) return value;
        }
        throw new ArgumentException($"{names[0]} is required.");
    }

    private static string? OptionalString(JsonElement parent, string name) =>
        parent.ValueKind == JsonValueKind.Object
        && parent.TryGetProperty(name, out JsonElement value)
        && value.ValueKind == JsonValueKind.String
        && !string.IsNullOrWhiteSpace(value.GetString())
            ? value.GetString()!.Trim()
            : null;

    private static bool RequiredBoolean(JsonElement parent, string name) =>
        OptionalBoolean(parent, name)
        ?? throw new ArgumentException($"{name} is required.");

    private static bool? OptionalBoolean(JsonElement parent, string name) =>
        parent.ValueKind == JsonValueKind.Object
        && parent.TryGetProperty(name, out JsonElement value)
        && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : null;

    private static int? OptionalInteger(JsonElement parent, string name) =>
        parent.ValueKind == JsonValueKind.Object
        && parent.TryGetProperty(name, out JsonElement value)
        && value.TryGetInt32(out int parsed)
            ? parsed
            : null;

    private static DateTimeOffset? OptionalTimestamp(JsonElement parent, string name)
    {
        string? value = OptionalString(parent, name);
        if (value is null) return null;
        if (!DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out DateTimeOffset parsed))
        {
            throw new ArgumentException($"{name} must be an ISO-8601 timestamp.");
        }
        return parsed;
    }
}

using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;

namespace OpenBurnBar.App.ManagedAgentRuntime.Run;

public enum HeadlessAgentRunPhase
{
    Idle,
    Planning,
    AwaitingApproval,
    ExecutingTool,
    WaitingOnCompanion,
    ModelStreaming,
    Completed,
    Failed,
    Cancelled,
}

public enum HeadlessAgentLoopAction
{
    Complete,
    SearchWorkspace,
    ReadFile,
    ApplyPatch,
    RunTerminal,
    BrowserClick,
    BrowserFill,
    BrowserGoto,
    BrowserKey,
    BrowserSelect,
    BrowserScreenshot,
    BrowserExtract,
    RequestApproval,
    Fail,
}

public enum HeadlessAgentApprovalDecision
{
    Approve,
    Reject,
    Cancel,
}

public enum HeadlessAgentToolDisposition
{
    Dispatched,
    NoPendingToolCall,
    RunNotFound,
}

public sealed record HeadlessAgentRunRequest(
    string RunId,
    string ClientId,
    string SessionId,
    string Prompt,
    string ModelId,
    bool RequiresApproval = false,
    JsonElement? Metadata = null);

public sealed record HeadlessAgentContextSnapshot(
    IReadOnlyList<string> CandidatePaths,
    string? ActiveFilePath,
    string? LastReadFilePath,
    string? LastReadContent,
    IReadOnlyList<string> SearchHints,
    string? ReplacementTargetPath,
    IReadOnlyList<string> SearchResultPaths);

public sealed record HeadlessAgentLoopDecision(
    HeadlessAgentLoopAction Action,
    BurnBarToolKind? RequestedTool,
    JsonElement? Arguments,
    string Rationale,
    string? Message);

public sealed record HeadlessAgentLoopState(
    int IterationCount,
    HeadlessAgentLoopDecision? LastDecision,
    HeadlessAgentContextSnapshot? LastContextSnapshot,
    BurnBarToolKind? LastExecutedTool,
    bool TerminalPending)
{
    public static HeadlessAgentLoopState Empty { get; } = new(0, null, null, null, false);
}

public sealed record HeadlessAgentToolError(
    BurnBarToolExecutionErrorCode Code,
    string Message);

public sealed record HeadlessAgentToolCall(
    string CallId,
    string RunId,
    BurnBarToolKind Tool,
    JsonElement Arguments,
    BurnBarToolCallStatus Status,
    string RequestedBy,
    DateTimeOffset RequestedAt,
    string? ClaimedBy = null,
    DateTimeOffset? ClaimedAt = null,
    DateTimeOffset? CompletedAt = null,
    JsonElement? Output = null,
    HeadlessAgentToolError? Error = null,
    string? ApprovalId = null);

public sealed record HeadlessAgentApprovalRequest(
    string ApprovalId,
    string RunId,
    BurnBarToolKind Tool,
    string Title,
    string Message,
    DateTimeOffset RequestedAt);

public sealed record HeadlessAgentApprovalResponse(
    string RunId,
    string ApprovalId,
    string ClientId,
    HeadlessAgentApprovalDecision Decision,
    string? Note,
    DateTimeOffset RespondedAt);

public sealed record HeadlessAgentToolResultSubmission(
    string ClientId,
    string SessionId,
    string RunId,
    string CallId,
    bool Succeeded,
    JsonElement? Output,
    HeadlessAgentToolError? Error,
    DateTimeOffset CompletedAt);

public sealed record HeadlessAgentRunCheckpoint(
    string RunId,
    string ClientId,
    string SessionId,
    HeadlessAgentRunPhase Phase,
    string ModelId,
    string OriginalPrompt,
    JsonElement Metadata,
    bool RequiresApproval,
    bool RunLevelApprovalCompleted,
    BurnBarAgentIntent Intent,
    BurnBarPlanOutline PlanOutline,
    int Attempt,
    string? ErrorMessage,
    HeadlessAgentApprovalRequest? ApprovalRequest,
    bool ApprovalResolvedForAttempt,
    HeadlessAgentToolCall? PendingApprovalToolInvocation,
    HeadlessAgentToolCall? PendingToolCall,
    HeadlessAgentToolCall? LastToolCall,
    int WorkflowStep,
    string? WorkflowReadContent,
    bool CompanionToolCompleted,
    string? LastRecoveryReason,
    HeadlessAgentLoopState LoopState,
    DateTimeOffset UpdatedAt,
    string? ApprovedToolAuthorizationId = null);

public sealed record HeadlessAgentRunSnapshot(
    string RunId,
    string ClientId,
    string SessionId,
    HeadlessAgentRunPhase Phase,
    string ModelId,
    DateTimeOffset UpdatedAt,
    string? ErrorMessage,
    string? ActiveApprovalId);

public sealed record HeadlessAgentRunDetail(
    HeadlessAgentRunSnapshot Run,
    HeadlessAgentApprovalRequest? ApprovalRequest,
    HeadlessAgentToolCall? PendingToolCall,
    HeadlessAgentLoopState LoopState);

public sealed record HeadlessAgentToolClaimResponse(
    HeadlessAgentToolDisposition Disposition,
    HeadlessAgentToolCall? ToolCall = null);

public sealed record HeadlessAgentInternalToolExecutionResult(
    bool Succeeded,
    JsonElement? Output = null,
    HeadlessAgentToolError? Error = null);

/// <summary>
/// Executes tools that must remain inside the signed app boundary. Workspace
/// tools continue to be leased to the authenticated companion.
/// </summary>
public interface IHeadlessAgentInternalToolExecutor
{
    bool CanExecute(BurnBarToolKind tool);

    Task<HeadlessAgentInternalToolExecutionResult> ExecuteAsync(
        string sessionId,
        HeadlessAgentToolCall call,
        CancellationToken cancellationToken = default);
}

public sealed class HeadlessAgentRunException : InvalidOperationException
{
    public HeadlessAgentRunException(string code, string message)
        : base(message)
    {
        Code = string.IsNullOrWhiteSpace(code) ? "agent_run_failed" : code;
    }

    public string Code { get; }
}

public static class HeadlessAgentRunStateMachine
{
    public static bool IsTerminal(HeadlessAgentRunPhase phase) => phase is
        HeadlessAgentRunPhase.Completed
        or HeadlessAgentRunPhase.Failed
        or HeadlessAgentRunPhase.Cancelled;

    public static bool CanTransition(HeadlessAgentRunPhase from, HeadlessAgentRunPhase to) =>
        (from, to) switch
        {
            (HeadlessAgentRunPhase.Idle, HeadlessAgentRunPhase.Planning) => true,
            (HeadlessAgentRunPhase.Planning, HeadlessAgentRunPhase.AwaitingApproval
                or HeadlessAgentRunPhase.ExecutingTool
                or HeadlessAgentRunPhase.WaitingOnCompanion
                or HeadlessAgentRunPhase.ModelStreaming
                or HeadlessAgentRunPhase.Completed
                or HeadlessAgentRunPhase.Failed
                or HeadlessAgentRunPhase.Cancelled) => true,
            (HeadlessAgentRunPhase.AwaitingApproval, HeadlessAgentRunPhase.Planning
                or HeadlessAgentRunPhase.Cancelled) => true,
            (HeadlessAgentRunPhase.ExecutingTool, HeadlessAgentRunPhase.Planning
                or HeadlessAgentRunPhase.AwaitingApproval
                or HeadlessAgentRunPhase.WaitingOnCompanion
                or HeadlessAgentRunPhase.ModelStreaming
                or HeadlessAgentRunPhase.Completed
                or HeadlessAgentRunPhase.Failed
                or HeadlessAgentRunPhase.Cancelled) => true,
            (HeadlessAgentRunPhase.WaitingOnCompanion, HeadlessAgentRunPhase.AwaitingApproval
                or HeadlessAgentRunPhase.ExecutingTool
                or HeadlessAgentRunPhase.ModelStreaming
                or HeadlessAgentRunPhase.Completed
                or HeadlessAgentRunPhase.Failed
                or HeadlessAgentRunPhase.Cancelled) => true,
            (HeadlessAgentRunPhase.ModelStreaming, HeadlessAgentRunPhase.ExecutingTool
                or HeadlessAgentRunPhase.AwaitingApproval
                or HeadlessAgentRunPhase.WaitingOnCompanion
                or HeadlessAgentRunPhase.Completed
                or HeadlessAgentRunPhase.Failed
                or HeadlessAgentRunPhase.Cancelled) => true,
            (HeadlessAgentRunPhase.Failed, HeadlessAgentRunPhase.Planning
                or HeadlessAgentRunPhase.Cancelled) => true,
            _ => false,
        };

    public static void RequireTransition(HeadlessAgentRunPhase from, HeadlessAgentRunPhase to)
    {
        if (!CanTransition(from, to))
        {
            throw new HeadlessAgentRunException(
                "invalid_run_transition",
                $"Invalid headless agent transition from {from} to {to}.");
        }
    }
}

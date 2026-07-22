using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.ManagedAgentRuntime.Planning;

public sealed record BurnBarApprovalDescriptor(
    BurnBarToolKind Tool,
    string Title,
    string Message,
    BurnBarToolRisk Risk);

public enum BurnBarToolExecutionErrorCode
{
    TrustGated,
    NoWorkspace,
    RemoteUnsupported,
    ApplyFailed,
    TerminalFailed,
    Unknown,
}

public enum BurnBarToolCallStatus
{
    Pending,
    Running,
    AwaitingApproval,
    Completed,
    Failed,
}

/// <summary>
/// Deterministic run/tool policy port. It classifies and describes proposed
/// work only; approval resolution and tool execution remain separate gates.
/// </summary>
public sealed class BurnBarPolicyEngine
{
    public BurnBarToolRisk Risk(BurnBarToolKind? tool) => tool switch
    {
        null or BurnBarToolKind.ReadFile or BurnBarToolKind.SearchWorkspace => BurnBarToolRisk.Low,
        BurnBarToolKind.ApplyPatch => BurnBarToolRisk.Medium,
        _ => BurnBarToolRisk.High,
    };

    public BurnBarApprovalDescriptor? ApprovalDescriptor(
        bool explicitApprovalRequired,
        BurnBarAgentIntent intent,
        BurnBarToolKind? tool = null,
        string? customTitle = null,
        string? customMessage = null)
    {
        ArgumentNullException.ThrowIfNull(intent);
        if (!explicitApprovalRequired)
        {
            return null;
        }

        BurnBarToolKind effectiveTool = tool
            ?? (intent.RequestedTools is { Count: > 0 } requestedTools
                ? requestedTools[^1]
                : BurnBarToolKind.ApplyPatch);
        return new BurnBarApprovalDescriptor(
            effectiveTool,
            customTitle ?? $"Approve {BurnBarPlannerWire.ToolKind(effectiveTool)}",
            customMessage ?? DefaultApprovalMessage(intent, effectiveTool),
            Risk(effectiveTool));
    }

    public bool IsRetryable(BurnBarToolExecutionErrorCode errorCode) => errorCode is
        BurnBarToolExecutionErrorCode.TrustGated
        or BurnBarToolExecutionErrorCode.NoWorkspace
        or BurnBarToolExecutionErrorCode.RemoteUnsupported
        or BurnBarToolExecutionErrorCode.ApplyFailed;

    public bool IndicatesProgress(
        BurnBarToolKind tool,
        BurnBarToolCallStatus status,
        bool hasOutput)
    {
        if (status != BurnBarToolCallStatus.Completed)
        {
            return false;
        }

        return tool is BurnBarToolKind.ReadFile or BurnBarToolKind.SearchWorkspace
            ? hasOutput
            : true;
    }

    public bool ShouldHonorModelRequestedApproval(BurnBarToolKind? tool) =>
        Risk(tool) != BurnBarToolRisk.Low;

    private static string DefaultApprovalMessage(BurnBarAgentIntent intent, BurnBarToolKind tool)
    {
        string summary = intent.Summary.ToLowerInvariant();
        return tool switch
        {
            BurnBarToolKind.ReadFile =>
                $"OpenBurnBar needs approval before reading additional workspace files for {summary}.",
            BurnBarToolKind.SearchWorkspace =>
                "OpenBurnBar needs approval before searching the workspace for additional context.",
            BurnBarToolKind.ApplyPatch =>
                "OpenBurnBar needs approval before applying workspace edits.",
            BurnBarToolKind.RunTerminal =>
                "OpenBurnBar needs approval before running terminal commands in this workspace.",
            BurnBarToolKind.BrowserClick or BurnBarToolKind.BrowserFill or BurnBarToolKind.BrowserGoto
                or BurnBarToolKind.BrowserKey or BurnBarToolKind.BrowserSelect
                or BurnBarToolKind.BrowserScreenshot or BurnBarToolKind.BrowserExtract =>
                $"OpenBurnBar needs approval before controlling a browser for {summary}.",
            _ => $"OpenBurnBar needs approval before controlling this Windows PC for {summary}.",
        };
    }
}

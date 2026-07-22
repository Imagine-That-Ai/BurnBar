using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Planning;

/// <summary>Authenticated, side-effect-free adapter for run/tool policy.</summary>
public sealed class CompanionCliPolicyHandler
{
    private const int MaxCustomTextCharacters = 8 * 1024;
    private readonly BurnBarPlannerService _planner;
    private readonly BurnBarPolicyEngine _policy;

    public CompanionCliPolicyHandler(BurnBarPlannerService planner, BurnBarPolicyEngine policy)
    {
        _planner = planner ?? throw new ArgumentNullException(nameof(planner));
        _policy = policy ?? throw new ArgumentNullException(nameof(policy));
    }

    public Task<object?> EvaluateAsync(JsonElement request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!request.TryGetProperty("intent", out JsonElement intentElement))
        {
            throw new BurnBarPlannerException("invalid_policy_input", "intent is required.");
        }

        BurnBarAgentIntent intent = _planner.ParseNormalizedIntent(intentElement);
        BurnBarToolKind? tool = ParseOptionalTool(request, "tool");
        bool explicitApprovalRequired = OptionalBoolean(request, "explicitApprovalRequired") ?? false;
        string? customTitle = OptionalBoundedString(request, "customTitle");
        string? customMessage = OptionalBoundedString(request, "customMessage");
        BurnBarApprovalDescriptor? approval = _policy.ApprovalDescriptor(
            explicitApprovalRequired,
            intent,
            tool,
            customTitle,
            customMessage);
        BurnBarToolExecutionErrorCode? errorCode = ParseOptionalErrorCode(request);
        (BurnBarToolKind Tool, BurnBarToolCallStatus Status, bool HasOutput)? toolCall =
            ParseOptionalToolCall(request);

        return Task.FromResult<object?>(new
        {
            risk = BurnBarPlannerWire.Risk(_policy.Risk(tool)),
            shouldHonorModelRequestedApproval = _policy.ShouldHonorModelRequestedApproval(tool),
            approval = approval is null
                ? null
                : new
                {
                    tool = BurnBarPlannerWire.ToolKind(approval.Tool),
                    title = approval.Title,
                    message = approval.Message,
                    risk = BurnBarPlannerWire.Risk(approval.Risk),
                },
            retryable = errorCode is null ? null : (bool?)_policy.IsRetryable(errorCode.Value),
            indicatesProgress = toolCall is null
                ? null
                : (bool?)_policy.IndicatesProgress(
                    toolCall.Value.Tool,
                    toolCall.Value.Status,
                    toolCall.Value.HasOutput),
        });
    }

    private static BurnBarToolKind? ParseOptionalTool(JsonElement request, string property)
    {
        if (!request.TryGetProperty(property, out JsonElement element) || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (element.ValueKind != JsonValueKind.String
            || !BurnBarPlannerWire.TryToolKind(element.GetString(), out BurnBarToolKind tool))
        {
            throw new BurnBarPlannerException("invalid_policy_input", $"{property} is unsupported.");
        }
        return tool;
    }

    private static BurnBarToolExecutionErrorCode? ParseOptionalErrorCode(JsonElement request)
    {
        if (!request.TryGetProperty("errorCode", out JsonElement element) || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (element.ValueKind != JsonValueKind.String)
        {
            throw new BurnBarPlannerException("invalid_policy_input", "errorCode must be a string.");
        }
        return element.GetString() switch
        {
            "trust_gated" => BurnBarToolExecutionErrorCode.TrustGated,
            "no_workspace" => BurnBarToolExecutionErrorCode.NoWorkspace,
            "remote_unsupported" => BurnBarToolExecutionErrorCode.RemoteUnsupported,
            "apply_failed" => BurnBarToolExecutionErrorCode.ApplyFailed,
            "terminal_failed" => BurnBarToolExecutionErrorCode.TerminalFailed,
            "unknown" => BurnBarToolExecutionErrorCode.Unknown,
            _ => throw new BurnBarPlannerException("invalid_policy_input", "errorCode is unsupported."),
        };
    }

    private static (BurnBarToolKind Tool, BurnBarToolCallStatus Status, bool HasOutput)? ParseOptionalToolCall(
        JsonElement request)
    {
        if (!request.TryGetProperty("toolCall", out JsonElement element) || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new BurnBarPlannerException("invalid_policy_input", "toolCall must be an object.");
        }
        BurnBarToolKind tool = ParseOptionalTool(element, "tool")
            ?? throw new BurnBarPlannerException("invalid_policy_input", "toolCall.tool is required.");
        if (!element.TryGetProperty("status", out JsonElement statusElement)
            || statusElement.ValueKind != JsonValueKind.String)
        {
            throw new BurnBarPlannerException("invalid_policy_input", "toolCall.status is required.");
        }
        BurnBarToolCallStatus status = statusElement.GetString() switch
        {
            "pending" => BurnBarToolCallStatus.Pending,
            "running" => BurnBarToolCallStatus.Running,
            "awaiting_approval" => BurnBarToolCallStatus.AwaitingApproval,
            "completed" => BurnBarToolCallStatus.Completed,
            "failed" => BurnBarToolCallStatus.Failed,
            _ => throw new BurnBarPlannerException("invalid_policy_input", "toolCall.status is unsupported."),
        };
        bool hasOutput = OptionalBoolean(element, "hasOutput") ?? false;
        return (tool, status, hasOutput);
    }

    private static string? OptionalBoundedString(JsonElement request, string property)
    {
        if (!request.TryGetProperty(property, out JsonElement element) || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (element.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(element.GetString())
            || element.GetString()!.Length > MaxCustomTextCharacters)
        {
            throw new BurnBarPlannerException("invalid_policy_input", $"{property} is invalid.");
        }
        return element.GetString();
    }

    private static bool? OptionalBoolean(JsonElement request, string property)
    {
        if (!request.TryGetProperty(property, out JsonElement element) || element.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (element.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new BurnBarPlannerException("invalid_policy_input", $"{property} must be a boolean.");
        }
        return element.GetBoolean();
    }
}

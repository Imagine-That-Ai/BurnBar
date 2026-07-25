using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Run;

public sealed partial class HeadlessAgentRunService
{
    public async Task<HeadlessAgentRunDetail> RespondToApprovalAsync(
        HeadlessAgentApprovalResponse response,
        CancellationToken cancellationToken = default)
    {
        ThrowIfNotStarted();
        ValidateApprovalResponse(response);
        SemaphoreSlim gate = RunGate(response.RunId);
        bool shouldContinue = false;
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            HeadlessAgentRunCheckpoint checkpoint = await RequireRunAsync(response.RunId, cancellationToken).ConfigureAwait(false);
            RequireClient(checkpoint, response.ClientId);
            if (checkpoint.Phase != HeadlessAgentRunPhase.AwaitingApproval
                || checkpoint.ApprovalRequest is null
                || !string.Equals(checkpoint.ApprovalRequest.ApprovalId, response.ApprovalId, StringComparison.Ordinal))
            {
                throw new HeadlessAgentRunException("approval_already_resolved", "The approval is missing or already resolved.");
            }

            if (response.Decision == HeadlessAgentApprovalDecision.Approve)
            {
                HeadlessAgentToolCall? pendingInvocation = checkpoint.PendingApprovalToolInvocation;
                pendingInvocation = pendingInvocation is null ? null : pendingInvocation with { ApprovalId = response.ApprovalId };
                bool completesRunLevelApproval = pendingInvocation is null && checkpoint.RequiresApproval && !checkpoint.RunLevelApprovalCompleted;
                checkpoint = checkpoint with
                {
                    ApprovalRequest = null,
                    PendingApprovalToolInvocation = null,
                    // A run-level or model-requested approval authorizes only
                    // continuation. It must never become a bearer capability
                    // that a later, different high-risk tool can spend.
                    ApprovalResolvedForAttempt = false,
                    RunLevelApprovalCompleted = checkpoint.RunLevelApprovalCompleted || completesRunLevelApproval,
                    ApprovedToolAuthorizationId = null,
                };
                checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Planning);
                if (pendingInvocation is not null)
                {
                    checkpoint = QueueApprovedTool(checkpoint, pendingInvocation);
                }
                else
                {
                    shouldContinue = true;
                }
                await PersistAsync(checkpoint, "approval_approved", cancellationToken).ConfigureAwait(false);
            }
            else
            {
                string decision = response.Decision == HeadlessAgentApprovalDecision.Reject ? "rejected" : "cancelled";
                checkpoint = checkpoint with
                {
                    ApprovalRequest = null,
                    PendingApprovalToolInvocation = null,
                    PendingToolCall = null,
                    ErrorMessage = Bound(response.Note ?? $"Approval {decision} by controller.", MaximumPromptCharacters),
                };
                checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Cancelled);
                await PersistAsync(checkpoint, "approval_declined", cancellationToken).ConfigureAwait(false);
            }
            return Detail(checkpoint);
        }
        finally
        {
            gate.Release();
            if (shouldContinue) Schedule(response.RunId);
        }
    }
}

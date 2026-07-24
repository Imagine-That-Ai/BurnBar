using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;

namespace OpenBurnBar.App.ManagedAgentRuntime.Run;

/// <summary>
/// Durable daemon-side agent run owner. Requests return after checkpointing;
/// model work continues independently and all workspace side effects are
/// claimed by the authenticated companion before a result can advance a run.
/// </summary>
public sealed partial class HeadlessAgentRunService : IAsyncDisposable
{
    public const int MaximumIdentifierCharacters = 128;
    public const int MaximumPromptCharacters = 32 * 1024;
    public const int MaximumMetadataBytes = 256 * 1024;
    public const int MaximumToolOutputBytes = 256 * 1024;
    public const int MaximumPollResults = 128;
    public static readonly TimeSpan DefaultToolClaimLease = TimeSpan.FromMinutes(2);
    private readonly ModelProxyRouter _router;
    private readonly IModelCompletionExecutor _executor;
    private readonly IHeadlessRunJournal _journal;
    private readonly IHeadlessAgentCheckpointStore _checkpoints;
    private readonly BurnBarPlannerService _planner;
    private readonly BurnBarPolicyEngine _policy;
    private readonly HeadlessAgentLoopService _loop;
    private readonly Func<DateTimeOffset> _now;
    private readonly TimeSpan _toolClaimLease;
    private readonly CancellationTokenSource _shutdown = new();
    private readonly ConcurrentDictionary<string, SemaphoreSlim> _runGates = new(StringComparer.Ordinal);
    private readonly object _stateGate = new();
    private readonly HashSet<string> _runIds = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Task> _backgroundTasks = new(StringComparer.Ordinal);
    private bool _started;
    private bool _disposed;
    public HeadlessAgentRunService(
        ModelProxyRouter router,
        IModelCompletionExecutor executor,
        IHeadlessRunJournal journal,
        IHeadlessAgentCheckpointStore checkpoints,
        BurnBarPlannerService? planner = null,
        BurnBarPolicyEngine? policy = null,
        HeadlessAgentLoopService? loop = null,
        Func<DateTimeOffset>? now = null,
        TimeSpan? toolClaimLease = null)
    {
        _router = router ?? throw new ArgumentNullException(nameof(router));
        _executor = executor ?? throw new ArgumentNullException(nameof(executor));
        _journal = journal ?? throw new ArgumentNullException(nameof(journal));
        _checkpoints = checkpoints ?? throw new ArgumentNullException(nameof(checkpoints));
        _planner = planner ?? new BurnBarPlannerService();
        _policy = policy ?? new BurnBarPolicyEngine();
        _loop = loop ?? new HeadlessAgentLoopService();
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _toolClaimLease = toolClaimLease ?? DefaultToolClaimLease;
        if (_toolClaimLease <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(toolClaimLease));
        }
    }
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        lock (_stateGate)
        {
            if (_started) return;
            _started = true;
        }

        IReadOnlyList<HeadlessRunJournalEntry> entries;
        try
        {
            entries = await _journal.ReadAllAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            lock (_stateGate) _started = false;
            throw;
        }

        foreach (IGrouping<string, HeadlessRunJournalEntry> group in entries.GroupBy(entry => entry.RunId))
        {
            cancellationToken.ThrowIfCancellationRequested();
            string runId = group.Key;
            lock (_stateGate) _runIds.Add(runId);
            HeadlessRunJournalEntry latest = group.OrderBy(entry => entry.RecordedAt).Last();
            if (latest.State is HeadlessRunState.Succeeded or HeadlessRunState.Failed or HeadlessRunState.Cancelled)
            {
                continue;
            }

            HeadlessAgentRunCheckpoint? checkpoint;
            try
            {
                checkpoint = await _checkpoints.LoadAsync(runId, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (error is InvalidDataException or ArgumentException)
            {
                await AppendJournalAsync(runId, HeadlessRunState.Failed, "checkpoint_rejected", "checkpoint_rejected", cancellationToken)
                    .ConfigureAwait(false);
                continue;
            }
            if (checkpoint is null)
            {
                await AppendJournalAsync(runId, HeadlessRunState.Failed, "checkpoint_missing", "checkpoint_missing", cancellationToken)
                    .ConfigureAwait(false);
                continue;
            }

            if (checkpoint.Phase == HeadlessAgentRunPhase.ExecutingTool && checkpoint.PendingToolCall is not null)
            {
                checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.WaitingOnCompanion);
                await PersistAsync(checkpoint, "run_restored", cancellationToken).ConfigureAwait(false);
            }
            if (checkpoint.Phase is HeadlessAgentRunPhase.Planning
                or HeadlessAgentRunPhase.ExecutingTool
                or HeadlessAgentRunPhase.ModelStreaming)
            {
                Schedule(runId);
            }
        }
    }

    public async Task<HeadlessAgentRunSnapshot> SubmitAsync(
        HeadlessAgentRunRequest request,
        CancellationToken cancellationToken = default)
    {
        ThrowIfNotStarted();
        ValidateRequest(request);
        SemaphoreSlim gate = RunGate(request.RunId);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        HeadlessAgentRunCheckpoint checkpoint;
        try
        {
            if (await _checkpoints.LoadAsync(request.RunId, cancellationToken).ConfigureAwait(false) is not null)
            {
                throw new HeadlessAgentRunException("run_already_exists", $"Run '{request.RunId}' already exists.");
            }

            JsonElement metadata = CloneMetadata(request.Metadata);
            BurnBarPlannedRun planned = _planner.PlanRaw(request.Prompt, metadata);
            DateTimeOffset now = _now();
            checkpoint = new HeadlessAgentRunCheckpoint(
                request.RunId.Trim(),
                request.ClientId.Trim(),
                request.SessionId.Trim(),
                HeadlessAgentRunPhase.Planning,
                request.ModelId.Trim(),
                request.Prompt,
                metadata,
                request.RequiresApproval,
                false,
                planned.Intent,
                planned.Outline,
                Attempt: 1,
                ErrorMessage: null,
                ApprovalRequest: null,
                ApprovalResolvedForAttempt: false,
                PendingApprovalToolInvocation: null,
                PendingToolCall: null,
                LastToolCall: null,
                WorkflowStep: 0,
                WorkflowReadContent: null,
                CompanionToolCompleted: false,
                LastRecoveryReason: null,
                LoopState: HeadlessAgentLoopState.Empty,
                UpdatedAt: now);
            await PersistAsync(checkpoint, "run_created", cancellationToken).ConfigureAwait(false);
            lock (_stateGate) _runIds.Add(checkpoint.RunId);
        }
        finally
        {
            gate.Release();
        }

        Schedule(checkpoint.RunId);
        return Snapshot(checkpoint);
    }

    public async Task<HeadlessAgentRunDetail> GetAsync(
        string runId,
        string clientId,
        CancellationToken cancellationToken = default)
    {
        ThrowIfNotStarted();
        ValidateIdentifier(runId, nameof(runId));
        ValidateIdentifier(clientId, nameof(clientId));
        SemaphoreSlim gate = RunGate(runId);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            HeadlessAgentRunCheckpoint checkpoint = await RequireRunAsync(runId, cancellationToken).ConfigureAwait(false);
            RequireClient(checkpoint, clientId);
            return Detail(checkpoint);
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<IReadOnlyList<HeadlessAgentRunSnapshot>> PollAsync(
        string clientId,
        DateTimeOffset? updatedAfter = null,
        int limit = MaximumPollResults,
        CancellationToken cancellationToken = default)
    {
        ThrowIfNotStarted();
        ValidateIdentifier(clientId, nameof(clientId));
        int boundedLimit = Math.Clamp(limit, 1, MaximumPollResults);
        string[] runIds;
        lock (_stateGate) runIds = _runIds.ToArray();
        var snapshots = new List<HeadlessAgentRunSnapshot>();
        foreach (string runId in runIds)
        {
            cancellationToken.ThrowIfCancellationRequested();
            HeadlessAgentRunCheckpoint? checkpoint = await _checkpoints.LoadAsync(runId, cancellationToken).ConfigureAwait(false);
            if (checkpoint is null
                || !string.Equals(checkpoint.ClientId, clientId, StringComparison.Ordinal)
                || (updatedAfter is not null && checkpoint.UpdatedAt <= updatedAfter))
            {
                continue;
            }
            snapshots.Add(Snapshot(checkpoint));
        }
        return snapshots
            .OrderByDescending(snapshot => snapshot.UpdatedAt)
            .Take(boundedLimit)
            .ToArray();
    }

    public async Task<HeadlessAgentToolClaimResponse> ClaimToolAsync(
        string runId,
        string clientId,
        string sessionId,
        CancellationToken cancellationToken = default)
    {
        ThrowIfNotStarted();
        ValidateIdentifier(runId, nameof(runId));
        ValidateIdentifier(clientId, nameof(clientId));
        ValidateIdentifier(sessionId, nameof(sessionId));
        SemaphoreSlim gate = RunGate(runId);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            HeadlessAgentRunCheckpoint? checkpoint = await _checkpoints.LoadAsync(runId, cancellationToken).ConfigureAwait(false);
            if (checkpoint is null) return new HeadlessAgentToolClaimResponse(HeadlessAgentToolDisposition.RunNotFound);
            RequireController(checkpoint, clientId, sessionId);
            HeadlessAgentToolCall? call = checkpoint.PendingToolCall;
            if (checkpoint.Phase != HeadlessAgentRunPhase.WaitingOnCompanion || call is null)
            {
                return new HeadlessAgentToolClaimResponse(HeadlessAgentToolDisposition.NoPendingToolCall);
            }

            DateTimeOffset now = _now();
            bool liveLease = call.Status == BurnBarToolCallStatus.Running
                && call.ClaimedAt is not null
                && now - call.ClaimedAt.Value < _toolClaimLease;
            if (liveLease && !string.Equals(call.ClaimedBy, clientId, StringComparison.Ordinal))
            {
                return new HeadlessAgentToolClaimResponse(HeadlessAgentToolDisposition.NoPendingToolCall);
            }
            if (!liveLease || string.Equals(call.ClaimedBy, clientId, StringComparison.Ordinal))
            {
                call = call with
                {
                    Status = BurnBarToolCallStatus.Running,
                    ClaimedBy = clientId,
                    ClaimedAt = liveLease ? call.ClaimedAt : now,
                };
                checkpoint = checkpoint with { PendingToolCall = call, UpdatedAt = now };
                await PersistAsync(checkpoint, "tool_claimed", cancellationToken).ConfigureAwait(false);
            }
            return new HeadlessAgentToolClaimResponse(HeadlessAgentToolDisposition.Dispatched, call);
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task<HeadlessAgentRunDetail> SubmitToolResultAsync(
        HeadlessAgentToolResultSubmission submission,
        CancellationToken cancellationToken = default)
    {
        ThrowIfNotStarted();
        ValidateToolResult(submission);
        SemaphoreSlim gate = RunGate(submission.RunId);
        bool shouldContinue = false;
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            HeadlessAgentRunCheckpoint checkpoint = await RequireRunAsync(submission.RunId, cancellationToken).ConfigureAwait(false);
            RequireController(checkpoint, submission.ClientId, submission.SessionId);
            if (checkpoint.PendingToolCall is null
                && string.Equals(checkpoint.LastToolCall?.CallId, submission.CallId, StringComparison.Ordinal))
            {
                return Detail(checkpoint);
            }
            HeadlessAgentToolCall call = checkpoint.PendingToolCall
                ?? throw new HeadlessAgentRunException("tool_call_not_pending", "The tool call is not pending.");
            if (!string.Equals(call.CallId, submission.CallId, StringComparison.Ordinal))
            {
                throw new HeadlessAgentRunException("tool_call_mismatch", "The submitted tool call id does not match.");
            }
            if (call.Status != BurnBarToolCallStatus.Running
                || !string.Equals(call.ClaimedBy, submission.ClientId, StringComparison.Ordinal))
            {
                throw new HeadlessAgentRunException("tool_not_claimed", "The companion must claim the tool call before submitting its result.");
            }
            if (submission.CompletedAt < call.RequestedAt)
            {
                throw new HeadlessAgentRunException("invalid_tool_completion_time", "The tool completion predates the tool request.");
            }

            checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.ExecutingTool);
            call = call with
            {
                Status = submission.Succeeded ? BurnBarToolCallStatus.Completed : BurnBarToolCallStatus.Failed,
                CompletedAt = submission.CompletedAt,
                Output = submission.Output?.Clone(),
                Error = submission.Error,
            };
            checkpoint = checkpoint with { PendingToolCall = null, LastToolCall = call };
            if (submission.Succeeded)
            {
                try
                {
                    checkpoint = ApplySuccessfulToolResult(checkpoint, call);
                    checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Planning);
                    await PersistAsync(checkpoint, "tool_completed", cancellationToken).ConfigureAwait(false);
                    shouldContinue = true;
                }
                catch (HeadlessAgentRunException validationError)
                {
                    call = call with
                    {
                        Status = BurnBarToolCallStatus.Failed,
                        Error = new HeadlessAgentToolError(
                            BurnBarToolExecutionErrorCode.Unknown,
                            validationError.Message),
                    };
                    checkpoint = checkpoint with { LastToolCall = call };
                    checkpoint = await RecoverToolFailureAsync(checkpoint, call, cancellationToken).ConfigureAwait(false);
                }
            }
            else
            {
                checkpoint = await RecoverToolFailureAsync(checkpoint, call, cancellationToken).ConfigureAwait(false);
                shouldContinue = checkpoint.Phase == HeadlessAgentRunPhase.Planning;
            }
            return Detail(checkpoint);
        }
        finally
        {
            gate.Release();
            if (shouldContinue) Schedule(submission.RunId);
        }
    }

    public Task<HeadlessAgentRunDetail> CancelAsync(
        string runId,
        string clientId,
        string? reason = null,
        CancellationToken cancellationToken = default) =>
        ChangeTerminalStateAsync(runId, clientId, HeadlessAgentRunPhase.Cancelled, reason ?? "Run cancelled by controller.", cancellationToken);

    public async Task<HeadlessAgentRunDetail> RetryAsync(
        string runId,
        string clientId,
        CancellationToken cancellationToken = default)
    {
        ThrowIfNotStarted();
        ValidateIdentifier(runId, nameof(runId));
        ValidateIdentifier(clientId, nameof(clientId));
        SemaphoreSlim gate = RunGate(runId);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        HeadlessAgentRunCheckpoint checkpoint;
        try
        {
            checkpoint = await RequireRunAsync(runId, cancellationToken).ConfigureAwait(false);
            RequireClient(checkpoint, clientId);
            if (checkpoint.Phase != HeadlessAgentRunPhase.Failed)
            {
                throw new HeadlessAgentRunException("run_not_retryable", "Only a failed run can be retried.");
            }
            checkpoint = checkpoint with
            {
                Attempt = checkpoint.Attempt + 1,
                ErrorMessage = null,
                ApprovalRequest = null,
                PendingApprovalToolInvocation = null,
                PendingToolCall = null,
                ApprovalResolvedForAttempt = false,
                RunLevelApprovalCompleted = false,
                LastRecoveryReason = null,
                ApprovedToolAuthorizationId = null,
            };
            checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Planning);
            await PersistAsync(checkpoint, "run_retried", cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
        Schedule(runId);
        return Detail(checkpoint);
    }

    public async Task<IReadOnlyList<HeadlessAgentRunSnapshot>> RecoverAsync(
        string clientId,
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<HeadlessAgentRunSnapshot> all = await PollAsync(
            clientId,
            updatedAfter: null,
            MaximumPollResults,
            cancellationToken).ConfigureAwait(false);
        return all.Where(snapshot => !HeadlessAgentRunStateMachine.IsTerminal(snapshot.Phase)).ToArray();
    }

    public async ValueTask DisposeAsync()
    {
        Task[] tasks;
        lock (_stateGate)
        {
            if (_disposed) return;
            _disposed = true;
            _shutdown.Cancel();
            tasks = _backgroundTasks.Values.ToArray();
        }
        try
        {
            await Task.WhenAll(tasks).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        _shutdown.Dispose();
        foreach (SemaphoreSlim gate in _runGates.Values) gate.Dispose();
    }

    private async Task<HeadlessAgentRunDetail> ChangeTerminalStateAsync(
        string runId,
        string clientId,
        HeadlessAgentRunPhase phase,
        string message,
        CancellationToken cancellationToken)
    {
        ThrowIfNotStarted();
        ValidateIdentifier(runId, nameof(runId));
        ValidateIdentifier(clientId, nameof(clientId));
        SemaphoreSlim gate = RunGate(runId);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            HeadlessAgentRunCheckpoint checkpoint = await RequireRunAsync(runId, cancellationToken).ConfigureAwait(false);
            RequireClient(checkpoint, clientId);
            if (!HeadlessAgentRunStateMachine.IsTerminal(checkpoint.Phase))
            {
                checkpoint = checkpoint with
                {
                    ApprovalRequest = null,
                    PendingApprovalToolInvocation = null,
                    PendingToolCall = null,
                    ErrorMessage = Bound(message, MaximumPromptCharacters),
                };
                checkpoint = Transition(checkpoint, phase);
                await PersistAsync(checkpoint, "run_cancelled", cancellationToken).ConfigureAwait(false);
            }
            return Detail(checkpoint);
        }
        finally
        {
            gate.Release();
        }
    }

    private void Schedule(string runId)
    {
        lock (_stateGate)
        {
            if (_disposed || _backgroundTasks.ContainsKey(runId)) return;
            _backgroundTasks[runId] = Task.Run(() => RunScheduledAsync(runId), CancellationToken.None);
        }
    }

    private async Task RunScheduledAsync(string runId)
    {
        try
        {
            await ProcessRunAsync(runId, _shutdown.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested)
        {
        }
        catch (Exception error)
        {
            await FailRunAfterUnhandledErrorAsync(runId, error).ConfigureAwait(false);
        }
        finally
        {
            lock (_stateGate) _backgroundTasks.Remove(runId);
            if (await NeedsProcessingAsync(runId).ConfigureAwait(false)) Schedule(runId);
        }
    }

    private async Task<bool> NeedsProcessingAsync(string runId)
    {
        if (_shutdown.IsCancellationRequested) return false;
        try
        {
            HeadlessAgentRunCheckpoint? checkpoint = await _checkpoints.LoadAsync(runId, CancellationToken.None)
                .ConfigureAwait(false);
            return checkpoint?.Phase is HeadlessAgentRunPhase.Planning
                or HeadlessAgentRunPhase.ExecutingTool
                or HeadlessAgentRunPhase.ModelStreaming;
        }
        catch (Exception error) when (error is IOException or InvalidDataException or ArgumentException)
        {
            return false;
        }
    }

    private async Task FailRunAfterUnhandledErrorAsync(string runId, Exception error)
    {
        SemaphoreSlim gate = RunGate(runId);
        await gate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
        try
        {
            HeadlessAgentRunCheckpoint? checkpoint = await _checkpoints.LoadAsync(runId, CancellationToken.None).ConfigureAwait(false);
            if (checkpoint is null || HeadlessAgentRunStateMachine.IsTerminal(checkpoint.Phase)) return;
            string message = error is HeadlessAgentRunException agentError
                ? agentError.Message
                : "OpenBurnBar stopped the run after an internal execution failure.";
            checkpoint = checkpoint with { ErrorMessage = Bound(message, MaximumPromptCharacters) };
            checkpoint = Transition(checkpoint, HeadlessAgentRunPhase.Failed);
            await PersistAsync(checkpoint, "run_failed", CancellationToken.None, "agent_run_failed").ConfigureAwait(false);
        }
        catch (Exception persistenceError) when (persistenceError is IOException or InvalidDataException)
        {
            await AppendJournalAsync(runId, HeadlessRunState.Failed, "run_failed", "checkpoint_persist_failed", CancellationToken.None)
                .ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<HeadlessAgentRunCheckpoint> RequireRunAsync(
        string runId,
        CancellationToken cancellationToken) =>
        await _checkpoints.LoadAsync(runId, cancellationToken).ConfigureAwait(false)
        ?? throw new HeadlessAgentRunException("run_not_found", $"Run '{runId}' was not found.");

    private async Task PersistAsync(
        HeadlessAgentRunCheckpoint checkpoint,
        string eventKind,
        CancellationToken cancellationToken,
        string? safeErrorCode = null)
    {
        await _checkpoints.SaveAsync(checkpoint, cancellationToken).ConfigureAwait(false);
        HeadlessRunState journalState = checkpoint.Phase switch
        {
            HeadlessAgentRunPhase.Completed => HeadlessRunState.Succeeded,
            HeadlessAgentRunPhase.Failed => HeadlessRunState.Failed,
            HeadlessAgentRunPhase.Cancelled => HeadlessRunState.Cancelled,
            _ => HeadlessRunState.Running,
        };
        await AppendJournalAsync(checkpoint.RunId, journalState, eventKind, safeErrorCode, cancellationToken)
            .ConfigureAwait(false);
    }

    private Task AppendJournalAsync(
        string runId,
        HeadlessRunState state,
        string eventKind,
        string? safeErrorCode,
        CancellationToken cancellationToken) =>
        _journal.AppendAsync(new HeadlessRunJournalEntry(runId, state, eventKind, safeErrorCode, _now()), cancellationToken);

    private HeadlessAgentRunCheckpoint Transition(
        HeadlessAgentRunCheckpoint checkpoint,
        HeadlessAgentRunPhase phase)
    {
        if (checkpoint.Phase != phase)
        {
            HeadlessAgentRunStateMachine.RequireTransition(checkpoint.Phase, phase);
        }
        return checkpoint with { Phase = phase, UpdatedAt = _now() };
    }

    private static HeadlessAgentRunSnapshot Snapshot(HeadlessAgentRunCheckpoint checkpoint) => new(
        checkpoint.RunId,
        checkpoint.ClientId,
        checkpoint.SessionId,
        checkpoint.Phase,
        checkpoint.ModelId,
        checkpoint.UpdatedAt,
        checkpoint.ErrorMessage,
        checkpoint.ApprovalRequest?.ApprovalId);

    private static HeadlessAgentRunDetail Detail(HeadlessAgentRunCheckpoint checkpoint) => new(
        Snapshot(checkpoint),
        checkpoint.ApprovalRequest,
        checkpoint.PendingToolCall,
        checkpoint.LoopState);

    private SemaphoreSlim RunGate(string runId) =>
        _runGates.GetOrAdd(runId, static _ => new SemaphoreSlim(1, 1));

    private void ThrowIfNotStarted()
    {
        ThrowIfDisposed();
        lock (_stateGate)
        {
            if (!_started) throw new InvalidOperationException("The headless agent run service has not started.");
        }
    }

    private void ThrowIfDisposed()
    {
        lock (_stateGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
        }
    }

    private static void RequireClient(HeadlessAgentRunCheckpoint checkpoint, string clientId)
    {
        if (!string.Equals(checkpoint.ClientId, clientId, StringComparison.Ordinal))
        {
            throw new HeadlessAgentRunException("client_not_authorized", "The client does not own this run.");
        }
    }

    private static void RequireController(
        HeadlessAgentRunCheckpoint checkpoint,
        string clientId,
        string sessionId)
    {
        RequireClient(checkpoint, clientId);
        if (!string.Equals(checkpoint.SessionId, sessionId, StringComparison.Ordinal))
        {
            throw new HeadlessAgentRunException("session_not_authorized", "The companion session does not own this run.");
        }
    }

    private static void ValidateRequest(HeadlessAgentRunRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ValidateIdentifier(request.RunId, nameof(request.RunId), pathSafe: true);
        ValidateIdentifier(request.ClientId, nameof(request.ClientId));
        ValidateIdentifier(request.SessionId, nameof(request.SessionId));
        ValidateText(request.Prompt, nameof(request.Prompt), MaximumPromptCharacters);
        ValidateText(request.ModelId, nameof(request.ModelId), GatewayRouteConfiguration.MaximumModelLength);
        _ = CloneMetadata(request.Metadata);
    }

    private static void ValidateToolResult(HeadlessAgentToolResultSubmission submission)
    {
        ArgumentNullException.ThrowIfNull(submission);
        ValidateIdentifier(submission.RunId, nameof(submission.RunId), pathSafe: true);
        ValidateIdentifier(submission.CallId, nameof(submission.CallId));
        ValidateIdentifier(submission.ClientId, nameof(submission.ClientId));
        ValidateIdentifier(submission.SessionId, nameof(submission.SessionId));
        if (submission.Output is JsonElement output
            && Encoding.UTF8.GetByteCount(output.GetRawText()) > MaximumToolOutputBytes)
        {
            throw new HeadlessAgentRunException("tool_output_too_large", "The companion tool output exceeds the size limit.");
        }
        if (!submission.Succeeded && submission.Error is null)
        {
            throw new HeadlessAgentRunException("tool_error_required", "A failed tool result requires a structured error.");
        }
        if (submission.Error?.Message.Length > MaximumPromptCharacters)
        {
            throw new HeadlessAgentRunException("tool_error_too_large", "The companion tool error exceeds the size limit.");
        }
    }

    private static void ValidateApprovalResponse(HeadlessAgentApprovalResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        ValidateIdentifier(response.RunId, nameof(response.RunId), pathSafe: true);
        ValidateIdentifier(response.ApprovalId, nameof(response.ApprovalId));
        ValidateIdentifier(response.ClientId, nameof(response.ClientId));
        if (response.Note?.Length > MaximumPromptCharacters)
        {
            throw new HeadlessAgentRunException("approval_note_too_large", "The approval note exceeds the size limit.");
        }
    }

    private static JsonElement CloneMetadata(JsonElement? metadata)
    {
        if (metadata is JsonElement supplied && supplied.ValueKind != JsonValueKind.Object)
        {
            throw new HeadlessAgentRunException("invalid_metadata", "Run metadata must be an object.");
        }
        JsonElement clone = metadata is { ValueKind: JsonValueKind.Object } value
            ? value.Clone()
            : JsonSerializer.SerializeToElement(new { });
        if (Encoding.UTF8.GetByteCount(clone.GetRawText()) > MaximumMetadataBytes)
        {
            throw new HeadlessAgentRunException("metadata_too_large", "Run metadata exceeds the size limit.");
        }
        return clone;
    }

    private static void ValidateIdentifier(string value, string name, bool pathSafe = false)
    {
        ValidateText(value, name, MaximumIdentifierCharacters);
        if (pathSafe) HeadlessAgentCheckpointCodec.ValidateRunId(value.Trim());
    }

    private static void ValidateText(string value, string name, int maximum)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Trim().Length > maximum || value.Any(char.IsControl))
        {
            throw new HeadlessAgentRunException("invalid_run_request", $"{name} must be a bounded non-control string.");
        }
    }

    private static string Bound(string value, int maximum) => value.Length <= maximum ? value : value[..maximum];
}

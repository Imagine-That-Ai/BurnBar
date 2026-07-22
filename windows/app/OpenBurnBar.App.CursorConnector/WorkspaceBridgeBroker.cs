using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace OpenBurnBar.App.CursorConnector;

public enum WorkspaceToolCallStatus { Pending, InProgress, Completed, Failed, Cancelled }

public sealed record WorkspaceToolInvocation(
    string CallId,
    string RunId,
    string Tool,
    JsonElement Arguments,
    string RequestedBy,
    DateTimeOffset RequestedAt);

public sealed record WorkspaceToolCallSnapshot(
    string CallId,
    string RunId,
    string Tool,
    JsonElement Arguments,
    WorkspaceToolCallStatus Status,
    string RequestedBy,
    DateTimeOffset RequestedAt,
    string? ClaimedBy = null,
    DateTimeOffset? ClaimedAt = null,
    DateTimeOffset? CompletedAt = null,
    JsonElement? Output = null,
    string? Error = null);

public sealed record WorkspaceToolResultSubmission(
    string RunId,
    string CallId,
    bool Succeeded,
    JsonElement? Output,
    string? Error,
    DateTimeOffset CompletedAt);

public sealed class WorkspaceBridgeBroker
{
    private readonly object _sync = new();
    private readonly Dictionary<string, WorkspaceToolCallSnapshot> _active = new(StringComparer.Ordinal);
    private readonly IConnectorClock _clock;

    public WorkspaceBridgeBroker(IConnectorClock? clock = null) =>
        _clock = clock ?? SystemConnectorClock.Instance;

    public WorkspaceToolCallSnapshot Enqueue(WorkspaceToolInvocation invocation)
    {
        ArgumentNullException.ThrowIfNull(invocation);
        lock (_sync)
        {
            if (_active.ContainsKey(invocation.RunId))
                throw new InvalidOperationException($"Run '{invocation.RunId}' already has an active workspace tool call.");
            var snapshot = new WorkspaceToolCallSnapshot(invocation.CallId, invocation.RunId, invocation.Tool,
                invocation.Arguments.Clone(), WorkspaceToolCallStatus.Pending, invocation.RequestedBy, invocation.RequestedAt);
            _active.Add(invocation.RunId, snapshot);
            return snapshot;
        }
    }

    public WorkspaceToolCallSnapshot? ActiveCall(string runId)
    {
        lock (_sync) return _active.GetValueOrDefault(runId);
    }

    public IReadOnlyList<WorkspaceToolCallSnapshot> ActiveCalls(IReadOnlySet<string>? runIds = null)
    {
        lock (_sync) return _active.Values
            .Where(call => runIds is null || runIds.Contains(call.RunId))
            .OrderByDescending(call => call.RequestedAt).ToArray();
    }

    public WorkspaceToolCallSnapshot? Claim(string? runId, string clientId)
    {
        if (string.IsNullOrWhiteSpace(clientId)) throw new ArgumentException("Client ID is required.", nameof(clientId));
        lock (_sync)
        {
            WorkspaceToolCallSnapshot? current = runId is null
                ? _active.Values.Where(IsClaimable).OrderBy(call => call.RequestedAt).FirstOrDefault()
                : _active.GetValueOrDefault(runId);
            if (current is null) return null;
            if (current.Status == WorkspaceToolCallStatus.InProgress)
                return string.Equals(current.ClaimedBy, clientId, StringComparison.Ordinal) ? current : null;
            if (current.Status != WorkspaceToolCallStatus.Pending) return null;
            WorkspaceToolCallSnapshot claimed = current with
            {
                Status = WorkspaceToolCallStatus.InProgress,
                ClaimedBy = clientId,
                ClaimedAt = _clock.UtcNow,
            };
            _active[current.RunId] = claimed;
            return claimed;
        }
    }

    public WorkspaceToolCallSnapshot Complete(WorkspaceToolResultSubmission result)
    {
        ArgumentNullException.ThrowIfNull(result);
        lock (_sync)
        {
            if (!_active.TryGetValue(result.RunId, out WorkspaceToolCallSnapshot? current))
                throw new InvalidOperationException($"Tool call '{result.CallId}' for run '{result.RunId}' was not found.");
            if (!string.Equals(current.CallId, result.CallId, StringComparison.Ordinal)
                || current.Status is not (WorkspaceToolCallStatus.Pending or WorkspaceToolCallStatus.InProgress))
                throw new InvalidOperationException($"Tool result '{result.CallId}' for run '{result.RunId}' is stale.");
            WorkspaceToolCallSnapshot completed = current with
            {
                Status = result.Succeeded ? WorkspaceToolCallStatus.Completed : WorkspaceToolCallStatus.Failed,
                CompletedAt = result.CompletedAt,
                Output = result.Output?.Clone(),
                Error = result.Error,
            };
            _active[result.RunId] = completed;
            return completed;
        }
    }

    public WorkspaceToolCallSnapshot? Clear(string runId, string callId)
    {
        lock (_sync)
        {
            if (!_active.TryGetValue(runId, out WorkspaceToolCallSnapshot? current)
                || !string.Equals(current.CallId, callId, StringComparison.Ordinal)) return null;
            _active.Remove(runId);
            return current;
        }
    }

    public WorkspaceToolCallSnapshot? Cancel(string runId)
    {
        lock (_sync)
        {
            if (!_active.Remove(runId, out WorkspaceToolCallSnapshot? current)) return null;
            return current with
            {
                Status = WorkspaceToolCallStatus.Cancelled,
                CompletedAt = _clock.UtcNow,
                Output = null,
                Error = "Cancelled while waiting for workspace completion.",
            };
        }
    }

    public void Restore(WorkspaceToolCallSnapshot snapshot)
    {
        if (snapshot.Status is not (WorkspaceToolCallStatus.Pending or WorkspaceToolCallStatus.InProgress)) return;
        lock (_sync) _active[snapshot.RunId] = snapshot;
    }

    private static bool IsClaimable(WorkspaceToolCallSnapshot call) =>
        call.Status is WorkspaceToolCallStatus.Pending or WorkspaceToolCallStatus.InProgress;
}

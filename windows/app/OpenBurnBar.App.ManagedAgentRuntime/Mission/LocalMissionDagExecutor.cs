using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Run;

namespace OpenBurnBar.App.ManagedAgentRuntime.Mission;

public sealed record MissionNode(
    string Id,
    string Kind,
    string Payload,
    IReadOnlyList<string>? DependsOn = null)
{
    public IReadOnlyList<string> Dependencies { get; } =
        DependsOn is null ? Array.Empty<string>() : DependsOn.ToArray();
}

public sealed record MissionDefinition(string MissionId, IReadOnlyList<MissionNode> Nodes);

public sealed record MissionPolicy(
    int MaxNodes = 128,
    IReadOnlySet<string>? AllowedKinds = null,
    bool RequireApproval = false,
    int MaxPayloadBytes = 256 * 1024,
    int MaxExecutionsPerMinute = 60);

public sealed record MissionStepResult(bool Succeeded, string? Error = null)
{
    public static MissionStepResult Ok() => new(true);

    public static MissionStepResult Fail(string error) => new(false, error);
}

public sealed record MissionExecutionResult(
    string MissionId,
    HeadlessRunState State,
    IReadOnlyList<string> CompletedNodeIds,
    string? FailedNodeId,
    string? Error);

/// <summary>
/// Local Mission Control execution with policy gates, DAG validation, durable
/// run journaling, cancellation, and deterministic recovery semantics.
/// </summary>
public sealed class LocalMissionDagExecutor
{
    private readonly HeadlessRunService _runs;
    private readonly Func<MissionNode, CancellationToken, Task<bool>> _approval;
    private readonly MissionRateLimiter? _rateLimiter;

    public LocalMissionDagExecutor(
        HeadlessRunService runs,
        Func<MissionNode, CancellationToken, Task<bool>>? approval = null,
        MissionRateLimiter? rateLimiter = null)
    {
        _runs = runs ?? throw new ArgumentNullException(nameof(runs));
        _approval = approval ?? ((_, _) => Task.FromResult(true));
        _rateLimiter = rateLimiter;
    }

    public async Task<MissionExecutionResult> ExecuteAsync(
        MissionDefinition definition,
        MissionPolicy policy,
        Func<MissionNode, CancellationToken, Task<MissionStepResult>> handler,
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<MissionNode> plan = MissionPlanner.Plan(definition, policy);
        ArgumentNullException.ThrowIfNull(handler);
        MissionRateLimiter rateLimiter = _rateLimiter
            ?? new MissionRateLimiter(policy.MaxExecutionsPerMinute, TimeSpan.FromMinutes(1));

        var runDefinition = new HeadlessRunDefinition(
            definition.MissionId,
            plan.Select(node => new HeadlessRunStep(
                node.Id,
                node.Kind,
                node.Payload,
                node.Dependencies)).ToArray());
        var nodes = definition.Nodes.ToDictionary(node => node.Id, StringComparer.Ordinal);
        HeadlessRunResult result = await _runs.ExecuteAsync(runDefinition, async (step, token) =>
        {
            MissionNode node = nodes[step.Id];
            if (policy.RequireApproval && !await _approval(node, token).ConfigureAwait(false))
            {
                return HeadlessRunStepResult.Fail("mission_step_not_approved");
            }

            if (!rateLimiter.TryAcquire())
            {
                return HeadlessRunStepResult.Fail("mission_rate_limit_exceeded");
            }

            MissionStepResult stepResult = await handler(node, token).ConfigureAwait(false);
            return new HeadlessRunStepResult(stepResult.Succeeded, stepResult.Error);
        }, cancellationToken).ConfigureAwait(false);

        return new MissionExecutionResult(
            definition.MissionId,
            result.State,
            result.CompletedStepIds,
            result.FailedStepId,
            result.Error);
    }

    public async Task<MissionExecutionResult> ResumeAsync(
        MissionDefinition definition,
        MissionPolicy policy,
        Func<MissionNode, CancellationToken, Task<MissionStepResult>> handler,
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<MissionNode> plan = MissionPlanner.Plan(definition, policy);
        ArgumentNullException.ThrowIfNull(handler);
        MissionRateLimiter rateLimiter = _rateLimiter
            ?? new MissionRateLimiter(policy.MaxExecutionsPerMinute, TimeSpan.FromMinutes(1));
        var runDefinition = new HeadlessRunDefinition(
            definition.MissionId,
            plan.Select(node => new HeadlessRunStep(
                node.Id,
                node.Kind,
                node.Payload,
                node.Dependencies)).ToArray());
        var nodes = definition.Nodes.ToDictionary(node => node.Id, StringComparer.Ordinal);
        HeadlessRunResult result = await _runs.ResumeAsync(runDefinition, async (step, token) =>
        {
            MissionNode node = nodes[step.Id];
            if (policy.RequireApproval && !await _approval(node, token).ConfigureAwait(false))
            {
                return HeadlessRunStepResult.Fail("mission_step_not_approved");
            }

            if (!rateLimiter.TryAcquire())
            {
                return HeadlessRunStepResult.Fail("mission_rate_limit_exceeded");
            }

            MissionStepResult stepResult = await handler(node, token).ConfigureAwait(false);
            return new HeadlessRunStepResult(stepResult.Succeeded, stepResult.Error);
        }, cancellationToken).ConfigureAwait(false);

        return new MissionExecutionResult(
            definition.MissionId,
            result.State,
            result.CompletedStepIds,
            result.FailedStepId,
            result.Error);
    }

}

/// <summary>
/// Deterministic Kahn planner for mission DAGs. It validates the entire graph
/// before the durable run journal is touched, so malformed missions fail
/// closed without leaving a misleading queued record behind.
/// </summary>
public static class MissionPlanner
{
    public static IReadOnlyList<MissionNode> Plan(MissionDefinition definition, MissionPolicy policy)
    {
        ArgumentNullException.ThrowIfNull(definition);
        ArgumentNullException.ThrowIfNull(policy);
        if (string.IsNullOrWhiteSpace(definition.MissionId))
        {
            throw new ArgumentException("A mission id is required.", nameof(definition));
        }

        if (definition.Nodes.Count == 0 || definition.Nodes.Count > policy.MaxNodes)
        {
            throw new ArgumentException("Mission node count is outside the configured policy.", nameof(definition));
        }

        if (policy.MaxPayloadBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(policy), "Mission payload bounds must be positive.");
        }

        if (policy.MaxExecutionsPerMinute <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(policy), "Mission execution rate must be positive.");
        }

        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (MissionNode node in definition.Nodes)
        {
            if (string.IsNullOrWhiteSpace(node.Id) || !ids.Add(node.Id))
            {
                throw new ArgumentException("Mission node ids must be unique and non-empty.", nameof(definition));
            }

            if (policy.AllowedKinds is not null && !policy.AllowedKinds.Contains(node.Kind))
            {
                throw new ArgumentException($"Mission node kind '{node.Kind}' is not allowed by policy.", nameof(definition));
            }

            if (Encoding.UTF8.GetByteCount(node.Payload ?? string.Empty) > policy.MaxPayloadBytes)
            {
                throw new ArgumentException($"Mission node '{node.Id}' exceeds the payload bound.", nameof(definition));
            }
        }

        var nodes = definition.Nodes.ToDictionary(node => node.Id, StringComparer.Ordinal);
        var order = definition.Nodes
            .Select((node, index) => (node.Id, index))
            .ToDictionary(item => item.Id, item => item.index, StringComparer.Ordinal);
        var incoming = definition.Nodes.ToDictionary(
            node => node.Id,
            node => node.Dependencies.Count,
            StringComparer.Ordinal);
        var dependents = definition.Nodes.ToDictionary(
            node => node.Id,
            _ => new List<string>(),
            StringComparer.Ordinal);
        foreach (MissionNode node in definition.Nodes)
        {
            if (node.Dependencies.Any(dependency => !ids.Contains(dependency)))
            {
                throw new ArgumentException($"Mission node '{node.Id}' references a missing dependency.", nameof(definition));
            }

            foreach (string dependency in node.Dependencies)
            {
                dependents[dependency].Add(node.Id);
            }
        }

        var ready = new List<string>(definition.Nodes.Where(node => incoming[node.Id] == 0).Select(node => node.Id));
        var planned = new List<MissionNode>(definition.Nodes.Count);
        while (ready.Count > 0)
        {
            ready.Sort((left, right) => order[left].CompareTo(order[right]));
            string id = ready[0];
            ready.RemoveAt(0);
            planned.Add(nodes[id]);
            foreach (string dependent in dependents[id])
            {
                incoming[dependent]--;
                if (incoming[dependent] == 0)
                {
                    ready.Add(dependent);
                }
            }
        }

        if (planned.Count != definition.Nodes.Count)
        {
            throw new ArgumentException("Mission dependencies contain a cycle.", nameof(definition));
        }

        return planned;
    }
}

/// <summary>
/// Small, thread-safe fixed-window limiter shared by local mission runs. It
/// never sleeps or silently queues unbounded work; callers receive a fail-closed
/// result when the configured window is exhausted.
/// </summary>
public sealed class MissionRateLimiter
{
    private readonly int _maximum;
    private readonly TimeSpan _window;
    private readonly Func<DateTimeOffset> _now;
    private readonly Queue<DateTimeOffset> _acquisitions = new();
    private readonly object _gate = new();

    public MissionRateLimiter(
        int maximum,
        TimeSpan window,
        Func<DateTimeOffset>? now = null)
    {
        if (maximum <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maximum));
        }

        if (window <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(window));
        }

        _maximum = maximum;
        _window = window;
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public bool TryAcquire()
    {
        DateTimeOffset now = _now();
        lock (_gate)
        {
            while (_acquisitions.Count > 0 && now - _acquisitions.Peek() >= _window)
            {
                _acquisitions.Dequeue();
            }

            if (_acquisitions.Count >= _maximum)
            {
                return false;
            }

            _acquisitions.Enqueue(now);
            return true;
        }
    }
}

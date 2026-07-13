using System;
using System.Collections.Generic;
using System.Linq;
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
    bool RequireApproval = false);

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

    public LocalMissionDagExecutor(
        HeadlessRunService runs,
        Func<MissionNode, CancellationToken, Task<bool>>? approval = null)
    {
        _runs = runs ?? throw new ArgumentNullException(nameof(runs));
        _approval = approval ?? ((_, _) => Task.FromResult(true));
    }

    public async Task<MissionExecutionResult> ExecuteAsync(
        MissionDefinition definition,
        MissionPolicy policy,
        Func<MissionNode, CancellationToken, Task<MissionStepResult>> handler,
        CancellationToken cancellationToken = default)
    {
        Validate(definition, policy);
        ArgumentNullException.ThrowIfNull(handler);

        var runDefinition = new HeadlessRunDefinition(
            definition.MissionId,
            definition.Nodes.Select(node => new HeadlessRunStep(
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
        Validate(definition, policy);
        ArgumentNullException.ThrowIfNull(handler);
        var runDefinition = new HeadlessRunDefinition(
            definition.MissionId,
            definition.Nodes.Select(node => new HeadlessRunStep(
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

    private static void Validate(MissionDefinition definition, MissionPolicy policy)
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
        }

        foreach (MissionNode node in definition.Nodes)
        {
            if (node.Dependencies.Any(dependency => !ids.Contains(dependency)))
            {
                throw new ArgumentException($"Mission node '{node.Id}' references a missing dependency.", nameof(definition));
            }
        }
    }
}

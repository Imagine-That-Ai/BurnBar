using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Run;

namespace OpenBurnBar.App.ManagedAgentRuntime.Mission;

/// <summary>
/// Authenticated companion-plane adapter for the local Mission DAG executor.
/// Production permits only the same non-shell built-ins as headless recovery;
/// provider/tool execution requires a separately approved handler.
/// </summary>
public sealed class CompanionCliMissionHandler
{
    private const int MaxNodes = 128;
    private const int MaxPayloadCharacters = 64 * 1024;
    private static readonly IReadOnlySet<string> AllowedKinds =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "noop", "health", "delay" };

    private readonly LocalMissionDagExecutor _executor;

    public CompanionCliMissionHandler(LocalMissionDagExecutor executor)
    {
        _executor = executor ?? throw new ArgumentNullException(nameof(executor));
    }

    public Task<object?> SubmitAsync(JsonElement request, CancellationToken cancellationToken) =>
        ExecuteAsync(request, resume: false, cancellationToken);

    public Task<object?> ResumeAsync(JsonElement request, CancellationToken cancellationToken) =>
        ExecuteAsync(request, resume: true, cancellationToken);

    private async Task<object?> ExecuteAsync(
        JsonElement request,
        bool resume,
        CancellationToken cancellationToken)
    {
        MissionDefinition definition = ParseDefinition(request);
        var policy = new MissionPolicy(
            MaxNodes: MaxNodes,
            AllowedKinds: AllowedKinds,
            MaxPayloadBytes: MaxPayloadCharacters,
            MaxExecutionsPerMinute: 60);
        MissionExecutionResult result = resume
            ? await _executor
                .ResumeAsync(definition, policy, ExecuteBuiltInAsync, cancellationToken)
                .ConfigureAwait(false)
            : await _executor
                .ExecuteAsync(definition, policy, ExecuteBuiltInAsync, cancellationToken)
                .ConfigureAwait(false);
        return new
        {
            missionId = result.MissionId,
            state = result.State.ToString(),
            completedNodeIds = result.CompletedNodeIds,
            failedNodeId = result.FailedNodeId,
            error = result.Error,
        };
    }

    private static MissionDefinition ParseDefinition(JsonElement request)
    {
        if (!TryString(request, "missionId", out string? missionId)
            || !request.TryGetProperty("nodes", out JsonElement nodesElement)
            || nodesElement.ValueKind != JsonValueKind.Array
            || nodesElement.GetArrayLength() is 0 or > MaxNodes)
        {
            throw new ArgumentException(
                "missionId and an array of 1 to 128 nodes are required.",
                nameof(request));
        }

        var nodes = new List<MissionNode>();
        foreach (JsonElement item in nodesElement.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object
                || !TryString(item, "id", out string? id)
                || !TryString(item, "kind", out string? kind))
            {
                throw new ArgumentException("Each mission node requires an id and kind.", nameof(request));
            }

            string payload = item.TryGetProperty("payload", out JsonElement payloadElement)
                && payloadElement.ValueKind == JsonValueKind.String
                ? payloadElement.GetString() ?? string.Empty
                : string.Empty;
            if (payload.Length > MaxPayloadCharacters)
            {
                throw new ArgumentException("A mission node payload exceeds the safety limit.", nameof(request));
            }

            nodes.Add(new MissionNode(id!, kind!, payload, ParseDependencies(item, request)));
        }

        return new MissionDefinition(missionId!, nodes);
    }

    private static IReadOnlyList<string> ParseDependencies(JsonElement item, JsonElement request)
    {
        if (!item.TryGetProperty("dependsOn", out JsonElement dependencyElement))
        {
            return Array.Empty<string>();
        }

        if (dependencyElement.ValueKind != JsonValueKind.Array)
        {
            throw new ArgumentException("dependsOn must be an array.", nameof(request));
        }

        var dependencies = new List<string>();
        foreach (JsonElement dependency in dependencyElement.EnumerateArray())
        {
            if (dependency.ValueKind != JsonValueKind.String
                || string.IsNullOrWhiteSpace(dependency.GetString()))
            {
                throw new ArgumentException(
                    "dependsOn entries must be non-empty strings.",
                    nameof(request));
            }

            dependencies.Add(dependency.GetString()!);
        }

        return dependencies;
    }

    private static async Task<MissionStepResult> ExecuteBuiltInAsync(
        MissionNode node,
        CancellationToken cancellationToken)
    {
        HeadlessRunStepResult result = await BuiltInHeadlessRunSteps
            .ExecuteAsync(
                new HeadlessRunStep(node.Id, node.Kind, node.Payload, node.Dependencies),
                cancellationToken)
            .ConfigureAwait(false);
        return new MissionStepResult(result.Succeeded, result.Error);
    }

    private static bool TryString(JsonElement item, string property, out string? value)
    {
        value = null;
        if (!item.TryGetProperty(property, out JsonElement element)
            || element.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = element.GetString();
        return !string.IsNullOrWhiteSpace(value);
    }
}

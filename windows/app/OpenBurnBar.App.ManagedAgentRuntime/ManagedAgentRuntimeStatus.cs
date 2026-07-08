using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;

namespace OpenBurnBar.App.ManagedAgentRuntime;

/// <summary>
/// Snapshot describing the live state of a managed agent runtime. The shape is
/// generic across Hermes and Pi so the Settings card UI and the runtime gate can
/// render either without branching on adapter kind.
///
/// Faithful port of the Swift <c>ManagedAgentRuntimeStatus</c> struct
/// (AgentLens/Services/ManagedAgentRuntime/ManagedAgentRuntime.swift, lines
/// 43-67). Swift is <c>Equatable, Sendable</c>; the C# <c>record</c> gives the
/// same value equality (list equality is provided via
/// <see cref="EqualityComparer"/> because the BCL does not structurally compare
/// <see cref="IReadOnlyList{T}"/> by default).
/// </summary>
public sealed record ManagedAgentRuntimeStatus
{
    /// <summary>Absolute path to the resolved CLI executable, when found.</summary>
    public string? ExecutablePath { get; init; }

    /// <summary>Whether the adapter's OpenAI-compatible gateway responds on <c>/v1/models</c>.</summary>
    public bool GatewayRunning { get; init; }

    /// <summary>
    /// Whether the adapter's companion app/process is running. For Pi this
    /// reflects the active instance launcher.
    /// </summary>
    public bool AppRunning { get; init; }

    /// <summary>Model name reported by the gateway, if available.</summary>
    public string? ModelName { get; init; }

    /// <summary>Free-form Redis status string. Null until probed.</summary>
    public string? RedisStatus { get; init; }

    /// <summary>Currently selected instance identifier, when known.</summary>
    public string? SelectedInstanceId { get; init; }

    /// <summary>Known instances discovered through the gateway or Redis.</summary>
    public IReadOnlyList<ManagedAgentInstance> Instances { get; init; } =
        new ReadOnlyCollection<ManagedAgentInstance>(new List<ManagedAgentInstance>());

    /// <summary>Operator-facing message suitable for the Settings card body.</summary>
    public string Message { get; init; } = string.Empty;

    /// <summary>
    /// True when chat can route through this runtime right now: CLI resolved and
    /// the gateway is up. Redis is optional, never required. Parity:
    /// <c>ManagedAgentRuntimeStatus.isReady</c> (lines 64-66).
    /// </summary>
    public bool IsReady => ExecutablePath is not null && GatewayRunning;

    /// <summary>
    /// Structural equality including the instance list, matching the Swift
    /// <c>Equatable</c> synthesis (which compares the array element-by-element).
    /// The default record equality would compare the list by reference, so it is
    /// overridden here.
    /// </summary>
    public bool Equals(ManagedAgentRuntimeStatus? other)
    {
        if (other is null)
        {
            return false;
        }

        return ExecutablePath == other.ExecutablePath
            && GatewayRunning == other.GatewayRunning
            && AppRunning == other.AppRunning
            && ModelName == other.ModelName
            && RedisStatus == other.RedisStatus
            && SelectedInstanceId == other.SelectedInstanceId
            && Message == other.Message
            && Instances.SequenceEqual(other.Instances);
    }

    /// <inheritdoc />
    public override int GetHashCode()
    {
        var hash = new System.HashCode();
        hash.Add(ExecutablePath);
        hash.Add(GatewayRunning);
        hash.Add(AppRunning);
        hash.Add(ModelName);
        hash.Add(RedisStatus);
        hash.Add(SelectedInstanceId);
        hash.Add(Message);
        foreach (var instance in Instances)
        {
            hash.Add(instance);
        }

        return hash.ToHashCode();
    }
}

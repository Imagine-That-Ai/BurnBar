using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;

namespace OpenBurnBar.App.ManagedAgentRuntime.Discovery;

/// <summary>
/// Result of polling the Pi agent's Redis-backed registry. When Redis is not
/// configured or unreachable, the adapter falls back to a synthetic "default"
/// instance derived from the gateway probe.
///
/// Faithful port of the Swift <c>PiAgentRedisSnapshot</c> struct
/// (AgentLens/Services/ManagedAgentRuntime/PiAgentRedisDiscovery.swift, lines
/// 8-18). Swift is <c>Equatable, Sendable</c>; the C# <c>record</c> gives value
/// equality with an explicit list comparison.
/// </summary>
public sealed record PiAgentRedisSnapshot
{
    /// <summary>Whether the Redis-backed registry answered successfully.</summary>
    public bool Available { get; }

    /// <summary>Operator-facing description of the registry state.</summary>
    public string StatusMessage { get; }

    /// <summary>Instances the registry reported (may be empty even when available).</summary>
    public IReadOnlyList<ManagedAgentInstance> Instances { get; }

    /// <summary>Constructs a snapshot.</summary>
    public PiAgentRedisSnapshot(
        bool available,
        string statusMessage,
        IReadOnlyList<ManagedAgentInstance> instances)
    {
        Available = available;
        StatusMessage = statusMessage;
        Instances = instances;
    }

    /// <summary>
    /// The canonical "no registry configured" snapshot. Parity:
    /// <c>PiAgentRedisSnapshot.unavailable</c> (lines 13-17).
    /// </summary>
    public static PiAgentRedisSnapshot Unavailable { get; } = new(
        available: false,
        statusMessage: "Redis not configured.",
        instances: new ReadOnlyCollection<ManagedAgentInstance>(new List<ManagedAgentInstance>()));

    /// <summary>Element-wise list equality, matching the Swift <c>Equatable</c> synthesis.</summary>
    public bool Equals(PiAgentRedisSnapshot? other)
    {
        if (other is null)
        {
            return false;
        }

        return Available == other.Available
            && StatusMessage == other.StatusMessage
            && Instances.SequenceEqual(other.Instances);
    }

    /// <inheritdoc />
    public override int GetHashCode()
    {
        var hash = new System.HashCode();
        hash.Add(Available);
        hash.Add(StatusMessage);
        foreach (var instance in Instances)
        {
            hash.Add(instance);
        }

        return hash.ToHashCode();
    }
}

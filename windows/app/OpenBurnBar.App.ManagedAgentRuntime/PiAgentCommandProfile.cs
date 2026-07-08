using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.ManagedAgentRuntime;

/// <summary>
/// Centralized Pi CLI argument shapes. Lives outside the adapter so integration
/// tests can verify the exact subcommand sequences without touching the live
/// process runner, and so the CLI surface can evolve in one place without ripple
/// changes through the UI layer.
///
/// Faithful port of the Swift <c>PiAgentCommandProfile</c> struct
/// (AgentLens/Services/ManagedAgentRuntime/PiAgentCommandProfile.swift). Swift is
/// <c>Sendable, Equatable</c>; the C# <c>record</c> gives the same value
/// equality. Argument lists are held as <see cref="IReadOnlyList{T}"/> so the
/// profile is immutable once constructed, matching the Swift <c>let</c> fields.
/// </summary>
public sealed record PiAgentCommandProfile
{
    /// <summary>
    /// Command that probes whether the Pi agent app/instance is running. Stdout
    /// is expected to contain either a <c>running</c> substring or a <c>PID</c>
    /// token when alive — same heuristic Hermes uses for its dashboard.
    /// </summary>
    public IReadOnlyList<string> AppStatusArguments { get; }

    /// <summary>Command that launches the Pi agent app/instance detached.</summary>
    public IReadOnlyList<string> LaunchAppArguments { get; }

    /// <summary>Command that starts the Pi gateway in the background.</summary>
    public IReadOnlyList<string> StartGatewayArguments { get; }

    /// <summary>
    /// Command that installs the Pi gateway runtime (called when
    /// <see cref="StartGatewayArguments"/> fails the first time).
    /// </summary>
    public IReadOnlyList<string> InstallGatewayArguments { get; }

    /// <summary>
    /// Optional command that lists Pi instances. When non-null, the adapter can
    /// supplement Redis discovery with a CLI-side enumeration.
    /// </summary>
    public IReadOnlyList<string>? ListInstancesArguments { get; }

    /// <summary>Constructs a profile from explicit argument vectors.</summary>
    public PiAgentCommandProfile(
        IReadOnlyList<string> appStatusArguments,
        IReadOnlyList<string> launchAppArguments,
        IReadOnlyList<string> startGatewayArguments,
        IReadOnlyList<string> installGatewayArguments,
        IReadOnlyList<string>? listInstancesArguments)
    {
        AppStatusArguments = appStatusArguments;
        LaunchAppArguments = launchAppArguments;
        StartGatewayArguments = startGatewayArguments;
        InstallGatewayArguments = installGatewayArguments;
        ListInstancesArguments = listInstancesArguments;
    }

    /// <summary>
    /// The production Pi command profile. Byte-for-byte the same argument
    /// vectors as the Swift <c>PiAgentCommandProfile.live</c> static (lines
    /// 26-32).
    /// </summary>
    public static PiAgentCommandProfile Live { get; } = new(
        appStatusArguments: new[] { "agent", "status" },
        launchAppArguments: new[] { "agent", "start", "--detach" },
        startGatewayArguments: new[] { "gateway", "start", "--accept-hooks" },
        installGatewayArguments: new[] { "gateway", "install", "--force", "--accept-hooks" },
        listInstancesArguments: new[] { "agent", "list", "--json" });

    /// <summary>
    /// Structural (element-wise) equality over every argument vector, matching
    /// the Swift <c>Equatable</c> synthesis. The default record equality would
    /// compare the list references, so it is overridden here.
    /// </summary>
    public bool Equals(PiAgentCommandProfile? other)
    {
        if (other is null)
        {
            return false;
        }

        return AppStatusArguments.SequenceEqual(other.AppStatusArguments)
            && LaunchAppArguments.SequenceEqual(other.LaunchAppArguments)
            && StartGatewayArguments.SequenceEqual(other.StartGatewayArguments)
            && InstallGatewayArguments.SequenceEqual(other.InstallGatewayArguments)
            && NullableSequenceEqual(ListInstancesArguments, other.ListInstancesArguments);
    }

    /// <inheritdoc />
    public override int GetHashCode()
    {
        var hash = new HashCode();
        AddSequence(ref hash, AppStatusArguments);
        AddSequence(ref hash, LaunchAppArguments);
        AddSequence(ref hash, StartGatewayArguments);
        AddSequence(ref hash, InstallGatewayArguments);
        if (ListInstancesArguments is not null)
        {
            AddSequence(ref hash, ListInstancesArguments);
        }

        return hash.ToHashCode();
    }

    private static bool NullableSequenceEqual(IReadOnlyList<string>? left, IReadOnlyList<string>? right)
    {
        if (left is null || right is null)
        {
            return left is null && right is null;
        }

        return left.SequenceEqual(right);
    }

    private static void AddSequence(ref HashCode hash, IReadOnlyList<string> values)
    {
        foreach (var value in values)
        {
            hash.Add(value);
        }
    }
}

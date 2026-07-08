using System;

namespace OpenBurnBar.App.ManagedAgentRuntime;

/// <summary>
/// Identity of a managed agent runtime adapter. Used by the Settings UI, the
/// chat backend strip, and the shared runtime gate to address a specific
/// adapter without leaking CLI-specific knowledge.
///
/// Faithful port of the Swift <c>ManagedAgentRuntimeKind</c> enum
/// (AgentLens/Services/ManagedAgentRuntime/ManagedAgentRuntime.swift, lines
/// 8-36). The Swift enum is <c>String</c>-raw-valued; the C# member names map
/// 1:1 to the Swift cases (<c>hermes</c> -&gt; <see cref="Hermes"/>,
/// <c>piAgent</c> -&gt; <see cref="PiAgent"/>).
/// </summary>
public enum ManagedAgentRuntimeKind
{
    /// <summary>The Hermes managed runtime.</summary>
    Hermes,

    /// <summary>The Pi Agent managed runtime.</summary>
    PiAgent,
}

/// <summary>
/// Presentation + configuration surface for <see cref="ManagedAgentRuntimeKind"/>,
/// mirroring the computed properties on the Swift enum. Kept as extension
/// methods so the enum stays a plain value the WinUI layer can switch on.
/// </summary>
public static class ManagedAgentRuntimeKindExtensions
{
    /// <summary>
    /// Swift raw value (<c>ManagedAgentRuntimeKind.rawValue</c>): the stable,
    /// lowercase-first identifier persisted in settings and sent across the
    /// bridge. Matches the Swift <c>String</c> raw values exactly.
    /// </summary>
    public static string RawValue(this ManagedAgentRuntimeKind kind) => kind switch
    {
        ManagedAgentRuntimeKind.Hermes => "hermes",
        ManagedAgentRuntimeKind.PiAgent => "piAgent",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };

    /// <summary>Parity: <c>ManagedAgentRuntimeKind.displayName</c> (lines 12-17).</summary>
    public static string DisplayName(this ManagedAgentRuntimeKind kind) => kind switch
    {
        ManagedAgentRuntimeKind.Hermes => "Hermes",
        ManagedAgentRuntimeKind.PiAgent => "Pi Agent",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };

    /// <summary>
    /// Default gateway base URL the adapter listens on if the user has not
    /// configured a custom endpoint. Parity:
    /// <c>ManagedAgentRuntimeKind.defaultGatewayBaseURL</c> (lines 21-26).
    /// </summary>
    public static Uri DefaultGatewayBaseUrl(this ManagedAgentRuntimeKind kind) => kind switch
    {
        ManagedAgentRuntimeKind.Hermes => new Uri("http://127.0.0.1:8642"),
        ManagedAgentRuntimeKind.PiAgent => new Uri("http://127.0.0.1:8765"),
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };

    /// <summary>
    /// Open-action button copy. Mirrors the Hermes Settings affordance so the
    /// Pi runtime card reads as a sibling, not a different feature. Parity:
    /// <c>ManagedAgentRuntimeKind.openActionLabel</c> (lines 30-35).
    /// </summary>
    public static string OpenActionLabel(this ManagedAgentRuntimeKind kind) => kind switch
    {
        ManagedAgentRuntimeKind.Hermes => "Open Hermes + Gateway",
        ManagedAgentRuntimeKind.PiAgent => "Open Pi + Gateway",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };
}

using System;

namespace OpenBurnBar.App.ManagedAgentRuntime;

/// <summary>
/// Lightweight per-instance descriptor surfaced to the Settings UI. Hermes
/// always exposes exactly one synthetic instance ("default"); Pi may expose many
/// when Redis discovery is wired up.
///
/// Faithful port of the Swift <c>ManagedAgentInstance</c> struct
/// (AgentLens/Services/ManagedAgentRuntime/ManagedAgentRuntime.swift, lines
/// 74-94). Swift conforms to <c>Equatable, Identifiable, Hashable</c>; the C#
/// <c>record</c> gives the same value equality + hashing, and <see cref="Id"/>
/// is the identity (Swift <c>Identifiable.id</c>).
/// </summary>
public sealed record ManagedAgentInstance
{
    /// <summary>Stable instance identifier (Swift <c>id</c> / <c>Identifiable.id</c>).</summary>
    public string Id { get; }

    /// <summary>Operator-facing label. Defaults to <see cref="Id"/> upstream when absent.</summary>
    public string DisplayName { get; init; }

    /// <summary>Whether the instance is currently reachable. Swift defaults to <c>true</c>.</summary>
    public bool IsOnline { get; init; }

    /// <summary>Identifier of the session the instance is actively serving, if any.</summary>
    public string? ActiveSessionId { get; init; }

    /// <summary>Gateway base URL the instance answers on, when advertised.</summary>
    public Uri? GatewayBaseUrl { get; init; }

    /// <summary>
    /// Mirrors the Swift memberwise initializer's default arguments
    /// (<c>isOnline: true</c>, the rest <c>nil</c>) so call sites read the same.
    /// </summary>
    public ManagedAgentInstance(
        string id,
        string displayName,
        bool isOnline = true,
        string? activeSessionId = null,
        Uri? gatewayBaseUrl = null)
    {
        Id = id;
        DisplayName = displayName;
        IsOnline = isOnline;
        ActiveSessionId = activeSessionId;
        GatewayBaseUrl = gatewayBaseUrl;
    }
}

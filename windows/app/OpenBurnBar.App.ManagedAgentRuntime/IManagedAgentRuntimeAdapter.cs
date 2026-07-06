using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime;

/// <summary>
/// Adapter contract every managed runtime implements. Implementations should be
/// cheap to construct because the Settings surface and the runtime gate
/// instantiate them inside UI state.
///
/// Faithful port of the Swift <c>ManagedAgentRuntimeAdapter</c> protocol
/// (AgentLens/Services/ManagedAgentRuntime/ManagedAgentRuntime.swift, lines
/// 96-127).
///
/// THREADING NOTE (deferred, Windows/UI half): the Swift protocol is
/// <c>@MainActor</c>, so all mutation of <see cref="ManagedStatus"/>,
/// <see cref="IsBusy"/>, and <see cref="LastError"/> is serialized on the main
/// actor and observed by SwiftUI. C# has no <c>@MainActor</c>; the WinUI layer
/// owns the equivalent discipline — it invokes these methods on the UI
/// dispatcher (or marshals the returned status back onto it) exactly as the
/// existing WinUI view-models do. The core intentionally performs no locking, so
/// callers must not touch a single adapter instance from multiple threads
/// concurrently, matching the single-actor Swift contract.
///
/// The method names keep the <c>Managed</c> prefix so adapter-specific entry
/// points can coexist without ambiguity, mirroring the Swift naming rationale.
/// </summary>
public interface IManagedAgentRuntimeAdapter
{
    /// <summary>Which managed runtime this adapter drives.</summary>
    ManagedAgentRuntimeKind Kind { get; }

    /// <summary>The last computed status snapshot.</summary>
    ManagedAgentRuntimeStatus ManagedStatus { get; }

    /// <summary>True while a refresh/open call is in flight.</summary>
    bool IsBusy { get; }

    /// <summary>The most recent operator-facing error, or null after a clean call.</summary>
    string? LastError { get; }

    /// <summary>
    /// Read the runtime state without mutating processes. Safe to call from task
    /// contexts during app launch and Settings refresh. Parity:
    /// <c>refreshManagedStatus(baseURL:bearerToken:)</c> (lines 114-118).
    /// </summary>
    Task<ManagedAgentRuntimeStatus> RefreshManagedStatusAsync(
        Uri baseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Mutating call: ensure the gateway is up, ensure the companion
    /// app/instance is running, then probe and return the resulting status.
    /// Parity: <c>openManagedRuntime(baseURL:bearerToken:)</c> (lines 122-126).
    /// </summary>
    Task<ManagedAgentRuntimeStatus> OpenManagedRuntimeAsync(
        Uri baseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default);
}

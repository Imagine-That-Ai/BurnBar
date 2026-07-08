// Seam for AgentLens/Services/Cast/CastTLSConnection.swift — the platform TLS
// socket. Implemented on Windows by OpenBurnBar.Integrations.Cast.Windows.

using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Cast.Protocol;

namespace OpenBurnBar.Integrations.Cast.Session;

/// <summary>Lifecycle state of a Cast TLS channel. Port of Swift <c>CastTLSConnection.State</c>.</summary>
public enum CastSocketState
{
    /// <summary>Not yet started.</summary>
    Idle,

    /// <summary>TLS handshake in progress.</summary>
    Connecting,

    /// <summary>Connected; frames may flow.</summary>
    Ready,

    /// <summary>Terminally failed.</summary>
    Failed,

    /// <summary>Cancelled by the sender or closed by the peer.</summary>
    Cancelled,
}

/// <summary>
/// The platform-specific Cast TLS socket seam. Cast devices present self-signed
/// certificates on <c>:8009</c>; an implementation accepts the presented chain
/// only because <c>_googlecast._tcp</c> discovery proved the peer. The portable
/// session driver frames/deframes with <see cref="CastFraming"/> and talks only
/// to this interface, so it stays unit-testable with an in-memory fake.
/// </summary>
public interface ICastSocket : IAsyncDisposable
{
    /// <summary>Current channel state.</summary>
    CastSocketState State { get; }

    /// <summary>Raised on the arrival of each fully-deframed inbound message.</summary>
    event Action<CastMessage>? MessageReceived;

    /// <summary>Raised whenever <see cref="State"/> changes.</summary>
    event Action<CastSocketState>? StateChanged;

    /// <summary>Open the TLS channel to the device; completes when Ready or terminal.</summary>
    Task ConnectAsync(CancellationToken cancellationToken = default);

    /// <summary>Frame and send one message. No-op unless <see cref="State"/> is Ready.</summary>
    Task SendAsync(CastMessage message, CancellationToken cancellationToken = default);

    /// <summary>Close the sender socket (leaves the receiver app running).</summary>
    void Cancel();
}

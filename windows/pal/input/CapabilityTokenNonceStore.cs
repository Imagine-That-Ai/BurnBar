// Single-use nonce ledger for offline capability-token leaf verification.
//
// Ported from OpenBurnBarComputerUseCore.CapabilityTokenNonceStore /
// InMemoryCapabilityTokenNonceStore. A capability token is single-use: once its nonce is
// consumed, a replay of the same token is rejected. Keyed by domain+nonce so an
// unrelated remote-unlock nonce never shadows a computer-use one.

using System;
using System.Collections.Generic;

namespace OpenBurnBar.Pal.Input;

/// <summary>Tracks consumed single-use nonces for offline leaf verification.</summary>
public interface ICapabilityTokenNonceStore
{
    bool HasConsumed(string nonce, CapabilityTokenDomain domain);

    /// <summary>Consume a nonce. Throws <see cref="CapabilityTokenNonceReplayException"/>
    /// if it was already consumed (checked-and-set atomically).</summary>
    void Consume(string nonce, CapabilityTokenDomain domain);
}

/// <summary>Thrown by <see cref="ICapabilityTokenNonceStore.Consume"/> on a replay.</summary>
public sealed class CapabilityTokenNonceReplayException : Exception
{
    public CapabilityTokenNonceReplayException()
        : base("Capability-token nonce already consumed.")
    {
    }
}

/// <summary>In-memory nonce store for unit tests and ephemeral coordinators.
/// Thread-safe via a private lock, matching the macOS <c>Locked</c> wrapper.</summary>
public sealed class InMemoryCapabilityTokenNonceStore : ICapabilityTokenNonceStore
{
    private readonly object _gate = new();
    private readonly HashSet<string> _consumed = new(StringComparer.Ordinal);

    private static string Key(string nonce, CapabilityTokenDomain domain) =>
        domain.ToWire() + ":" + nonce;

    public bool HasConsumed(string nonce, CapabilityTokenDomain domain)
    {
        lock (_gate)
        {
            return _consumed.Contains(Key(nonce, domain));
        }
    }

    public void Consume(string nonce, CapabilityTokenDomain domain)
    {
        lock (_gate)
        {
            if (!_consumed.Add(Key(nonce, domain)))
            {
                throw new CapabilityTokenNonceReplayException();
            }
        }
    }
}

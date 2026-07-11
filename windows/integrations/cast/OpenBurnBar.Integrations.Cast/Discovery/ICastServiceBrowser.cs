// Seam for AgentLens/Services/Cast/CastDiscovery.swift — the live mDNS browser.
// Implemented on Windows by OpenBurnBar.Integrations.Cast.Windows via the OS
// Dnssd watcher. Kept as an interface so the wizard is unit-testable with a fake.

using System;
using System.Collections.Generic;
using OpenBurnBar.Integrations.Cast.Model;

namespace OpenBurnBar.Integrations.Cast.Discovery;

/// <summary>
/// A live <c>_googlecast._tcp</c> browser. Implementations publish the full
/// deduplicated device set on every change (so views can straight-assign),
/// exactly like the Swift <c>CastDiscovery.onUpdate</c> contract.
/// </summary>
public interface ICastServiceBrowser : IDisposable
{
    /// <summary>Raised with the full, sorted, deduplicated device list on every change.</summary>
    event Action<IReadOnlyList<CastDevice>>? DevicesChanged;

    /// <summary>Begin browsing. Idempotent restart, like the Swift <c>start()</c>.</summary>
    void Start();

    /// <summary>Stop browsing and clear internal state.</summary>
    void Stop();
}

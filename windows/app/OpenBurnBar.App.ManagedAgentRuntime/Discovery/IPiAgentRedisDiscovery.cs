using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Discovery;

/// <summary>
/// Pi instance discovery seam. Production builds talk to the Pi gateway's
/// <c>/admin/instances</c> endpoint, which proxies the Redis-backed registry of
/// active Pi agent instances (online state, active session, attached gateway
/// base URL). Tests and lightweight environments inject a fake.
///
/// Faithful port of the Swift <c>PiAgentRedisDiscovery</c> protocol
/// (AgentLens/Services/ManagedAgentRuntime/PiAgentRedisDiscovery.swift, lines
/// 26-28). This is the injectable discovery abstraction the mission calls for:
/// the runtime controller depends only on this interface, so the tests fake it
/// and the real registry access (the HTTP-to-gateway client here, and any
/// direct raw-Redis-socket client a Windows adapter might later add) stays a
/// thin, swappable implementation.
/// </summary>
public interface IPiAgentRedisDiscovery
{
    /// <summary>
    /// Poll the registry for the current instance set. Parity:
    /// <c>snapshot(redisURL:gatewayBaseURL:bearerToken:)</c> (line 27). Never
    /// throws — a failure is reported as an unavailable snapshot with a
    /// human-readable status, matching the Swift implementation's catch-all.
    /// </summary>
    Task<PiAgentRedisSnapshot> SnapshotAsync(
        Uri? redisUrl,
        Uri gatewayBaseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default);
}

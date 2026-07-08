// Parity source: AgentLens/Services/Cast/CastChannelClient.swift (sendDashCastLoadWithRetries)

using System;
using System.Collections.Generic;
using OpenBurnBar.Integrations.Cast.Protocol;

namespace OpenBurnBar.Integrations.Cast.Session;

/// <summary>One scheduled DashCast LOAD attempt (delay + force flag + wire message).</summary>
public sealed record CastLoadAttempt
{
    /// <summary>Zero-based attempt index.</summary>
    public required int Index { get; init; }

    /// <summary>Delay to wait <em>before</em> sending this attempt.</summary>
    public required TimeSpan Delay { get; init; }

    /// <summary>Whether this attempt forces a direct (reload-incapable) load.</summary>
    public required bool Force { get; init; }

    /// <summary>The LOAD message to put on the wire for this attempt.</summary>
    public required CastMessage Message { get; init; }
}

/// <summary>
/// Builds the repeat-send DashCast LOAD schedule that defeats receiver-side
/// message drop on a fresh transport. Port of <c>sendDashCastLoadWithRetries</c>:
/// three attempts at 0 / 600 ms / 1500 ms, with <c>reloadSeconds = 0</c>
/// (DashCast's own reload timer is pure flicker) and <c>force = index &gt; 0</c>
/// (the first attempt preserves an existing page; retries force a wedged splash
/// to reload with our URL).
/// </summary>
public static class CastLoadPlan
{
    /// <summary>The three inter-attempt delays, in the Swift order.</summary>
    public static readonly IReadOnlyList<TimeSpan> Delays = new[]
    {
        TimeSpan.Zero,
        TimeSpan.FromMilliseconds(600),
        TimeSpan.FromMilliseconds(1_500),
    };

    /// <summary>Build the ordered LOAD attempts for a transport + URL.</summary>
    public static IReadOnlyList<CastLoadAttempt> Build(string transportId, string url, string? sessionId)
    {
        var attempts = new List<CastLoadAttempt>(Delays.Count);
        for (var index = 0; index < Delays.Count; index++)
        {
            var force = index > 0;
            attempts.Add(new CastLoadAttempt
            {
                Index = index,
                Delay = Delays[index],
                Force = force,
                Message = CastReceiverProtocol.DashCastLoad(
                    transportId,
                    url,
                    sessionId,
                    reloadSeconds: 0,
                    force: force),
            });
        }

        return attempts;
    }
}

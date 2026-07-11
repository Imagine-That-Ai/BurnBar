// Parity source: AgentLens/Services/Cast/CastChannelClient.swift
// (cast(url:) + launchAppIfNeeded + handle(message:) state transitions)

using System;
using System.Collections.Generic;
using OpenBurnBar.Integrations.Cast.Protocol;

namespace OpenBurnBar.Integrations.Cast.Session;

/// <summary>Phase of the receiver launch handshake.</summary>
public enum CastCastPhase
{
    /// <summary>Nothing started yet.</summary>
    Idle,

    /// <summary>Sent GET_STATUS; awaiting the receiver's current app.</summary>
    QueryingStatus,

    /// <summary>Sent STOP for a pre-existing session; awaiting teardown.</summary>
    StoppingStale,

    /// <summary>Sent LAUNCH for DashCast; awaiting the fresh session/transport.</summary>
    Launching,

    /// <summary>Transport CONNECT + LOAD emitted; heartbeat should run.</summary>
    Streaming,

    /// <summary>Terminal failure with a human-readable reason.</summary>
    Failed,
}

/// <summary>The outbound effect of feeding one input to the state machine.</summary>
public sealed record CastStep
{
    /// <summary>The phase after applying the input.</summary>
    public required CastCastPhase Phase { get; init; }

    /// <summary>Frames to put on the wire, in order.</summary>
    public required IReadOnlyList<CastMessage> Outbound { get; init; }

    /// <summary>The LOAD retry schedule to run, when the machine reached Streaming.</summary>
    public IReadOnlyList<CastLoadAttempt> LoadPlan { get; init; } = Array.Empty<CastLoadAttempt>();

    /// <summary>Whether the heartbeat loop should start now.</summary>
    public bool StartHeartbeat { get; init; }

    /// <summary>Failure reason when <see cref="Phase"/> is <see cref="CastCastPhase.Failed"/>.</summary>
    public string? FailureReason { get; init; }
}

/// <summary>
/// Pure, socket-free driver of the Cast launch handshake:
/// CONNECT → GET_STATUS → (STOP stale) → LAUNCH DashCast → CONNECT(transport) →
/// LOAD → heartbeat. The Windows adapter pumps real inbound events into
/// <see cref="OnEvent"/> and writes the returned frames; every branch is
/// deterministic so it is exercised entirely off-Windows.
/// </summary>
/// <remarks>
/// Faithful to <c>launchAppIfNeeded</c>'s hard rule: NEVER reuse an existing
/// session — even a DashCast one — because the Hub can report DashCast active
/// while visually stuck on its splash. Any pre-existing session is STOPped, then
/// DashCast is LAUNCHed fresh.
/// </remarks>
public sealed class CastReceiverStateMachine
{
    private readonly string _url;
    private int _requestCounter = 1;

    /// <summary>Current handshake phase.</summary>
    public CastCastPhase Phase { get; private set; } = CastCastPhase.Idle;

    /// <summary>Latched receiver session id, once known.</summary>
    public string? SessionId { get; private set; }

    /// <summary>Latched receiver transport id, once known.</summary>
    public string? TransportId { get; private set; }

    /// <summary>Latched running app id, once known.</summary>
    public string? AppId { get; private set; }

    /// <summary>Create a driver that will cast <paramref name="url"/> to the receiver.</summary>
    public CastReceiverStateMachine(string url)
    {
        _url = url ?? throw new ArgumentNullException(nameof(url));
    }

    /// <summary>Next request id (monotonic, starts at 1), mirroring Swift's counter.</summary>
    public int NextRequestId() => _requestCounter++;

    /// <summary>
    /// Begin the handshake: open the receiver virtual channel and query status.
    /// </summary>
    public CastStep Start()
    {
        Phase = CastCastPhase.QueryingStatus;
        return new CastStep
        {
            Phase = Phase,
            Outbound = new[]
            {
                CastReceiverProtocol.Connect(CastMessage.DefaultDestination),
                CastReceiverProtocol.GetStatus(NextRequestId()),
            },
        };
    }

    /// <summary>
    /// Feed one decoded inbound event (or a synthetic no-response, see
    /// <see cref="OnNoResponse"/>) and get the next outbound effect.
    /// </summary>
    public CastStep OnEvent(CastInboundEvent inbound)
    {
        if (inbound is null)
        {
            throw new ArgumentNullException(nameof(inbound));
        }

        // A device PING is answered with a PONG regardless of phase.
        if (inbound.Kind == CastInboundKind.Ping)
        {
            return new CastStep
            {
                Phase = Phase,
                Outbound = new[] { CastReceiverProtocol.Pong() },
            };
        }

        switch (Phase)
        {
            case CastCastPhase.QueryingStatus:
                return OnStatusResult(inbound);
            case CastCastPhase.StoppingStale:
                return LaunchFresh();
            case CastCastPhase.Launching:
                return OnLaunchResult(inbound);
            default:
                return NoOp();
        }
    }

    /// <summary>
    /// Signal that a request timed out / produced no usable response. In
    /// QueryingStatus this proceeds straight to LAUNCH (matching Swift, which
    /// launches regardless of GET_STATUS outcome); in Launching it is a timeout
    /// failure.
    /// </summary>
    public CastStep OnNoResponse()
    {
        switch (Phase)
        {
            case CastCastPhase.QueryingStatus:
                return LaunchFresh();
            case CastCastPhase.StoppingStale:
                return LaunchFresh();
            case CastCastPhase.Launching:
                return Fail("Hub didn't respond in time");
            default:
                return NoOp();
        }
    }

    private CastStep OnStatusResult(CastInboundEvent inbound)
    {
        if (inbound.Kind == CastInboundKind.ReceiverStatusActive && !string.IsNullOrEmpty(inbound.SessionId))
        {
            // Something is running — STOP it first so LAUNCH lands on a clean
            // slate (avoids LAUNCH_ERROR=INVALID_PARAMETER). Never reuse it.
            SessionId = inbound.SessionId;
            TransportId = inbound.TransportId;
            AppId = inbound.AppId;
            Phase = CastCastPhase.StoppingStale;
            var stop = CastReceiverProtocol.Stop(inbound.SessionId!, NextRequestId());
            return new CastStep { Phase = Phase, Outbound = new[] { stop } };
        }

        // Idle / Backdrop / no session — launch directly.
        return LaunchFresh();
    }

    private CastStep LaunchFresh()
    {
        SessionId = null;
        TransportId = null;
        AppId = null;
        Phase = CastCastPhase.Launching;
        return new CastStep
        {
            Phase = Phase,
            Outbound = new[] { CastReceiverProtocol.LaunchDashCast(NextRequestId()) },
        };
    }

    private CastStep OnLaunchResult(CastInboundEvent inbound)
    {
        switch (inbound.Kind)
        {
            case CastInboundKind.LaunchError:
                return Fail(MapLaunchError(inbound.LaunchErrorReason));
            case CastInboundKind.ReceiverStatusIdle:
                return Fail("Receiver returned no sessions");
            case CastInboundKind.ReceiverStatusActive:
                if (string.IsNullOrEmpty(inbound.TransportId))
                {
                    return Fail("Missing transport id after LAUNCH");
                }

                SessionId = inbound.SessionId;
                TransportId = inbound.TransportId;
                AppId = inbound.AppId;
                Phase = CastCastPhase.Streaming;
                return new CastStep
                {
                    Phase = Phase,
                    Outbound = new[] { CastReceiverProtocol.Connect(inbound.TransportId!) },
                    LoadPlan = CastLoadPlan.Build(inbound.TransportId!, _url, SessionId),
                    StartHeartbeat = true,
                };
            default:
                return NoOp();
        }
    }

    /// <summary>
    /// Map a raw LAUNCH_ERROR reason to a user-facing message. <c>NOT_FOUND</c>
    /// means the device can't host DashCast (audio-only speakers).
    /// </summary>
    public static string MapLaunchError(string? reason)
        => reason == "NOT_FOUND"
            ? "This device can't display web pages. Pick a Nest Hub or Chromecast."
            : reason ?? "LAUNCH_ERROR";

    private CastStep Fail(string reason)
    {
        Phase = CastCastPhase.Failed;
        return new CastStep
        {
            Phase = Phase,
            Outbound = Array.Empty<CastMessage>(),
            FailureReason = reason,
        };
    }

    private CastStep NoOp() => new()
    {
        Phase = Phase,
        Outbound = Array.Empty<CastMessage>(),
    };
}

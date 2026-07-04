using System;
using System.Collections.Generic;
using OpenBurnBar.Integrations.Mercury.Budget;

namespace OpenBurnBar.Integrations.Mercury.Sessions;

/// <summary>
/// Pure media-session phase machine extracted from
/// <c>AgentLens/Services/Media/MediaSessionCoordinator.swift</c>. Owns only the
/// transport-free control logic: phase transitions, restartability, viewer-sink
/// fan-out bookkeeping, capability-denial routing, and the mid-session admission
/// recheck that tears a session down when the gate flips to denied.
///
/// The AVFoundation / Windows.Graphics.Capture capture, the encoder, and the
/// iroh stream sinks are injected by the platform coordinator; this class never
/// touches them, so the state logic is verifiable on any host.
/// </summary>
public sealed class MediaSessionStateMachine
{
    private readonly Dictionary<string, object> _sinks = new(StringComparer.Ordinal);
    private MediaSessionPhase _phase = MediaSessionPhase.Idle();

    public MediaSessionPhase Phase => _phase;

    /// <summary>Distinct viewer sinks currently attached (parity: activeScreenShareViewerCount).</summary>
    public int ActiveViewerCount => _sinks.Count;

    /// <summary>Whether a fresh session may start now (parity: Phase.isRestartable).</summary>
    public bool IsRestartable => _phase.Kind is MediaSessionPhaseKind.Idle or MediaSessionPhaseKind.Ended;

    /// <summary>
    /// Begin a session for <paramref name="feature"/>, given the gate's
    /// <paramref name="decision"/> and the viewer sink key. Mirrors
    /// startScreenShare's control flow:
    /// <list type="bullet">
    ///   <item>Already active on the same feature → attach the sink, stay active.</item>
    ///   <item>Not restartable → reject (a capture is already spinning up).</item>
    ///   <item>Gate denied → transition to Ended(reason.EndReason) and reject.</item>
    ///   <item>Otherwise → Starting(feature) with the sink registered.</item>
    /// </list>
    /// </summary>
    public MediaSessionStartOutcome BeginStart(MediaFeature feature, MediaCapabilityCheck decision, string sinkKey, object sink)
    {
        if (sinkKey is null)
        {
            throw new ArgumentNullException(nameof(sinkKey));
        }

        if (sink is null)
        {
            throw new ArgumentNullException(nameof(sink));
        }

        if (_phase.Kind == MediaSessionPhaseKind.Active && _phase.Feature == feature)
        {
            _sinks[sinkKey] = sink;
            return MediaSessionStartOutcome.AttachedToActive;
        }

        if (!IsRestartable)
        {
            return MediaSessionStartOutcome.RejectedNotRestartable;
        }

        if (!decision.IsAllowed)
        {
            var reason = decision.DenialReason ?? MediaCapabilityDenialReason.KillSwitchActive;
            _phase = MediaSessionPhase.Ended(EndReasonFor(reason));
            return MediaSessionStartOutcome.RejectedDenied(reason);
        }

        _sinks.Clear();
        _sinks[sinkKey] = sink;
        _phase = MediaSessionPhase.Starting(feature);
        return MediaSessionStartOutcome.Starting;
    }

    /// <summary>Promote a Starting session to Active (parity: phase = .active after pipeline start).</summary>
    public void CompleteStart()
    {
        if (_phase.Kind != MediaSessionPhaseKind.Starting)
        {
            throw new InvalidOperationException($"cannot complete start from phase {_phase.Kind}");
        }

        _phase = MediaSessionPhase.Active(_phase.Feature!.Value);
    }

    /// <summary>
    /// Stop the session, clearing sinks and landing in Ended(reason)
    /// (parity: stop(reason:)).
    /// </summary>
    public void Stop(MediaSessionEndReason reason = MediaSessionEndReason.CompletedUserCancel)
    {
        _phase = MediaSessionPhase.Stopping();
        _sinks.Clear();
        _phase = MediaSessionPhase.Ended(reason);
    }

    /// <summary>
    /// Detach one viewer sink; when the last viewer leaves, stop the whole
    /// session (parity: detachScreenShareViewer). Returns whether a sink was
    /// removed.
    /// </summary>
    public bool DetachViewer(string sinkKey, MediaSessionEndReason reason = MediaSessionEndReason.CompletedUserCancel)
    {
        if (!_sinks.Remove(sinkKey))
        {
            return false;
        }

        if (_sinks.Count == 0)
        {
            Stop(reason);
        }

        return true;
    }

    /// <summary>
    /// Re-run admission mid-session: while Active on the request feature, a
    /// denied decision tears the session down with the mapped end reason
    /// (parity: recheckActiveAdmission). Returns whether the session was stopped.
    /// </summary>
    public bool RecheckAdmission(MediaFeature requestFeature, MediaCapabilityCheck decision)
    {
        if (_phase.Kind != MediaSessionPhaseKind.Active || _phase.Feature != requestFeature)
        {
            return false;
        }

        if (decision.IsAllowed)
        {
            return false;
        }

        var reason = decision.DenialReason ?? MediaCapabilityDenialReason.KillSwitchActive;
        Stop(EndReasonFor(reason));
        return true;
    }

    /// <summary>
    /// Map a capability-denial reason onto a session end reason (parity: the
    /// private MediaCapabilityDenialReason.endReason extension).
    /// </summary>
    public static MediaSessionEndReason EndReasonFor(MediaCapabilityDenialReason reason) => reason switch
    {
        MediaCapabilityDenialReason.BudgetSoftCapReached => MediaSessionEndReason.BudgetSoftCap,
        MediaCapabilityDenialReason.BudgetHardCapReached => MediaSessionEndReason.BudgetHardCap,
        MediaCapabilityDenialReason.KillSwitchActive => MediaSessionEndReason.BudgetHardCap,
        _ => MediaSessionEndReason.Error,
    };
}

/// <summary>Session phase (parity: MediaSessionCoordinator.Phase).</summary>
public readonly struct MediaSessionPhase : IEquatable<MediaSessionPhase>
{
    public MediaSessionPhaseKind Kind { get; }

    public MediaFeature? Feature { get; }

    public MediaSessionEndReason? EndReason { get; }

    private MediaSessionPhase(MediaSessionPhaseKind kind, MediaFeature? feature, MediaSessionEndReason? endReason)
    {
        Kind = kind;
        Feature = feature;
        EndReason = endReason;
    }

    public static MediaSessionPhase Idle() => new(MediaSessionPhaseKind.Idle, null, null);

    public static MediaSessionPhase Starting(MediaFeature feature) => new(MediaSessionPhaseKind.Starting, feature, null);

    public static MediaSessionPhase Active(MediaFeature feature) => new(MediaSessionPhaseKind.Active, feature, null);

    public static MediaSessionPhase Stopping() => new(MediaSessionPhaseKind.Stopping, null, null);

    public static MediaSessionPhase Ended(MediaSessionEndReason reason) => new(MediaSessionPhaseKind.Ended, null, reason);

    public bool Equals(MediaSessionPhase other) =>
        Kind == other.Kind && Feature == other.Feature && EndReason == other.EndReason;

    public override bool Equals(object? obj) => obj is MediaSessionPhase other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(Kind, Feature, EndReason);
}

public enum MediaSessionPhaseKind
{
    Idle,
    Starting,
    Active,
    Stopping,
    Ended,
}

/// <summary>Session end reasons (parity: MediaSessionMetadata.EndReason).</summary>
public enum MediaSessionEndReason
{
    CompletedSuccess,
    CompletedUserCancel,
    CompletedPeerCancel,
    Timeout,
    Error,
    EntitlementRevoked,
    BudgetSoftCap,
    BudgetHardCap,
    ThermalCritical,
}

/// <summary>Outcome of <see cref="MediaSessionStateMachine.BeginStart"/>.</summary>
public readonly struct MediaSessionStartOutcome : IEquatable<MediaSessionStartOutcome>
{
    public MediaSessionStartResult Result { get; }

    public MediaCapabilityDenialReason? DenialReason { get; }

    private MediaSessionStartOutcome(MediaSessionStartResult result, MediaCapabilityDenialReason? denialReason)
    {
        Result = result;
        DenialReason = denialReason;
    }

    public static readonly MediaSessionStartOutcome Starting = new(MediaSessionStartResult.Starting, null);
    public static readonly MediaSessionStartOutcome AttachedToActive = new(MediaSessionStartResult.AttachedToActive, null);
    public static readonly MediaSessionStartOutcome RejectedNotRestartable = new(MediaSessionStartResult.RejectedNotRestartable, null);

    public static MediaSessionStartOutcome RejectedDenied(MediaCapabilityDenialReason reason) =>
        new(MediaSessionStartResult.RejectedDenied, reason);

    public bool Equals(MediaSessionStartOutcome other) =>
        Result == other.Result && DenialReason == other.DenialReason;

    public override bool Equals(object? obj) => obj is MediaSessionStartOutcome other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(Result, DenialReason);
}

public enum MediaSessionStartResult
{
    Starting,
    AttachedToActive,
    RejectedNotRestartable,
    RejectedDenied,
}

using System;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Mercury.Sessions;

namespace OpenBurnBar.Integrations.Mercury.Budget;

/// <summary>
/// Denial reasons surfaced by the capability gate (parity:
/// MediaCapabilityDenialReason).
/// </summary>
public enum MediaCapabilityDenialReason
{
    EntitlementMissing,
    EntitlementExpired,
    DailyCapReached,
    SessionCapReached,
    ConcurrentSessionCapReached,
    BudgetSoftCapReached,
    BudgetHardCapReached,
    KillSwitchActive,
}

/// <summary>Transfer direction for file-transfer admission (parity: MediaCapabilityTransferDirection).</summary>
public enum MediaCapabilityTransferDirection
{
    Inbound,
    Outbound,
}

/// <summary>
/// The result of a capability check: <c>Allowed(envelope)</c> or
/// <c>Denied(reason)</c> (parity: MediaCapabilityCheck).
/// </summary>
public readonly struct MediaCapabilityCheck : IEquatable<MediaCapabilityCheck>
{
    public bool IsAllowed { get; }

    public MediaCapabilityEnvelope? Envelope { get; }

    public MediaCapabilityDenialReason? DenialReason { get; }

    private MediaCapabilityCheck(bool isAllowed, MediaCapabilityEnvelope? envelope, MediaCapabilityDenialReason? denialReason)
    {
        IsAllowed = isAllowed;
        Envelope = envelope;
        DenialReason = denialReason;
    }

    public static MediaCapabilityCheck Allowed(MediaCapabilityEnvelope envelope) =>
        new(true, envelope ?? throw new ArgumentNullException(nameof(envelope)), null);

    public static MediaCapabilityCheck Denied(MediaCapabilityDenialReason reason) =>
        new(false, null, reason);

    public bool Equals(MediaCapabilityCheck other) =>
        IsAllowed == other.IsAllowed
        && Nullable.Equals(DenialReason, other.DenialReason)
        && Equals(Envelope, other.Envelope);

    public override bool Equals(object? obj) => obj is MediaCapabilityCheck other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(IsAllowed, Envelope, DenialReason);
}

/// <summary>
/// Caller-visible envelope returned with an <c>Allowed</c> decision so the caller
/// knows its remaining budget before it commits to a session (parity:
/// MediaCapabilityEnvelope).
/// </summary>
public sealed class MediaCapabilityEnvelope : IEquatable<MediaCapabilityEnvelope>
{
    public MediaFeature Feature { get; }

    public int? RemainingSecondsToday { get; }

    public long? RemainingBytesToday { get; }

    public int? PerSessionMaxSeconds { get; }

    public long? PerSessionMaxBytes { get; }

    public int ConcurrentSessionsRemaining { get; }

    public MediaCapabilityEnvelope(
        MediaFeature feature,
        int? remainingSecondsToday = null,
        long? remainingBytesToday = null,
        int? perSessionMaxSeconds = null,
        long? perSessionMaxBytes = null,
        int concurrentSessionsRemaining = 1)
    {
        Feature = feature;
        RemainingSecondsToday = remainingSecondsToday;
        RemainingBytesToday = remainingBytesToday;
        PerSessionMaxSeconds = perSessionMaxSeconds;
        PerSessionMaxBytes = perSessionMaxBytes;
        ConcurrentSessionsRemaining = concurrentSessionsRemaining;
    }

    public bool Equals(MediaCapabilityEnvelope? other)
    {
        if (other is null)
        {
            return false;
        }

        return Feature == other.Feature
            && RemainingSecondsToday == other.RemainingSecondsToday
            && RemainingBytesToday == other.RemainingBytesToday
            && PerSessionMaxSeconds == other.PerSessionMaxSeconds
            && PerSessionMaxBytes == other.PerSessionMaxBytes
            && ConcurrentSessionsRemaining == other.ConcurrentSessionsRemaining;
    }

    public override bool Equals(object? obj) => Equals(obj as MediaCapabilityEnvelope);

    public override int GetHashCode() => HashCode.Combine(
        Feature,
        RemainingSecondsToday,
        RemainingBytesToday,
        PerSessionMaxSeconds,
        PerSessionMaxBytes,
        ConcurrentSessionsRemaining);
}

/// <summary>
/// Per-feature entitlement flags (parity: MacMediaCapabilityGate.EntitlementState).
/// </summary>
public sealed class MediaEntitlementState
{
    public bool Active { get; }

    public bool FileTransfer { get; }

    public bool ScreenShare { get; }

    public bool VideoCall { get; }

    public MediaEntitlementState(bool active, bool fileTransfer, bool screenShare, bool videoCall)
    {
        Active = active;
        FileTransfer = fileTransfer;
        ScreenShare = screenShare;
        VideoCall = videoCall;
    }

    /// <summary>All-off state (denies everything).</summary>
    public static readonly MediaEntitlementState None = new(false, false, false, false);

    /// <summary>All-on state (parity: entitlementState when hosted media active).</summary>
    public static readonly MediaEntitlementState All = new(true, true, true, true);
}

/// <summary>
/// Snapshot mirror of the server-reconciled quota usage doc (parity:
/// MediaQuotaUsageSnapshot). Read-only to clients server-side, so a
/// user-controlled write cannot lower a counter to bypass admission.
/// </summary>
public sealed class MediaQuotaUsageSnapshot
{
    public long BytesUploadedFile { get; init; }

    public long BytesDownloadedFile { get; init; }

    public int FileTransfersInitiated { get; init; }

    public int FileTransfersFailed { get; init; }

    public int ScreenShareSecondsUsed { get; init; }

    public int ScreenShareSessions { get; init; }

    public int VideoCallSecondsUsed { get; init; }

    public int VideoCallSessions { get; init; }
}

/// <summary>
/// Synchronous gate consulted before every Mercury session start and rechecked
/// mid-session (parity: MediaCapabilityGate protocol).
/// </summary>
public interface IMediaCapabilityGate
{
    Task<MediaCapabilityCheck> CheckAsync(
        MediaFeature feature,
        int? sessionDurationLimitSeconds,
        long? sessionByteBudget,
        MediaCapabilityTransferDirection? transferDirection = null);
}

/// <summary>
/// A gate that always allows (parity: AlwaysAllowMediaCapabilityGate). Used by
/// integration tests and builds without a platform gate.
/// </summary>
public sealed class AlwaysAllowMediaCapabilityGate : IMediaCapabilityGate
{
    public Task<MediaCapabilityCheck> CheckAsync(
        MediaFeature feature,
        int? sessionDurationLimitSeconds,
        long? sessionByteBudget,
        MediaCapabilityTransferDirection? transferDirection = null) =>
        Task.FromResult(MediaCapabilityCheck.Allowed(new MediaCapabilityEnvelope(feature)));
}

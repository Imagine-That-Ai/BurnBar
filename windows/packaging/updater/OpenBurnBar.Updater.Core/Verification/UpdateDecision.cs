// The verdict types the updater core produces. Small, allocation-light records
// so the host adapter can pattern-match on them and drive the WinSparkle /
// Squirrel UX. The ONLY status that leads to an install is UpdateAvailable.

using OpenBurnBar.Updater.Core.Feed;

namespace OpenBurnBar.Updater.Core.Verification;

/// <summary>The outcome of evaluating a feed against the installed version, no
/// artifact bytes required yet.</summary>
public enum FeedEvaluationStatus
{
    /// <summary>A strictly-newer, well-formed candidate is available — proceed to
    /// download + <see cref="UpdateFeedVerifier.VerifyArtifact"/>.</summary>
    CandidateAvailable,

    /// <summary>The feed offers the installed version — nothing to do.</summary>
    UpToDate,

    /// <summary>The feed offers an OLDER version — a downgrade; blocked (R19).</summary>
    DowngradeBlocked,

    /// <summary>The feed itself was unusable (see <see cref="RejectionReason"/>).</summary>
    Rejected,
}

/// <summary>Stage-1 result: feed parsed + version compared, no bytes verified yet.</summary>
public sealed record FeedEvaluation
{
    public required FeedEvaluationStatus Status { get; init; }

    /// <summary>The candidate manifest, present only when
    /// <see cref="Status"/> is <see cref="FeedEvaluationStatus.CandidateAvailable"/>.</summary>
    public UpdateManifest? Manifest { get; init; }

    /// <summary>Why the feed was rejected, present only when
    /// <see cref="Status"/> is <see cref="FeedEvaluationStatus.Rejected"/>.</summary>
    public RejectionReason? Reason { get; init; }

    internal static FeedEvaluation Candidate(UpdateManifest manifest) =>
        new() { Status = FeedEvaluationStatus.CandidateAvailable, Manifest = manifest };

    internal static FeedEvaluation UpToDate() => new() { Status = FeedEvaluationStatus.UpToDate };

    internal static FeedEvaluation Downgrade() => new() { Status = FeedEvaluationStatus.DowngradeBlocked };

    internal static FeedEvaluation Reject(RejectionReason reason) =>
        new() { Status = FeedEvaluationStatus.Rejected, Reason = reason };
}

/// <summary>Stage-2 result: the downloaded artifact verified against a manifest.</summary>
public sealed record ArtifactVerification
{
    public required bool Verified { get; init; }

    /// <summary>Why the artifact failed, present only when
    /// <see cref="Verified"/> is false.</summary>
    public RejectionReason? Reason { get; init; }

    internal static ArtifactVerification Pass() => new() { Verified = true };

    internal static ArtifactVerification Fail(RejectionReason reason) =>
        new() { Verified = false, Reason = reason };
}

/// <summary>The combined one-shot verdict (feed + artifact).</summary>
public enum UpdateStatus
{
    /// <summary>A newer build passed EVERY check (version, length, SHA-256, and
    /// the pinned Ed25519 signature) — safe to install.</summary>
    UpdateAvailable,

    /// <summary>Already on the offered version.</summary>
    UpToDate,

    /// <summary>The feed offered an older version; blocked.</summary>
    DowngradeBlocked,

    /// <summary>Something failed a hard check; install nothing.</summary>
    Rejected,
}

/// <summary>The final decision the host acts on.</summary>
public sealed record UpdateDecision
{
    public required UpdateStatus Status { get; init; }

    /// <summary>The verified update, present only when
    /// <see cref="Status"/> is <see cref="UpdateStatus.UpdateAvailable"/>.</summary>
    public UpdateManifest? Manifest { get; init; }

    /// <summary>Why the update was rejected, present only when
    /// <see cref="Status"/> is <see cref="UpdateStatus.Rejected"/>.</summary>
    public RejectionReason? Reason { get; init; }

    /// <summary>True only for a fully-verified, installable update.</summary>
    public bool ShouldInstall => Status == UpdateStatus.UpdateAvailable;

    internal static UpdateDecision Available(UpdateManifest manifest) =>
        new() { Status = UpdateStatus.UpdateAvailable, Manifest = manifest };

    internal static UpdateDecision UpToDate() => new() { Status = UpdateStatus.UpToDate };

    internal static UpdateDecision Downgrade() => new() { Status = UpdateStatus.DowngradeBlocked };

    internal static UpdateDecision Reject(RejectionReason reason) =>
        new() { Status = UpdateStatus.Rejected, Reason = reason };
}

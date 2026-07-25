// The host seam behind which the WinSparkle / Squirrel integration lives.
//
// The portable core owns the security decision (feed parse + downgrade guard +
// pinned Ed25519 verify). A HOST implements the OS-native mechanics — fetching
// the feed over HTTPS, showing the update prompt, downloading the artifact, and
// relaunching the installer — but it MUST route the downloaded bytes back
// through UpdateFeedVerifier before installing. WinSparkle can be configured to
// enforce the same EdDSA pin natively (win_sparkle_set_eddsa_public_key); this
// seam keeps that host swappable and keeps the pin authority in the core either
// way.

using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Updater.Core.Verification;

namespace OpenBurnBar.Updater.Core.Host;

/// <summary>The verified outcome of a non-interactive update check.</summary>
public sealed record BackgroundUpdateCheckResult(
    bool CandidateAvailable,
    string? CandidateVersion)
{
    public static BackgroundUpdateCheckResult UpToDate { get; } = new(false, null);

    public static BackgroundUpdateCheckResult Available(string version)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(version);
        return new BackgroundUpdateCheckResult(true, version);
    }
}

/// <summary>An OS-native updater host driven by the portable core's config.</summary>
public interface IUpdaterHost
{
    /// <summary>Wires the host with the feed URL, pinned key, and current
    /// version. Idempotent; called once at startup.</summary>
    void Configure(UpdaterConfiguration configuration);

    /// <summary>Kicks off a user-visible update check (WinSparkle
    /// check-update-with-ui / Squirrel equivalent).</summary>
    Task CheckForUpdatesWithUiAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Performs a silent background check and returns a verified candidate
    /// without downloading or installing it.
    /// </summary>
    Task<BackgroundUpdateCheckResult> CheckForUpdatesInBackgroundAsync(
        CancellationToken cancellationToken = default);

    /// <summary>
    /// The final gate every host MUST call on the downloaded artifact bytes
    /// before installing. Returns the core's verdict; the host installs iff
    /// <see cref="UpdateDecision.ShouldInstall"/>.
    /// </summary>
    UpdateDecision VerifyDownloadedArtifact(string feedText, byte[] artifactBytes);
}

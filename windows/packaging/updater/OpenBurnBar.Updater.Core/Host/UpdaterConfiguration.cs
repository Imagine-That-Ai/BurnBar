// The transport-agnostic configuration a host updater is wired with.
//
// The host adapter (WinSparkle / Squirrel, net8.0-windows) reads this and drives
// the OS-native update UX; the portable core owns the pin + version so the
// SAME verification runs no matter which host renders the prompt.

using OpenBurnBar.Updater.Core.Feed;
using OpenBurnBar.Updater.Core.Verification;
using OpenBurnBar.Updater.Core.Versioning;

namespace OpenBurnBar.Updater.Core.Host;

/// <summary>Immutable updater wiring: where the feed is, what to pin, who we are.</summary>
public sealed record UpdaterConfiguration
{
    /// <summary>The HTTPS URL of the appcast feed.</summary>
    public required string AppcastUrl { get; init; }

    /// <summary>The validated pinned Ed25519 feed key (R19).</summary>
    public required PinnedUpdateKey PinnedKey { get; init; }

    /// <summary>The currently-installed version, used to block downgrades.</summary>
    public required UpdateVersion CurrentVersion { get; init; }

    /// <summary>Which feed encoding the URL serves.</summary>
    public FeedFormat Format { get; init; } = FeedFormat.Appcast;

    /// <summary>The distribution channel label, e.g. "direct-download".</summary>
    public string Channel { get; init; } = "direct-download";

    /// <summary>Builds the verifier that gates every install for this config.</summary>
    public UpdateFeedVerifier CreateVerifier() => PinnedKey.CreateVerifier();
}

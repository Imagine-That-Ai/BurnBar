// The release-side inputs used to PRODUCE a feed (appcast XML + JSON).
//
// This is the mirror of the arguments scripts/generate-macos-appcast.mjs takes.
// The release pipeline (a Windows runner + the W0 signing key, CI-deferred)
// computes the artifact length + SHA-256, signs the canonical update descriptor with the
// PINNED Ed25519 PRIVATE key, and fills this in; the writers below serialize it
// to the two feed encodings. The tests use it to build a real signed feed and
// prove the full generate -> parse -> pin-verify round trip end to end.

namespace OpenBurnBar.Updater.Core.Feed;

/// <summary>Everything needed to emit one release's appcast + JSON feed.</summary>
public sealed record UpdateReleaseDescriptor
{
    /// <summary>Marketing / short version string, e.g. "1.4.2".</summary>
    public required string Version { get; init; }

    /// <summary>Monotonic build (Sparkle <c>sparkle:version</c>), e.g. "1420".</summary>
    public required string Build { get; init; }

    /// <summary>The MSIX / installer package identity, e.g. "com.openburnbar.app".</summary>
    public required string BundleId { get; init; }

    /// <summary>The artifact download URL.</summary>
    public required string DownloadUrl { get; init; }

    /// <summary>The artifact file name (JSON <c>package</c>), informational.</summary>
    public string? PackageName { get; init; }

    /// <summary>The artifact size in bytes.</summary>
    public required long Length { get; init; }

    /// <summary>Lowercase-hex SHA-256 of the artifact bytes.</summary>
    public required string Sha256 { get; init; }

    /// <summary>Base64 Ed25519 signature over the canonical update descriptor (pinned key).</summary>
    public required string EdSignatureBase64 { get; init; }

    /// <summary>MIME type of the enclosure; MSIX defaults below.</summary>
    public string ArtifactMimeType { get; init; } = "application/msix";

    /// <summary>Whether this is a critical update (re-prompt after "Later").</summary>
    public bool Critical { get; init; }

    /// <summary>Minimum OS build, e.g. "10.0.19041".</summary>
    public string MinimumSystemVersion { get; init; } = "10.0.19041";

    /// <summary>URL of the human-readable release notes.</summary>
    public string? ReleaseNotesUrl { get; init; }

    /// <summary>The canonical URL of the appcast itself (channel &lt;link&gt;).</summary>
    public string? AppcastUrl { get; init; }

    /// <summary>The release commit SHA (JSON <c>commit</c>), informational.</summary>
    public string? Commit { get; init; }

    /// <summary>The distribution channel, e.g. "direct-download".</summary>
    public string Channel { get; init; } = "direct-download";

    /// <summary>RFC-1123 publish date (<c>pubDate</c>); the writer supplies one
    /// when null.</summary>
    public string? PubDate { get; init; }

    /// <summary>ISO-8601 creation timestamp (JSON <c>createdAt</c>); the writer
    /// supplies one when null.</summary>
    public string? CreatedAt { get; init; }
}

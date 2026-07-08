// The parsed, transport-agnostic view of ONE update the feed advertises.
//
// Both feed formats — the Sparkle/WinSparkle appcast XML and the
// latest-windows.json companion — parse into this same record. It carries only
// what the client needs to decide + verify: the version to compare, the
// download URL, the expected byte length, the SHA-256 integrity hash, and the
// Ed25519 signature (base64) that the PINNED key must verify over the artifact
// bytes. The `critical` flag mirrors Sparkle's <sparkle:criticalUpdate> tag
// (re-prompt even after "Later"); `minimumSystemVersion` mirrors
// <sparkle:minimumSystemVersion>.

using OpenBurnBar.Updater.Core.Versioning;

namespace OpenBurnBar.Updater.Core.Feed;

/// <summary>One update entry parsed from a feed, ready for pin-verify.</summary>
public sealed record UpdateManifest
{
    /// <summary>The marketing / short version string (appcast
    /// <c>sparkle:shortVersionString</c>, JSON <c>version</c>), e.g. "1.4.2".</summary>
    public required string Version { get; init; }

    /// <summary>The monotonic build (appcast <c>sparkle:version</c>, JSON
    /// <c>build</c>), e.g. "1420"; optional, informational.</summary>
    public string? Build { get; init; }

    /// <summary>The artifact download URL (appcast enclosure <c>url</c>, JSON
    /// <c>downloadUrl</c>).</summary>
    public required string Url { get; init; }

    /// <summary>The expected artifact size in bytes (enclosure <c>length</c>,
    /// JSON <c>length</c>); 0 / null means "not asserted".</summary>
    public long? Length { get; init; }

    /// <summary>Lowercase-hex SHA-256 of the artifact (JSON <c>sha256</c>;
    /// appcast custom <c>sparkle:sha256</c>).</summary>
    public string? Sha256 { get; init; }

    /// <summary>Base64 Ed25519 signature over the artifact BYTES
    /// (appcast enclosure <c>sparkle:edSignature</c>, JSON
    /// <c>edSignature</c>) — the value the PINNED key must verify.</summary>
    public string? EdSignatureBase64 { get; init; }

    /// <summary>Whether this is a critical update (Sparkle
    /// <c>&lt;sparkle:criticalUpdate&gt;</c>) that re-prompts after "Later".</summary>
    public bool Critical { get; init; }

    /// <summary>Minimum OS version this build supports
    /// (<c>sparkle:minimumSystemVersion</c>), e.g. "10.0.19041".</summary>
    public string? MinimumSystemVersion { get; init; }

    /// <summary>URL of the human-readable release notes
    /// (<c>sparkle:releaseNotesLink</c>).</summary>
    public string? ReleaseNotesUrl { get; init; }

    /// <summary>RFC-1123 publish date (<c>pubDate</c>), informational.</summary>
    public string? PubDate { get; init; }

    /// <summary>Parses <see cref="Version"/> into the comparable version, or
    /// returns false if the feed's version string is not dotted-numeric (which
    /// the verifier treats as a malformed feed, failing closed).</summary>
    public bool TryGetVersion(out UpdateVersion version) => UpdateVersion.TryParse(Version, out version);
}

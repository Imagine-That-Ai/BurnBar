// A single direct-download release offer (Phase 5 · signed distribution).
//
// Pure record (System only). This is the Windows analog of one Sparkle appcast <item> /
// latest-macos.json entry. Every field EXCEPT the signature is bound by the canonical
// descriptor the pinned Ed25519 key signs (see UpdateDescriptorCanonicalizer), so none of
// them — download url, size, sha256, version, channel, minimum OS build, critical flag,
// publish time, release-notes url — can be tampered with without invalidating the signature.

using System;

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>
/// One authenticated-once-verified release offer. Construct via <see cref="UpdateFeedEntry"/>
/// directly (from a trusted builder) or by parsing a feed document
/// (<see cref="UpdateFeedJson"/>). The <see cref="Signature"/> is the base64 Ed25519 signature
/// over the canonical descriptor of the OTHER fields; verification is done by
/// <see cref="Ed25519UpdateFeedVerifier"/> against the PINNED public key.
/// </summary>
public sealed record UpdateFeedEntry
{
    /// <summary>Raw release version string, e.g. "1.0.28". Parsed strictly via <see cref="UpdateVersion"/>.</summary>
    public required string Version { get; init; }

    /// <summary>Target architecture / runtime identifier.</summary>
    public required UpdatePlatform Platform { get; init; }

    /// <summary>Release channel.</summary>
    public required UpdateChannel Channel { get; init; }

    /// <summary>Absolute https URL of the signed installer/zip artifact.</summary>
    public required string Url { get; init; }

    /// <summary>Artifact size in bytes (a defense-in-depth bound on the download).</summary>
    public required long SizeBytes { get; init; }

    /// <summary>Lowercase hex SHA-256 (64 chars) of the artifact bytes — the CONTENT binding.</summary>
    public required string Sha256 { get; init; }

    /// <summary>Minimum Windows OS build (e.g. 17763 for 1809). 0 == no floor.</summary>
    public int MinimumOsBuild { get; init; }

    /// <summary>Security-critical release (drives the "A security fix is ready" copy + forced install).</summary>
    public bool Critical { get; init; }

    /// <summary>Publish timestamp (UTC). Bound by the signature to anchor anti-rollback context.</summary>
    public DateTimeOffset PublishedAtUtc { get; init; }

    /// <summary>Optional absolute https URL of the release notes. Empty == none. Signed when present.</summary>
    public string ReleaseNotesUrl { get; init; } = string.Empty;

    /// <summary>Base64 Ed25519 signature (64 raw bytes) over the canonical descriptor. Empty until signed.</summary>
    public string Signature { get; init; } = string.Empty;

    /// <summary>Return a copy carrying <paramref name="signatureBase64"/> as the detached signature.</summary>
    public UpdateFeedEntry WithSignature(string signatureBase64) => this with { Signature = signatureBase64 };
}

// The updater's security decision tree — the R19 pin-verify crux.
//
// This is the ONE place the client decides whether to install. It is
// FAIL-CLOSED at every branch: it installs iff (1) the feed parses, (2) its
// version is dotted-numeric and strictly newer than the installed build, (3)
// the downloaded artifact's byte length matches, (4) its SHA-256 matches, and
// (5) its Ed25519 signature verifies the canonical update descriptor against
// the PINNED public key. ANY other
// path returns UpToDate / DowngradeBlocked / Rejected — never an install.
//
// The pinned key is Ed25519 and INDEPENDENT of the Authenticode signing
// certificate (mirrors macOS SUPublicEDKey vs. codesign). That independence is
// the whole point: an attacker who breaks the transport, swaps the artifact, or
// even re-signs the installer with a valid Authenticode certificate STILL
// cannot pass step (5) without the pinned feed private key. The SHA-256 check
// is a cheap fail-fast that does NOT weaken this — rewriting the feed's sha256
// to match a malicious payload does not let the attacker forge the Ed25519
// signature over a descriptor for that payload (proven by the SignatureBeatsRewrittenSha256
// test).
//
// The two stages are exposed separately so the host can parse the feed, decide
// whether to spend bandwidth downloading, and only then verify the bytes — but
// Decide() runs the whole pipeline for callers (and tests) that hold both.

using System;
using OpenBurnBar.Updater.Core.Crypto;
using OpenBurnBar.Updater.Core.Feed;
using OpenBurnBar.Updater.Core.Versioning;

namespace OpenBurnBar.Updater.Core.Verification;

/// <summary>Parses a feed, blocks downgrades, and pin-verifies the signed descriptor and artifact.</summary>
public sealed class UpdateFeedVerifier
{
    private readonly IUpdateSignatureVerifier _pinnedVerifier;

    /// <summary>
    /// Constructs a verifier bound to a non-null pinned key. Prefer
    /// <see cref="TryCreate"/> at boundaries where the pin comes from config and
    /// might be malformed.
    /// </summary>
    public UpdateFeedVerifier(IUpdateSignatureVerifier pinnedVerifier)
    {
        _pinnedVerifier = pinnedVerifier ?? throw new ArgumentNullException(nameof(pinnedVerifier));
    }

    /// <summary>The base64 pinned public key this verifier gates every install on.</summary>
    public string PinnedPublicKeyBase64 => _pinnedVerifier.PinnedPublicKeyBase64;

    /// <summary>
    /// Builds a verifier from a base64 pinned Ed25519 key, or returns null if the
    /// pin is empty / not base64 / not 32 bytes. A null return MUST fail the
    /// update closed at the call site — there is no "verify against no key" path.
    /// </summary>
    public static UpdateFeedVerifier? TryCreate(string? pinnedPublicKeyBase64)
    {
        var verifier = Ed25519UpdateSignatureVerifier.FromBase64PublicKey(pinnedPublicKeyBase64);
        return verifier is null ? null : new UpdateFeedVerifier(verifier);
    }

    /// <summary>
    /// Stage 1 — parse the feed and compare its version to the installed build.
    /// No artifact bytes required. Returns CandidateAvailable only for a
    /// well-formed, strictly-newer entry.
    /// </summary>
    public FeedEvaluation EvaluateFeed(string? feedText, FeedFormat format, UpdateVersion currentVersion)
    {
        var manifest = format switch
        {
            FeedFormat.Appcast => AppcastFeedReader.TryParse(feedText),
            FeedFormat.Json => JsonFeedReader.TryParse(feedText),
            _ => null,
        };

        if (manifest is null)
        {
            return FeedEvaluation.Reject(RejectionReason.MalformedFeed);
        }

        if (!manifest.TryGetVersion(out var feedVersion))
        {
            return FeedEvaluation.Reject(RejectionReason.MalformedFeedVersion);
        }

        if (feedVersion < currentVersion)
        {
            return FeedEvaluation.Downgrade();
        }

        if (feedVersion == currentVersion)
        {
            return FeedEvaluation.UpToDate();
        }

        return FeedEvaluation.Candidate(manifest);
    }

    /// <summary>
    /// Stage 2 — verify a downloaded artifact against a candidate manifest:
    /// signature present, length matches, SHA-256 matches, and the Ed25519
    /// signature verifies the canonical descriptor against the PINNED key. The signature check is the
    /// authoritative gate; the others are fail-fast integrity checks that run
    /// first.
    /// </summary>
    public ArtifactVerification VerifyArtifact(UpdateManifest manifest, ReadOnlySpan<byte> artifactBytes)
    {
        ArgumentNullException.ThrowIfNull(manifest);

        if (string.IsNullOrWhiteSpace(manifest.EdSignatureBase64))
        {
            return ArtifactVerification.Fail(RejectionReason.MissingSignature);
        }

        if (string.IsNullOrWhiteSpace(manifest.Sha256))
        {
            return ArtifactVerification.Fail(RejectionReason.MissingSha256);
        }

        if (manifest.Length is { } expectedLength && expectedLength != artifactBytes.Length)
        {
            return ArtifactVerification.Fail(RejectionReason.LengthMismatch);
        }

        if (!Sha256Digest.Matches(artifactBytes, manifest.Sha256))
        {
            return ArtifactVerification.Fail(RejectionReason.Sha256Mismatch);
        }

        byte[] signedDescriptor;
        try
        {
            signedDescriptor = UpdateDescriptorCanonicalizer.CanonicalBytes(manifest);
        }
        catch (FormatException)
        {
            return ArtifactVerification.Fail(RejectionReason.SignatureInvalid);
        }

        byte[] signature;
        try
        {
            signature = Convert.FromBase64String(manifest.EdSignatureBase64!.Trim());
        }
        catch (FormatException)
        {
            return ArtifactVerification.Fail(RejectionReason.SignatureInvalid);
        }

        if (!_pinnedVerifier.Verify(signedDescriptor, signature))
        {
            return ArtifactVerification.Fail(RejectionReason.SignatureInvalid);
        }

        return ArtifactVerification.Pass();
    }

    /// <summary>
    /// The full pipeline: evaluate the feed, then (only for a strictly-newer
    /// candidate) pin-verify the downloaded artifact. Returns an installable
    /// decision only when EVERY check passes.
    /// </summary>
    public UpdateDecision Decide(
        string? feedText,
        FeedFormat format,
        UpdateVersion currentVersion,
        ReadOnlySpan<byte> artifactBytes)
    {
        var evaluation = EvaluateFeed(feedText, format, currentVersion);
        switch (evaluation.Status)
        {
            case FeedEvaluationStatus.UpToDate:
                return UpdateDecision.UpToDate();
            case FeedEvaluationStatus.DowngradeBlocked:
                return UpdateDecision.Downgrade();
            case FeedEvaluationStatus.Rejected:
                return UpdateDecision.Reject(evaluation.Reason!.Value);
        }

        var manifest = evaluation.Manifest!;
        var verification = VerifyArtifact(manifest, artifactBytes);
        return verification.Verified
            ? UpdateDecision.Available(manifest)
            : UpdateDecision.Reject(verification.Reason!.Value);
    }
}

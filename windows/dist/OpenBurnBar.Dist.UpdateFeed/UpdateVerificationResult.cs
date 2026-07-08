// Result of verifying an update offer's pinned signature (Phase 5 · signed distribution).
//
// Pure (System only). A non-authentic result is the fail-closed state: the decision layer maps
// it to "no update", never to "install". The failure reason is diagnostic only — the app must
// treat EVERY non-Authentic result identically (refuse), regardless of reason.

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>Why an update offer failed pinned-signature verification.</summary>
public enum UpdateVerificationFailure
{
    /// <summary>No failure — the offer is authentic.</summary>
    None,

    /// <summary>The offer carried no signature.</summary>
    MissingSignature,

    /// <summary>The signature was not valid base64 or was the wrong length.</summary>
    MalformedSignature,

    /// <summary>A descriptor field was malformed (bad version/sha256/CRLF injection/etc.).</summary>
    MalformedDescriptor,

    /// <summary>The signature was well-formed but did not verify under the pinned key.</summary>
    InvalidSignature,
}

/// <summary>The outcome of pinned Ed25519 verification. <see cref="IsAuthentic"/> is the only
/// bit the security decision depends on.</summary>
public sealed class UpdateVerificationResult
{
    private UpdateVerificationResult(bool isAuthentic, UpdateFeedEntry? entry, UpdateVerificationFailure failure, string message)
    {
        IsAuthentic = isAuthentic;
        Entry = entry;
        Failure = failure;
        Message = message;
    }

    /// <summary>True iff the offer's pinned signature verified over its canonical descriptor.</summary>
    public bool IsAuthentic { get; }

    /// <summary>The verified entry (only when <see cref="IsAuthentic"/>).</summary>
    public UpdateFeedEntry? Entry { get; }

    /// <summary>The failure category (None when authentic).</summary>
    public UpdateVerificationFailure Failure { get; }

    /// <summary>Diagnostic detail. Not to be shown to end users; log-only.</summary>
    public string Message { get; }

    /// <summary>Build an authentic result.</summary>
    public static UpdateVerificationResult Authentic(UpdateFeedEntry entry) =>
        new(true, entry, UpdateVerificationFailure.None, "Authenticated under the pinned update key.");

    /// <summary>Build a fail-closed rejected result.</summary>
    public static UpdateVerificationResult Rejected(UpdateVerificationFailure failure, string message) =>
        new(false, null, failure, message);
}

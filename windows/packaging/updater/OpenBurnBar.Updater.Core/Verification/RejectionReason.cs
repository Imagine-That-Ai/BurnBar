namespace OpenBurnBar.Updater.Core.Verification;

/// <summary>
/// Why the updater refused an update. Every value is a HARD stop — the updater
/// installs nothing unless the decision is <c>UpdateAvailable</c>. The order is
/// diagnostic only; the decision tree short-circuits on the first failure.
/// </summary>
public enum RejectionReason
{
    /// <summary>No usable pinned Ed25519 key was configured — fail closed, never
    /// "verify against nothing".</summary>
    MissingPinnedKey,

    /// <summary>The feed could not be parsed (malformed XML/JSON, wrong root,
    /// no usable item, or a missing required field).</summary>
    MalformedFeed,

    /// <summary>The feed parsed but its advertised version is not
    /// dotted-numeric, so it cannot be compared.</summary>
    MalformedFeedVersion,

    /// <summary>The candidate carried no Ed25519 signature to verify.</summary>
    MissingSignature,

    /// <summary>The candidate carried no SHA-256 to check integrity against.</summary>
    MissingSha256,

    /// <summary>The downloaded artifact's byte length did not match the feed.</summary>
    LengthMismatch,

    /// <summary>The downloaded artifact's SHA-256 did not match the feed.</summary>
    Sha256Mismatch,

    /// <summary>The Ed25519 signature did not verify against the PINNED key —
    /// the authoritative gate (tampered payload, wrong key, or forged
    /// signature).</summary>
    SignatureInvalid,
}

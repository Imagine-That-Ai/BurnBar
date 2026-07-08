// Portable signed-nonce handshake — value types.
//
// Part of the app<->daemon named-pipe peer-auth handshake for the Windows port
// (R16, docs/WINDOWS_PORT_MASTER_PLAN.md). These types are platform-independent:
// they carry the challenge a verifier issues and the signed response a peer
// returns. No OS calls, no crypto implementation — the crypto lives behind the
// INonceSigner / INonceVerifier seams in HandshakeCredentials.cs.

using System;

namespace OpenBurnBar.Pal.Ipc;

/// <summary>
/// Which end of the pipe issued a given challenge. Bound into the signed
/// transcript so a challenge cannot be reflected back at its issuer: the
/// daemon's challenge and the app's challenge sign over different bytes even
/// when the random nonce happens to collide.
/// </summary>
public enum HandshakeRole
{
    /// <summary>The connecting side (the app process opening the pipe).</summary>
    Initiator = 1,

    /// <summary>The listening side (the daemon/service that owns the pipe).</summary>
    Responder = 2,
}

/// <summary>
/// The verdict a <see cref="SignedNonceHandshakeVerifier"/> returns for one
/// response. Exactly one value is returned per <c>Verify</c> call; only
/// <see cref="Accepted"/> authenticates the peer.
/// </summary>
public enum HandshakeVerdict
{
    /// <summary>The response carried a fresh, unexpired nonce with a valid
    /// signature over the expected transcript. The peer is authenticated.</summary>
    Accepted,

    /// <summary>No outstanding challenge matches the response nonce and the nonce
    /// was never accepted before — an unexpected, forged, or stale nonce.</summary>
    RejectedUnknownNonce,

    /// <summary>The response nonce was already accepted by a prior handshake on
    /// this verifier — a replay of a previously valid response.</summary>
    RejectedReplay,

    /// <summary>The outstanding challenge's time-to-live elapsed before the
    /// response arrived.</summary>
    RejectedExpired,

    /// <summary>The nonce matched a live challenge but the signature did not
    /// verify against the peer's public key over the expected transcript.</summary>
    RejectedBadSignature,

    /// <summary>The response was structurally invalid (null/empty nonce or
    /// signature) and could not be evaluated.</summary>
    RejectedMalformed,
}

/// <summary>
/// A nonce challenge a verifier issues to the peer. The peer must return a
/// <see cref="SignedNonceResponse"/> whose signature covers the transcript
/// derived from this challenge (see <see cref="HandshakeTranscript"/>) before
/// the TTL elapses.
/// </summary>
/// <remarks>
/// <see cref="Nonce"/> is compared by content, never by reference; do not rely
/// on record value-equality for this type (arrays compare by reference).
/// </remarks>
public sealed class NonceChallenge
{
    public NonceChallenge(byte[] nonce, long issuedAtUnixMs, long ttlMs, HandshakeRole challengerRole)
    {
        Nonce = nonce ?? throw new ArgumentNullException(nameof(nonce));
        if (nonce.Length == 0)
        {
            throw new ArgumentException("Nonce must be non-empty.", nameof(nonce));
        }

        if (ttlMs <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(ttlMs), ttlMs, "TTL must be positive.");
        }

        IssuedAtUnixMs = issuedAtUnixMs;
        TtlMs = ttlMs;
        ChallengerRole = challengerRole;
    }

    /// <summary>The random challenge bytes. Treated as opaque; never secret.</summary>
    public byte[] Nonce { get; }

    /// <summary>Unix epoch milliseconds when the challenge was issued, per the
    /// issuing verifier's clock.</summary>
    public long IssuedAtUnixMs { get; }

    /// <summary>How long, in milliseconds, the challenge stays valid.</summary>
    public long TtlMs { get; }

    /// <summary>The role of the side that issued this challenge.</summary>
    public HandshakeRole ChallengerRole { get; }

    /// <summary>Unix epoch milliseconds at (and after) which the challenge is
    /// expired.</summary>
    public long ExpiresAtUnixMs => IssuedAtUnixMs + TtlMs;
}

/// <summary>
/// A peer's signed answer to a <see cref="NonceChallenge"/>: the echoed nonce
/// plus a signature over the challenge transcript.
/// </summary>
public sealed class SignedNonceResponse
{
    public SignedNonceResponse(byte[] nonce, byte[] signature)
    {
        Nonce = nonce ?? throw new ArgumentNullException(nameof(nonce));
        Signature = signature ?? throw new ArgumentNullException(nameof(signature));
    }

    /// <summary>The nonce copied from the challenge being answered.</summary>
    public byte[] Nonce { get; }

    /// <summary>The peer's signature over
    /// <see cref="HandshakeTranscript.Build(NonceChallenge)"/>.</summary>
    public byte[] Signature { get; }
}

// Portable signed-nonce handshake — the verifier state machine.
//
// This is the platform-independent heart of the app<->daemon peer-auth handshake
// (R16). A verifier issues a fresh nonce challenge, then evaluates the peer's
// signed response, accepting only a fresh, unexpired nonce carrying a valid
// signature over the expected transcript, and rejecting replays, expired
// challenges, wrong signatures, unknown nonces, and malformed frames.
//
// State (one outstanding challenge at a time — the natural per-connection IPC
// pattern):
//
//        IssueChallenge                 Verify(valid, fresh, in-TTL)
//   Idle ───────────────▶ Challenged ─────────────────────────────▶ Accepted
//     ▲                      │  │                                       │
//     │        Verify(expired / accepted)                              │
//     └──────────────────────┘  └── Verify(bad sig / malformed) keeps ─┘
//                                    the challenge live until it expires
//                                    or a valid response arrives
//
// Replay defense outlives a single challenge: every accepted nonce is remembered
// (bounded history) so a captured valid response is rejected on re-presentation.

using System;
using System.Collections.Generic;

namespace OpenBurnBar.Pal.Ipc;

/// <summary>
/// Evaluates signed-nonce responses from a pipe peer. Not thread-safe: a single
/// verifier drives a single connection's handshake, which is inherently
/// sequential (issue, then verify).
/// </summary>
public sealed class SignedNonceHandshakeVerifier
{
    /// <summary>Default nonce width in bytes (256 bits of entropy).</summary>
    public const int DefaultNonceSizeBytes = 32;

    /// <summary>Default challenge lifetime.</summary>
    public const long DefaultTtlMs = 5_000;

    /// <summary>Default cap on remembered accepted nonces (replay history).</summary>
    public const int DefaultReplayHistoryCapacity = 1_024;

    private readonly INonceVerifier _peerVerifier;
    private readonly IHandshakeClock _clock;
    private readonly INonceSource _nonceSource;
    private readonly int _nonceSizeBytes;
    private readonly long _ttlMs;
    private readonly HandshakeRole _selfRole;
    private readonly int _replayHistoryCapacity;

    // Accepted-nonce history for replay detection. Hex-keyed; FIFO-bounded so a
    // long-lived verifier cannot grow without bound.
    private readonly HashSet<string> _consumed = new(StringComparer.Ordinal);
    private readonly Queue<string> _consumedOrder = new();

    private NonceChallenge? _outstanding;

    /// <param name="peerVerifier">Verifies the peer's signature over the transcript.</param>
    /// <param name="selfRole">This verifier's role; stamped into challenges it issues.</param>
    /// <param name="clock">Time source; defaults to the system clock.</param>
    /// <param name="nonceSource">Randomness source; defaults to a CSPRNG.</param>
    /// <param name="nonceSizeBytes">Nonce width in bytes.</param>
    /// <param name="ttlMs">Challenge lifetime in milliseconds.</param>
    /// <param name="replayHistoryCapacity">How many accepted nonces to remember.</param>
    public SignedNonceHandshakeVerifier(
        INonceVerifier peerVerifier,
        HandshakeRole selfRole,
        IHandshakeClock? clock = null,
        INonceSource? nonceSource = null,
        int nonceSizeBytes = DefaultNonceSizeBytes,
        long ttlMs = DefaultTtlMs,
        int replayHistoryCapacity = DefaultReplayHistoryCapacity)
    {
        _peerVerifier = peerVerifier ?? throw new ArgumentNullException(nameof(peerVerifier));
        _selfRole = selfRole;
        _clock = clock ?? SystemHandshakeClock.Instance;
        _nonceSource = nonceSource ?? CryptoNonceSource.Instance;

        if (nonceSizeBytes is < 16 or > ushort.MaxValue)
        {
            throw new ArgumentOutOfRangeException(
                nameof(nonceSizeBytes), nonceSizeBytes, "Nonce must be 16..65535 bytes.");
        }

        if (ttlMs <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(ttlMs), ttlMs, "TTL must be positive.");
        }

        if (replayHistoryCapacity < 1)
        {
            throw new ArgumentOutOfRangeException(
                nameof(replayHistoryCapacity), replayHistoryCapacity, "Capacity must be >= 1.");
        }

        _nonceSizeBytes = nonceSizeBytes;
        _ttlMs = ttlMs;
        _replayHistoryCapacity = replayHistoryCapacity;
    }

    /// <summary>
    /// True once a challenge has been issued and not yet consumed or expired.
    /// </summary>
    public bool HasOutstandingChallenge => _outstanding is not null;

    /// <summary>
    /// Issues a fresh nonce challenge, replacing any outstanding one. The caller
    /// sends the returned challenge to the peer.
    /// </summary>
    public NonceChallenge IssueChallenge()
    {
        var nonce = new byte[_nonceSizeBytes];
        _nonceSource.Fill(nonce);
        var challenge = new NonceChallenge(nonce, _clock.UnixTimeMilliseconds, _ttlMs, _selfRole);
        _outstanding = challenge;
        return challenge;
    }

    /// <summary>
    /// Evaluates a peer response against the outstanding challenge and returns a
    /// single verdict. Only <see cref="HandshakeVerdict.Accepted"/> authenticates
    /// the peer; on acceptance the nonce is retired into replay history and the
    /// verifier returns to <c>Idle</c>.
    /// </summary>
    public HandshakeVerdict Verify(SignedNonceResponse response)
    {
        if (response is null ||
            response.Nonce is not { Length: > 0 } ||
            response.Signature is not { Length: > 0 })
        {
            return HandshakeVerdict.RejectedMalformed;
        }

        NonceChallenge? outstanding = _outstanding;
        bool matchesOutstanding =
            outstanding is not null && NoncesEqual(outstanding.Nonce, response.Nonce);

        if (!matchesOutstanding)
        {
            // No live challenge for this nonce. Distinguish a replay of a
            // previously accepted nonce from a never-issued (unknown) one.
            return _consumed.Contains(ToKey(response.Nonce))
                ? HandshakeVerdict.RejectedReplay
                : HandshakeVerdict.RejectedUnknownNonce;
        }

        // Expiry is evaluated at or after the expiry instant.
        if (_clock.UnixTimeMilliseconds >= outstanding!.ExpiresAtUnixMs)
        {
            _outstanding = null; // drop the expired challenge; it never authenticated
            return HandshakeVerdict.RejectedExpired;
        }

        byte[] transcript = HandshakeTranscript.Build(outstanding);
        if (!_peerVerifier.Verify(transcript, response.Signature))
        {
            // Keep the challenge live so a duplicated/corrupted frame can be
            // retried within the TTL; the attacker still lacks the peer key.
            return HandshakeVerdict.RejectedBadSignature;
        }

        Retire(outstanding.Nonce);
        _outstanding = null;
        return HandshakeVerdict.Accepted;
    }

    private void Retire(byte[] nonce)
    {
        string key = ToKey(nonce);
        if (_consumed.Add(key))
        {
            _consumedOrder.Enqueue(key);
            while (_consumedOrder.Count > _replayHistoryCapacity)
            {
                _consumed.Remove(_consumedOrder.Dequeue());
            }
        }
    }

    private static bool NoncesEqual(byte[] a, byte[] b)
    {
        if (a.Length != b.Length)
        {
            return false;
        }

        // Nonces are not secret, but a fixed-length compare is cheap and avoids
        // early-exit surprises; use the framework's vectorized comparison.
        return a.AsSpan().SequenceEqual(b);
    }

    private static string ToKey(byte[] nonce) => Convert.ToHexString(nonce);
}

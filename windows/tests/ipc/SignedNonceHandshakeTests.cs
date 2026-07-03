// macOS unit tests for the PORTABLE signed-nonce handshake state machine
// (VAL-P0-CONPTY-018). These prove the contract's required transitions —
//   * accept a valid nonce,
//   * reject a replayed response,
//   * reject an expired challenge,
//   * reject a wrong-signature response,
// — plus the adjacent rejections the state machine must also get right (unknown
// nonce, malformed frame, tampered nonce/transcript, cross-role reflection) and
// the mutual-handshake wiring. Everything runs off-Windows with a real ECDSA
// signer; VAL-P0-CONPTY-019 re-runs the same logic against CNG on Windows.

using System;
using OpenBurnBar.Pal.Ipc;
using Xunit;

namespace OpenBurnBar.Pal.Ipc.Tests;

public sealed class SignedNonceHandshakeTests
{
    private const long TtlMs = 5_000;

    private static SignedNonceHandshakeVerifier NewVerifier(
        INonceVerifier peerVerifier,
        IHandshakeClock? clock = null,
        INonceSource? nonceSource = null,
        HandshakeRole selfRole = HandshakeRole.Responder,
        long ttlMs = TtlMs,
        int replayHistoryCapacity = SignedNonceHandshakeVerifier.DefaultReplayHistoryCapacity) =>
        new(
            peerVerifier,
            selfRole,
            clock: clock,
            nonceSource: nonceSource,
            ttlMs: ttlMs,
            replayHistoryCapacity: replayHistoryCapacity);

    // ── Required: accept a valid nonce ─────────────────────────────────────────
    [Fact]
    public void Verify_ValidFreshResponse_IsAccepted()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock);
        var responder = new SignedNonceResponder(peer.Signer);

        NonceChallenge challenge = verifier.IssueChallenge();
        Assert.True(verifier.HasOutstandingChallenge);

        SignedNonceResponse response = responder.Respond(challenge);

        Assert.Equal(HandshakeVerdict.Accepted, verifier.Verify(response));
        Assert.False(verifier.HasOutstandingChallenge); // returned to Idle
    }

    // ── Required: reject a replay ──────────────────────────────────────────────
    [Fact]
    public void Verify_ReplayedAcceptedResponse_IsRejectedAsReplay()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock);
        var responder = new SignedNonceResponder(peer.Signer);

        SignedNonceResponse response = responder.Respond(verifier.IssueChallenge());
        Assert.Equal(HandshakeVerdict.Accepted, verifier.Verify(response));

        // Re-presenting the exact same valid response must not re-authenticate.
        Assert.Equal(HandshakeVerdict.RejectedReplay, verifier.Verify(response));
    }

    [Fact]
    public void Verify_ReplayAcrossReissuedChallenge_IsStillReplay()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock);
        var responder = new SignedNonceResponder(peer.Signer);

        SignedNonceResponse first = responder.Respond(verifier.IssueChallenge());
        Assert.Equal(HandshakeVerdict.Accepted, verifier.Verify(first));

        // A brand-new challenge is outstanding; replaying the OLD nonce still
        // resolves to replay (it is in history), not unknown.
        verifier.IssueChallenge();
        Assert.Equal(HandshakeVerdict.RejectedReplay, verifier.Verify(first));
    }

    // ── Required: reject an expired challenge ──────────────────────────────────
    [Fact]
    public void Verify_ResponseAfterTtl_IsRejectedAsExpired()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock, ttlMs: TtlMs);
        var responder = new SignedNonceResponder(peer.Signer);

        NonceChallenge challenge = verifier.IssueChallenge();
        SignedNonceResponse response = responder.Respond(challenge);

        clock.Advance(TtlMs); // reach the expiry instant exactly

        Assert.Equal(HandshakeVerdict.RejectedExpired, verifier.Verify(response));
        Assert.False(verifier.HasOutstandingChallenge); // expired challenge dropped
    }

    [Fact]
    public void Verify_ResponseJustBeforeTtl_IsAccepted()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock, ttlMs: TtlMs);
        var responder = new SignedNonceResponder(peer.Signer);

        SignedNonceResponse response = responder.Respond(verifier.IssueChallenge());

        clock.Advance(TtlMs - 1); // still inside the window

        Assert.Equal(HandshakeVerdict.Accepted, verifier.Verify(response));
    }

    [Fact]
    public void Verify_ExpiredThenReplayed_IsUnknownNotReplay()
    {
        // An expired challenge never authenticated, so its nonce is NOT in replay
        // history; a later presentation is unknown, not a replay.
        using var peer = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock, ttlMs: TtlMs);
        var responder = new SignedNonceResponder(peer.Signer);

        SignedNonceResponse response = responder.Respond(verifier.IssueChallenge());
        clock.Advance(TtlMs);
        Assert.Equal(HandshakeVerdict.RejectedExpired, verifier.Verify(response));
        Assert.Equal(HandshakeVerdict.RejectedUnknownNonce, verifier.Verify(response));
    }

    // ── Required: reject a wrong signature ─────────────────────────────────────
    [Fact]
    public void Verify_ResponseSignedByWrongKey_IsRejectedAsBadSignature()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        using var attacker = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock); // pins the peer key
        var attackerResponder = new SignedNonceResponder(attacker.Signer);

        NonceChallenge challenge = verifier.IssueChallenge();
        SignedNonceResponse forged = attackerResponder.Respond(challenge);

        Assert.Equal(HandshakeVerdict.RejectedBadSignature, verifier.Verify(forged));
    }

    [Fact]
    public void Verify_TamperedSignatureBytes_IsRejectedAsBadSignature()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock);
        var responder = new SignedNonceResponder(peer.Signer);

        SignedNonceResponse response = responder.Respond(verifier.IssueChallenge());
        response.Signature[^1] ^= 0xFF; // flip a bit in the signature

        Assert.Equal(HandshakeVerdict.RejectedBadSignature, verifier.Verify(response));
    }

    [Fact]
    public void Verify_BadSignatureThenValidRetry_WithinTtl_IsAccepted()
    {
        // A bad signature does not consume the challenge; a correct retry within
        // the TTL still authenticates.
        using var peer = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock);
        var responder = new SignedNonceResponder(peer.Signer);

        NonceChallenge challenge = verifier.IssueChallenge();
        var corrupt = new SignedNonceResponse((byte[])challenge.Nonce.Clone(), new byte[] { 1, 2, 3 });
        Assert.Equal(HandshakeVerdict.RejectedBadSignature, verifier.Verify(corrupt));
        Assert.True(verifier.HasOutstandingChallenge); // still live

        SignedNonceResponse good = responder.Respond(challenge);
        Assert.Equal(HandshakeVerdict.Accepted, verifier.Verify(good));
    }

    // ── Adjacent rejections the FSM must also get right ────────────────────────
    [Fact]
    public void Verify_NeverIssuedNonce_IsRejectedAsUnknown()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var verifier = NewVerifier(peer.Verifier, new ManualClock());
        var responder = new SignedNonceResponder(peer.Signer);

        // Sign an arbitrary challenge the verifier never issued.
        var strayChallenge = new NonceChallenge(
            new byte[32], issuedAtUnixMs: 0, ttlMs: TtlMs, HandshakeRole.Responder);
        SignedNonceResponse response = responder.Respond(strayChallenge);

        Assert.Equal(HandshakeVerdict.RejectedUnknownNonce, verifier.Verify(response));
    }

    [Fact]
    public void Verify_ResponseWithNoOutstandingChallenge_IsUnknown()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var verifier = NewVerifier(peer.Verifier, new ManualClock());

        var response = new SignedNonceResponse(new byte[32], new byte[] { 9, 9, 9 });
        Assert.Equal(HandshakeVerdict.RejectedUnknownNonce, verifier.Verify(response));
    }

    [Fact]
    public void Verify_TamperedNonce_IsRejectedAsUnknown()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var verifier = NewVerifier(peer.Verifier, new ManualClock());
        var responder = new SignedNonceResponder(peer.Signer);

        NonceChallenge challenge = verifier.IssueChallenge();
        SignedNonceResponse response = responder.Respond(challenge);
        response.Nonce[0] ^= 0x01; // no longer matches the outstanding challenge

        Assert.Equal(HandshakeVerdict.RejectedUnknownNonce, verifier.Verify(response));
    }

    [Theory]
    [InlineData(true, false)]  // empty nonce
    [InlineData(false, true)]  // empty signature
    [InlineData(true, true)]   // both empty
    public void Verify_EmptyFields_AreRejectedAsMalformed(bool emptyNonce, bool emptySignature)
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var verifier = NewVerifier(peer.Verifier, new ManualClock());
        verifier.IssueChallenge();

        var response = new SignedNonceResponse(
            emptyNonce ? Array.Empty<byte>() : new byte[32],
            emptySignature ? Array.Empty<byte>() : new byte[] { 1 });

        Assert.Equal(HandshakeVerdict.RejectedMalformed, verifier.Verify(response));
    }

    // ── Role binding: a challenge cannot be reflected back at its issuer ────────
    [Fact]
    public void Verify_ResponseToPeersOwnChallengeRole_IsRejected()
    {
        // The verifier issues as Responder. A response whose signature was made
        // over the SAME nonce but the Initiator transcript must not verify —
        // proving the challenger role is bound into the signature.
        using var peer = new EcdsaHandshakeKeyPair();
        var verifier = NewVerifier(peer.Verifier, new ManualClock(), selfRole: HandshakeRole.Responder);

        NonceChallenge challenge = verifier.IssueChallenge();

        // Sign the wrong-role transcript for the same nonce.
        byte[] wrongRoleTranscript =
            HandshakeTranscript.Build(HandshakeRole.Initiator, challenge.Nonce);
        byte[] signature = peer.Signer.Sign(wrongRoleTranscript);
        var response = new SignedNonceResponse((byte[])challenge.Nonce.Clone(), signature);

        Assert.Equal(HandshakeVerdict.RejectedBadSignature, verifier.Verify(response));
    }

    // ── Full mutual handshake between two endpoints ────────────────────────────
    [Fact]
    public void MutualHandshake_BetweenTwoEndpoints_BothSidesAuthenticate()
    {
        using var appKey = new EcdsaHandshakeKeyPair();
        using var daemonKey = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();

        // Each endpoint signs with its own key and verifies the peer's key.
        var app = new MutualHandshakeEndpoint(
            HandshakeRole.Initiator, appKey.Signer, daemonKey.Verifier, clock);
        var daemon = new MutualHandshakeEndpoint(
            HandshakeRole.Responder, daemonKey.Signer, appKey.Verifier, clock);

        // Direction 1: daemon challenges, app answers.
        NonceChallenge daemonChallenge = daemon.Verifier.IssueChallenge();
        SignedNonceResponse appAnswer = app.Responder.Respond(daemonChallenge);
        Assert.Equal(HandshakeVerdict.Accepted, daemon.Verifier.Verify(appAnswer));

        // Direction 2: app challenges, daemon answers.
        NonceChallenge appChallenge = app.Verifier.IssueChallenge();
        SignedNonceResponse daemonAnswer = daemon.Responder.Respond(appChallenge);
        Assert.Equal(HandshakeVerdict.Accepted, app.Verifier.Verify(daemonAnswer));
    }

    [Fact]
    public void MutualHandshake_ReflectionAcrossDirections_IsRejected()
    {
        // Same nonce in both directions must not let one side's answer satisfy
        // the other side's challenge, because the roles differ.
        using var appKey = new EcdsaHandshakeKeyPair();
        using var daemonKey = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        byte[] fixedNonce = new byte[32];
        for (int i = 0; i < fixedNonce.Length; i++)
        {
            fixedNonce[i] = (byte)i;
        }

        var app = new MutualHandshakeEndpoint(
            HandshakeRole.Initiator, appKey.Signer, daemonKey.Verifier, clock,
            new ScriptedNonceSource(fixedNonce));
        var daemon = new MutualHandshakeEndpoint(
            HandshakeRole.Responder, daemonKey.Signer, appKey.Verifier, clock,
            new ScriptedNonceSource(fixedNonce));

        NonceChallenge appChallenge = app.Verifier.IssueChallenge();     // Initiator role
        SignedNonceResponse daemonAnswer = daemon.Responder.Respond(appChallenge);

        // The daemon's verifier issued a Responder-role challenge with the SAME
        // nonce; feeding the app's Initiator-role answer to it must fail on the
        // role-bound transcript.
        daemon.Verifier.IssueChallenge();
        Assert.Equal(HandshakeVerdict.RejectedBadSignature, daemon.Verifier.Verify(daemonAnswer));
    }

    // ── Replay history stays bounded but never forgets the most recent nonce ───
    [Fact]
    public void ReplayHistory_IsBounded_ButRecentNonceStillDetected()
    {
        using var peer = new EcdsaHandshakeKeyPair();
        var clock = new ManualClock();
        var verifier = NewVerifier(peer.Verifier, clock, replayHistoryCapacity: 2);
        var responder = new SignedNonceResponder(peer.Signer);

        SignedNonceResponse[] accepted = new SignedNonceResponse[4];
        for (int i = 0; i < accepted.Length; i++)
        {
            SignedNonceResponse r = responder.Respond(verifier.IssueChallenge());
            Assert.Equal(HandshakeVerdict.Accepted, verifier.Verify(r));
            accepted[i] = r;
        }

        // The two most recent accepted nonces are still detected as replays.
        Assert.Equal(HandshakeVerdict.RejectedReplay, verifier.Verify(accepted[3]));
        Assert.Equal(HandshakeVerdict.RejectedReplay, verifier.Verify(accepted[2]));

        // The oldest, evicted from the bounded history, downgrades to unknown —
        // acceptable because it is also long expired in any real deployment.
        Assert.Equal(HandshakeVerdict.RejectedUnknownNonce, verifier.Verify(accepted[0]));
    }

    // ── Transcript encoding is unambiguous (length-prefixed) ───────────────────
    [Fact]
    public void Transcript_DiffersByRole_ForSameNonce()
    {
        byte[] nonce = new byte[16];
        byte[] asInitiator = HandshakeTranscript.Build(HandshakeRole.Initiator, nonce);
        byte[] asResponder = HandshakeTranscript.Build(HandshakeRole.Responder, nonce);

        Assert.NotEqual(asInitiator, asResponder);
    }
}

// Portable signed-nonce handshake — the responder half.
//
// The verifier (SignedNonceHandshakeVerifier) issues challenges and grades
// responses; this is the other end — it takes a challenge received from the peer
// and returns the signed response. Kept tiny and stateless so both the app and
// the daemon can run one of each (verifier + responder) to achieve the mutual
// handshake R16 requires.

using System;

namespace OpenBurnBar.Pal.Ipc;

/// <summary>
/// Signs an incoming <see cref="NonceChallenge"/> with this side's private key,
/// producing the <see cref="SignedNonceResponse"/> to return to the challenger.
/// </summary>
public sealed class SignedNonceResponder
{
    private readonly INonceSigner _signer;

    public SignedNonceResponder(INonceSigner signer)
    {
        _signer = signer ?? throw new ArgumentNullException(nameof(signer));
    }

    /// <summary>
    /// Builds the transcript for <paramref name="challenge"/> (binding the
    /// challenger's role, per <see cref="HandshakeTranscript"/>) and signs it.
    /// </summary>
    public SignedNonceResponse Respond(NonceChallenge challenge)
    {
        if (challenge is null)
        {
            throw new ArgumentNullException(nameof(challenge));
        }

        byte[] transcript = HandshakeTranscript.Build(challenge);
        byte[] signature = _signer.Sign(transcript);

        // Echo a defensive copy of the nonce so the caller cannot mutate the
        // challenge's buffer through the response.
        return new SignedNonceResponse((byte[])challenge.Nonce.Clone(), signature);
    }
}

/// <summary>
/// Convenience wiring for the full mutual handshake: each side holds its own
/// signer (to answer the peer's challenge) and the peer's verifier (to grade the
/// peer's answer to its own challenge). This type just bundles the two portable
/// halves for one endpoint; the transport (named pipe on Windows) drives the
/// message exchange.
/// </summary>
public sealed class MutualHandshakeEndpoint
{
    /// <param name="selfRole">This endpoint's role in the exchange.</param>
    /// <param name="selfSigner">Signs challenges received from the peer.</param>
    /// <param name="peerVerifier">Verifies the peer's answers to this side's challenges.</param>
    /// <param name="clock">Optional clock override.</param>
    /// <param name="nonceSource">Optional randomness override.</param>
    public MutualHandshakeEndpoint(
        HandshakeRole selfRole,
        INonceSigner selfSigner,
        INonceVerifier peerVerifier,
        IHandshakeClock? clock = null,
        INonceSource? nonceSource = null)
    {
        Role = selfRole;
        Responder = new SignedNonceResponder(selfSigner);
        Verifier = new SignedNonceHandshakeVerifier(
            peerVerifier, selfRole, clock: clock, nonceSource: nonceSource);
    }

    /// <summary>This endpoint's role.</summary>
    public HandshakeRole Role { get; }

    /// <summary>Grades the peer's answers to challenges this endpoint issues.</summary>
    public SignedNonceHandshakeVerifier Verifier { get; }

    /// <summary>Signs challenges the peer issues to this endpoint.</summary>
    public SignedNonceResponder Responder { get; }
}

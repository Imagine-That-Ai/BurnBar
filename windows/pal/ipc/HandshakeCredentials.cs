// Portable signed-nonce handshake — the crypto / clock / RNG seams.
//
// The handshake state machine depends only on these interfaces, never on a
// concrete algorithm or OS API. That is what makes it portable:
//   * macOS authoring host (VAL-P0-CONPTY-018) injects an ECDSA-P256 signer /
//     verifier + a deterministic clock in the unit tests.
//   * The Windows harness (VAL-P0-CONPTY-019) injects CNG/TPM-backed credentials
//     (OpenBurnBar.Pal.Ipc.Windows.CngNonceCredentials) with a real system clock.
//
// The signer and verifier both operate over the domain-separated transcript
// built by HandshakeTranscript; neither ever sees the raw nonce alone.

using System;
using System.Security.Cryptography;

namespace OpenBurnBar.Pal.Ipc;

/// <summary>
/// Signs a handshake transcript with this side's private key. On Windows the
/// private key is a non-exportable CNG key held in the TPM (R15/R16); the
/// interface hides that so the state machine stays portable.
/// </summary>
public interface INonceSigner
{
    /// <summary>Produces a detached signature over <paramref name="message"/>.</summary>
    byte[] Sign(ReadOnlySpan<byte> message);
}

/// <summary>
/// Verifies a handshake transcript signature against the peer's pinned public
/// key. Implementations MUST perform the comparison in the underlying crypto
/// primitive (constant-time), not by hand.
/// </summary>
public interface INonceVerifier
{
    /// <summary>Returns <c>true</c> iff <paramref name="signature"/> is a valid
    /// signature over <paramref name="message"/> for the pinned peer key.</summary>
    bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature);
}

/// <summary>
/// The verifier's monotonic-enough source of wall-clock time, in Unix epoch
/// milliseconds. Abstracted so tests can drive expiry deterministically without
/// sleeping.
/// </summary>
public interface IHandshakeClock
{
    /// <summary>Current time in Unix epoch milliseconds.</summary>
    long UnixTimeMilliseconds { get; }
}

/// <summary>
/// Fills a buffer with cryptographically strong random bytes for nonce
/// generation. Abstracted so tests can substitute a deterministic source when
/// they need reproducible nonces.
/// </summary>
public interface INonceSource
{
    /// <summary>Fills the whole span with random bytes.</summary>
    void Fill(Span<byte> buffer);
}

/// <summary>
/// Default <see cref="IHandshakeClock"/> backed by the system wall clock.
/// </summary>
public sealed class SystemHandshakeClock : IHandshakeClock
{
    public static readonly SystemHandshakeClock Instance = new();

    public long UnixTimeMilliseconds => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

/// <summary>
/// Default <see cref="INonceSource"/> backed by <see cref="RandomNumberGenerator"/>.
/// </summary>
public sealed class CryptoNonceSource : INonceSource
{
    public static readonly CryptoNonceSource Instance = new();

    public void Fill(Span<byte> buffer) => RandomNumberGenerator.Fill(buffer);
}

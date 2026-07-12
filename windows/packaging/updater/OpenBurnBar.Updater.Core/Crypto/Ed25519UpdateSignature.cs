// Ed25519 (RFC 8032) update-feed signature verifier + signer seams.
//
// This is the R19 security crux of the Windows auto-updater. The macOS app
// ships a Sparkle appcast whose `sparkle:edSignature` is a base64 Ed25519
// signature over the RAW BYTES of the download artifact, verified against a
// public key PINNED in the app (SUPublicEDKey) INDEPENDENT of the codesign
// certificate. This mirrors that exactly for Windows: the pinned Ed25519 key
// gates every install, so tampering the feed transport, swapping the artifact,
// or even re-signing with the Authenticode certificate cannot ship a payload
// the pinned feed key did not sign.
//
// The .NET BCL ships no Ed25519, so the default implementation uses the
// pure-managed, cross-platform BouncyCastle primitive — REAL RFC-8032
// signatures on the macOS authoring host and Windows CI alike. Verification is
// exposed behind IUpdateSignatureVerifier so a host can substitute a different
// primitive without touching the feed / version / decision logic. The signer
// exists only so the release-side tooling and the tests can PRODUCE a signed
// feed; the client never signs.

using System;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace OpenBurnBar.Updater.Core.Crypto;

/// <summary>
/// Verifies a detached Ed25519 signature against a PINNED public key. The
/// comparison happens inside the crypto primitive (constant-time), never by
/// hand. A verifier is bound to exactly one pinned key for its whole lifetime.
/// </summary>
public interface IUpdateSignatureVerifier
{
    /// <summary>The 32-byte raw Ed25519 public key this verifier pins, base64.</summary>
    string PinnedPublicKeyBase64 { get; }

    /// <summary>
    /// True iff <paramref name="signature"/> is a valid Ed25519 signature over
    /// <paramref name="message"/> for the pinned public key. Returns false —
    /// never throws — for a wrong-length signature so callers fail closed.
    /// </summary>
    bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature);
}

/// <summary>Ed25519 sizing constants (RFC 8032).</summary>
public static class Ed25519Sizes
{
    /// <summary>Raw Ed25519 public keys and private seeds are 32 bytes.</summary>
    public const int KeySize = 32;

    /// <summary>Detached Ed25519 signatures are 64 bytes.</summary>
    public const int SignatureSize = 64;
}

/// <summary>
/// Default <see cref="IUpdateSignatureVerifier"/> over a raw 32-byte Ed25519
/// public key. Constructed from the pinned key that ships in the app; a null is
/// returned from the factory helpers when the pinned key is malformed so the
/// caller can fail closed rather than run with a bogus pin.
/// </summary>
public sealed class Ed25519UpdateSignatureVerifier : IUpdateSignatureVerifier
{
    private readonly Ed25519PublicKeyParameters _publicKey;

    private Ed25519UpdateSignatureVerifier(Ed25519PublicKeyParameters publicKey, string pinnedBase64)
    {
        _publicKey = publicKey;
        PinnedPublicKeyBase64 = pinnedBase64;
    }

    public string PinnedPublicKeyBase64 { get; }

    /// <summary>Builds a verifier from a 32-byte raw pinned public key.</summary>
    public static Ed25519UpdateSignatureVerifier FromRawPublicKey(ReadOnlySpan<byte> rawPublicKey)
    {
        if (rawPublicKey.Length != Ed25519Sizes.KeySize)
        {
            throw new ArgumentException(
                $"Ed25519 public key must be {Ed25519Sizes.KeySize} bytes.", nameof(rawPublicKey));
        }

        var raw = rawPublicKey.ToArray();
        return new Ed25519UpdateSignatureVerifier(
            new Ed25519PublicKeyParameters(raw, 0), Convert.ToBase64String(raw));
    }

    /// <summary>
    /// Builds a verifier from a base64 raw pinned public key, or null if the
    /// pin is empty / not base64 / not 32 bytes. A null pin MUST fail the whole
    /// update closed at the call site — never fall through to "no verification".
    /// </summary>
    public static Ed25519UpdateSignatureVerifier? FromBase64PublicKey(string? publicKeyBase64)
    {
        if (string.IsNullOrWhiteSpace(publicKeyBase64))
        {
            return null;
        }

        byte[] raw;
        try
        {
            raw = Convert.FromBase64String(publicKeyBase64);
        }
        catch (FormatException)
        {
            return null;
        }

        if (raw.Length != Ed25519Sizes.KeySize)
        {
            return null;
        }

        return new Ed25519UpdateSignatureVerifier(
            new Ed25519PublicKeyParameters(raw, 0), Convert.ToBase64String(raw));
    }

    public bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature)
    {
        if (signature.Length != Ed25519Sizes.SignatureSize)
        {
            return false;
        }

        var verifier = new Org.BouncyCastle.Crypto.Signers.Ed25519Signer();
        verifier.Init(forSigning: false, _publicKey);
        var buffer = message.ToArray();
        verifier.BlockUpdate(buffer, 0, buffer.Length);
        return verifier.VerifySignature(signature.ToArray());
    }
}

/// <summary>
/// An Ed25519 key pair used ONLY by the release-side feed generator and the
/// tests to PRODUCE a signed feed. Raw 32-byte seed / public key match the
/// CryptoKit <c>rawRepresentation</c> encoding, so a key minted on macOS
/// verifies here and vice-versa. The client updater never holds a private key.
/// </summary>
public sealed class Ed25519UpdateKeyPair
{
    private readonly Ed25519PrivateKeyParameters _privateKey;
    private readonly Ed25519PublicKeyParameters _publicKey;

    private Ed25519UpdateKeyPair(Ed25519PrivateKeyParameters privateKey, Ed25519PublicKeyParameters publicKey)
    {
        _privateKey = privateKey;
        _publicKey = publicKey;
    }

    /// <summary>Generates a fresh key pair from cryptographically strong randomness.</summary>
    public static Ed25519UpdateKeyPair Generate()
    {
        Span<byte> seed = stackalloc byte[Ed25519Sizes.KeySize];
        System.Security.Cryptography.RandomNumberGenerator.Fill(seed);
        return FromSeed(seed);
    }

    /// <summary>Rebuilds a key pair from a 32-byte raw private seed.</summary>
    public static Ed25519UpdateKeyPair FromSeed(ReadOnlySpan<byte> seed)
    {
        if (seed.Length != Ed25519Sizes.KeySize)
        {
            throw new ArgumentException(
                $"Ed25519 seed must be {Ed25519Sizes.KeySize} bytes.", nameof(seed));
        }

        var privateKey = new Ed25519PrivateKeyParameters(seed.ToArray(), 0);
        return new Ed25519UpdateKeyPair(privateKey, privateKey.GeneratePublicKey());
    }

    /// <summary>The 32-byte raw public key (CryptoKit rawRepresentation).</summary>
    public byte[] PublicKeyRaw => _publicKey.GetEncoded();

    /// <summary>The 32-byte raw public key, base64 — the value pinned in the app.</summary>
    public string PublicKeyBase64 => Convert.ToBase64String(PublicKeyRaw);

    /// <summary>Produces a detached Ed25519 signature over caller-supplied bytes.</summary>
    public byte[] Sign(ReadOnlySpan<byte> message)
    {
        var signer = new Org.BouncyCastle.Crypto.Signers.Ed25519Signer();
        signer.Init(forSigning: true, _privateKey);
        var buffer = message.ToArray();
        signer.BlockUpdate(buffer, 0, buffer.Length);
        return signer.GenerateSignature();
    }

    /// <summary>The detached signature over caller-supplied bytes, base64 — the
    /// value that goes into the feed's <c>sparkle:edSignature</c> / JSON
    /// <c>edSignature</c> field.</summary>
    public string SignBase64(ReadOnlySpan<byte> message) => Convert.ToBase64String(Sign(message));

    /// <summary>A verifier bound to this key pair's public key.</summary>
    public IUpdateSignatureVerifier Verifier() =>
        Ed25519UpdateSignatureVerifier.FromRawPublicKey(PublicKeyRaw);
}

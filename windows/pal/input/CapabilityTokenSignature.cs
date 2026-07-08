// Ed25519 signature seam + a pure-managed implementation.
//
// The verification STATE MACHINE (VirtualHidCapabilityTokenVerifier) is algorithm-
// agnostic: it depends only on ICapabilityTokenSignatureVerifier. The default
// implementation is BouncyCastle Ed25519 — the SAME primitive as macOS CryptoKit
// Curve25519.Signing, over the SAME canonical bytes (CapabilityTokenCanonicalizer) — so
// a token minted by the macOS PDP verifies here byte-for-byte. Both the verifier and a
// reference signer (for issuers + tests) are portable and exercised by `dotnet test` on
// macOS.

using System;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;

namespace OpenBurnBar.Pal.Input;

/// <summary>
/// Verifies a detached signature over a message with a raw public key. Kept as a seam so
/// the token verification state machine has no crypto-library dependency and can be driven
/// from a fixture.
/// </summary>
public interface ICapabilityTokenSignatureVerifier
{
    /// <summary>True iff <paramref name="signature"/> is a valid signature over
    /// <paramref name="message"/> under <paramref name="publicKey"/>. Never throws — a
    /// malformed key/signature returns false (fail-closed).</summary>
    bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature, ReadOnlySpan<byte> publicKey);
}

/// <summary>
/// Ed25519 verifier (raw 32-byte public key, 64-byte signature). Matches macOS
/// Curve25519.Signing. Pure-managed (BouncyCastle) so it restores + runs on macOS.
/// </summary>
public sealed class Ed25519CapabilityTokenSignatureVerifier : ICapabilityTokenSignatureVerifier
{
    /// <summary>Raw Ed25519 public-key length (bytes).</summary>
    private const int PublicKeySize = 32;

    /// <summary>Ed25519 detached-signature length (bytes).</summary>
    private const int SignatureSize = 64;

    public bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature, ReadOnlySpan<byte> publicKey)
    {
        if (publicKey.Length != PublicKeySize || signature.Length != SignatureSize)
        {
            return false;
        }

        try
        {
            var parameters = new Ed25519PublicKeyParameters(publicKey.ToArray(), 0);
            var verifier = new Ed25519Signer();
            verifier.Init(false, parameters);
            var message2 = message.ToArray();
            verifier.BlockUpdate(message2, 0, message2.Length);
            return verifier.VerifySignature(signature.ToArray());
        }
        catch (Exception)
        {
            // A malformed key or signature must never authenticate a peer.
            return false;
        }
    }
}

/// <summary>A raw Ed25519 key pair (32-byte public + 32-byte private seed).</summary>
public sealed class Ed25519CapabilityKeyPair
{
    public Ed25519CapabilityKeyPair(byte[] publicKey, byte[] privateKey)
    {
        PublicKey = publicKey;
        PrivateKey = privateKey;
    }

    public byte[] PublicKey { get; }
    public byte[] PrivateKey { get; }
}

/// <summary>
/// Reference Ed25519 signer for the PDP issuer path (and tests): mints the base64
/// signature over the canonical token bytes. The macOS PDP does the equivalent with
/// CryptoKit; on Windows the same PDP logic runs here.
/// </summary>
public sealed class Ed25519CapabilityTokenSigner
{
    private readonly SecureRandom _random = new();

    /// <summary>Generate a fresh raw Ed25519 key pair.</summary>
    public Ed25519CapabilityKeyPair GenerateKeyPair()
    {
        var generator = new Ed25519KeyPairGenerator();
        generator.Init(new Ed25519KeyGenerationParameters(_random));
        var pair = generator.GenerateKeyPair();
        var priv = (Ed25519PrivateKeyParameters)pair.Private;
        var pub = (Ed25519PublicKeyParameters)pair.Public;
        return new Ed25519CapabilityKeyPair(pub.GetEncoded(), priv.GetEncoded());
    }

    /// <summary>Sign the canonical bytes of <paramref name="token"/> and return a copy
    /// carrying the base64 signature.</summary>
    public VirtualHidCapabilityToken Sign(VirtualHidCapabilityToken token, byte[] privateKey)
    {
        var payload = CapabilityTokenCanonicalizer.CanonicalBytes(token);
        var parameters = new Ed25519PrivateKeyParameters(privateKey, 0);
        var signer = new Ed25519Signer();
        signer.Init(true, parameters);
        signer.BlockUpdate(payload, 0, payload.Length);
        var signature = signer.GenerateSignature();
        return token.WithSignature(Convert.ToBase64String(signature));
    }
}

// Ed25519 (RFC 8032) signer / verifier seams + a pure-managed default.
//
// The Swift core signs capability tokens and audit heads with
// CryptoKit.Curve25519.Signing (Ed25519). The .NET BCL ships no Ed25519, so
// the default implementation here uses the pure-managed, cross-platform
// BouncyCastle primitive — REAL RFC-8032 signatures on the macOS authoring host
// and Windows CI alike. The state machines depend ONLY on the ICapabilitySigner
// / ICapabilityVerifier seams, so a Windows dev host can substitute a CNG/TPM
// non-exportable key (R15/R16) without touching token or audit logic.

using System;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace OpenBurnBar.ComputerUse.Core.Crypto;

/// <summary>
/// Produces a detached Ed25519 signature over a message. On Windows the private
/// key may be a non-exportable CNG/TPM key; the interface hides that.
/// </summary>
public interface ICapabilitySigner
{
    /// <summary>The 32-byte raw Ed25519 public key matching this signer, base64.</summary>
    string PublicKeyBase64 { get; }

    /// <summary>Detached signature bytes over <paramref name="message"/>.</summary>
    byte[] Sign(ReadOnlySpan<byte> message);
}

/// <summary>
/// Verifies a detached Ed25519 signature against a pinned public key. The
/// comparison happens inside the crypto primitive (constant-time), never by hand.
/// </summary>
public interface ICapabilityVerifier
{
    /// <summary>True iff <paramref name="signature"/> is valid over
    /// <paramref name="message"/> for the pinned public key.</summary>
    bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature);
}

/// <summary>
/// Pure-managed Ed25519 key pair. Raw 32-byte seed / public key match the
/// <c>rawRepresentation</c> encoding CryptoKit uses, so a key minted on macOS
/// verifies here and vice-versa.
/// </summary>
public sealed class Ed25519KeyPair
{
    private readonly Ed25519PrivateKeyParameters _privateKey;
    private readonly Ed25519PublicKeyParameters _publicKey;

    private Ed25519KeyPair(Ed25519PrivateKeyParameters privateKey, Ed25519PublicKeyParameters publicKey)
    {
        _privateKey = privateKey;
        _publicKey = publicKey;
    }

    /// <summary>Generates a fresh key pair from cryptographically strong randomness.</summary>
    public static Ed25519KeyPair Generate()
    {
        Span<byte> seed = stackalloc byte[Ed25519PrivateKeyParameters.KeySize];
        System.Security.Cryptography.RandomNumberGenerator.Fill(seed);
        return FromSeed(seed);
    }

    /// <summary>Rebuilds a key pair from a 32-byte raw private seed.</summary>
    public static Ed25519KeyPair FromSeed(ReadOnlySpan<byte> seed)
    {
        if (seed.Length != Ed25519PrivateKeyParameters.KeySize)
        {
            throw new ArgumentException(
                $"Ed25519 seed must be {Ed25519PrivateKeyParameters.KeySize} bytes.", nameof(seed));
        }

        var privateKey = new Ed25519PrivateKeyParameters(seed.ToArray(), 0);
        return new Ed25519KeyPair(privateKey, privateKey.GeneratePublicKey());
    }

    /// <summary>The 32-byte raw private seed (CryptoKit rawRepresentation).</summary>
    public byte[] PrivateKeyRaw => _privateKey.GetEncoded();

    /// <summary>The 32-byte raw public key (CryptoKit rawRepresentation).</summary>
    public byte[] PublicKeyRaw => _publicKey.GetEncoded();

    /// <summary>The 32-byte raw public key, base64-encoded.</summary>
    public string PublicKeyBase64 => Convert.ToBase64String(PublicKeyRaw);

    /// <summary>A signer bound to this key pair's private key.</summary>
    public ICapabilitySigner Signer() => new Ed25519Signer(_privateKey, PublicKeyBase64);

    /// <summary>A verifier bound to this key pair's public key.</summary>
    public ICapabilityVerifier Verifier() => new Ed25519Verifier(_publicKey);
}

/// <summary>Default <see cref="ICapabilitySigner"/> over a raw Ed25519 private key.</summary>
public sealed class Ed25519Signer : ICapabilitySigner
{
    private readonly Ed25519PrivateKeyParameters _privateKey;

    internal Ed25519Signer(Ed25519PrivateKeyParameters privateKey, string publicKeyBase64)
    {
        _privateKey = privateKey;
        PublicKeyBase64 = publicKeyBase64;
    }

    public string PublicKeyBase64 { get; }

    public byte[] Sign(ReadOnlySpan<byte> message)
    {
        var signer = new Org.BouncyCastle.Crypto.Signers.Ed25519Signer();
        signer.Init(forSigning: true, _privateKey);
        var buffer = message.ToArray();
        signer.BlockUpdate(buffer, 0, buffer.Length);
        return signer.GenerateSignature();
    }
}

/// <summary>Default <see cref="ICapabilityVerifier"/> over a raw Ed25519 public key.</summary>
public sealed class Ed25519Verifier : ICapabilityVerifier
{
    private readonly Ed25519PublicKeyParameters _publicKey;

    public Ed25519Verifier(Ed25519PublicKeyParameters publicKey)
    {
        _publicKey = publicKey;
    }

    /// <summary>Builds a verifier from a 32-byte raw public key.</summary>
    public static Ed25519Verifier FromRawPublicKey(ReadOnlySpan<byte> rawPublicKey)
    {
        if (rawPublicKey.Length != Ed25519PublicKeyParameters.KeySize)
        {
            throw new ArgumentException(
                $"Ed25519 public key must be {Ed25519PublicKeyParameters.KeySize} bytes.",
                nameof(rawPublicKey));
        }

        return new Ed25519Verifier(new Ed25519PublicKeyParameters(rawPublicKey.ToArray(), 0));
    }

    /// <summary>Builds a verifier from a base64 raw public key, or null if malformed.</summary>
    public static Ed25519Verifier? FromBase64PublicKey(string publicKeyBase64)
    {
        if (string.IsNullOrEmpty(publicKeyBase64))
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

        if (raw.Length != Ed25519PublicKeyParameters.KeySize)
        {
            return null;
        }

        return new Ed25519Verifier(new Ed25519PublicKeyParameters(raw, 0));
    }

    public bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature)
    {
        if (signature.Length != Ed25519.SignatureSize)
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

/// <summary>Ed25519 sizing constants.</summary>
public static class Ed25519
{
    /// <summary>Detached Ed25519 signatures are 64 bytes.</summary>
    public const int SignatureSize = 64;
}

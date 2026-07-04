// Reference Ed25519 signer for the release pipeline + tests (Phase 5 · signed distribution).
//
// The RELEASE CI holds the private half of WINDOWS_UPDATE_SIGNING_KEY and uses this to sign the
// canonical descriptor of each release offer. It lives beside the verifier ON PURPOSE: signer +
// verifier share UpdateDescriptorCanonicalizer, so the bytes signed here are exactly the bytes
// verified on the client. The round-trip is exercised by `dotnet test` on macOS
// (windows/tests/dist). BouncyCastle Ed25519 == macOS CryptoKit Curve25519.Signing.
//
// This signer never runs inside the shipped app — only in the OpenBurnBar.Dist.UpdateFeed.Tool
// CLI (release CI) and in tests. Key generation here is for tooling/tests; production keys are
// generated offline and stored as the WINDOWS_UPDATE_SIGNING_KEY secret.

using System;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>A raw Ed25519 key pair (32-byte public + 32-byte private seed).</summary>
public sealed class UpdateSigningKeyPair
{
    /// <summary>Wrap raw key bytes.</summary>
    public UpdateSigningKeyPair(byte[] publicKey, byte[] privateKey)
    {
        PublicKey = publicKey;
        PrivateKey = privateKey;
    }

    /// <summary>Raw 32-byte public key (the value pinned into the app).</summary>
    public byte[] PublicKey { get; }

    /// <summary>Raw 32-byte private seed (the WINDOWS_UPDATE_SIGNING_KEY secret).</summary>
    public byte[] PrivateKey { get; }

    /// <summary>Base64 of the public key.</summary>
    public string PublicKeyBase64 => Convert.ToBase64String(PublicKey);

    /// <summary>Base64 of the private seed.</summary>
    public string PrivateKeyBase64 => Convert.ToBase64String(PrivateKey);
}

/// <summary>Signs release descriptors with a raw Ed25519 private seed.</summary>
public sealed class UpdateFeedSigner
{
    private readonly SecureRandom _random = new();

    /// <summary>Generate a fresh raw Ed25519 key pair (tooling/tests only).</summary>
    public UpdateSigningKeyPair GenerateKeyPair()
    {
        var generator = new Ed25519KeyPairGenerator();
        generator.Init(new Ed25519KeyGenerationParameters(_random));
        var pair = generator.GenerateKeyPair();
        var priv = (Ed25519PrivateKeyParameters)pair.Private;
        var pub = (Ed25519PublicKeyParameters)pair.Public;
        return new UpdateSigningKeyPair(pub.GetEncoded(), priv.GetEncoded());
    }

    /// <summary>Derive the raw 32-byte Ed25519 public key from a private seed. Lets the release
    /// pipeline recover the PINNED public key from the WINDOWS_UPDATE_SIGNING_KEY secret alone
    /// (for the feed self-verify + to print the value to pin into the app).</summary>
    public byte[] DerivePublicKey(ReadOnlySpan<byte> privateSeed)
    {
        if (privateSeed.Length != UpdateDescriptorCanonicalizer.PublicKeySize)
        {
            throw new ArgumentException(
                $"Ed25519 private seed must be {UpdateDescriptorCanonicalizer.PublicKeySize} bytes.",
                nameof(privateSeed));
        }

        var parameters = new Ed25519PrivateKeyParameters(privateSeed.ToArray(), 0);
        return parameters.GeneratePublicKey().GetEncoded();
    }

    /// <summary>
    /// Sign the canonical descriptor of <paramref name="entry"/> and return a copy carrying the
    /// base64 Ed25519 signature. Throws on a malformed descriptor (a bad release can never be
    /// signed) or a wrong-length private seed.
    /// </summary>
    public UpdateFeedEntry Sign(UpdateFeedEntry entry, ReadOnlySpan<byte> privateSeed)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (privateSeed.Length != UpdateDescriptorCanonicalizer.PublicKeySize)
        {
            throw new ArgumentException(
                $"Ed25519 private seed must be {UpdateDescriptorCanonicalizer.PublicKeySize} bytes.",
                nameof(privateSeed));
        }

        var payload = UpdateDescriptorCanonicalizer.CanonicalBytes(entry);
        var parameters = new Ed25519PrivateKeyParameters(privateSeed.ToArray(), 0);
        var signer = new Ed25519Signer();
        signer.Init(true, parameters);
        signer.BlockUpdate(payload, 0, payload.Length);
        var signature = signer.GenerateSignature();
        return entry.WithSignature(Convert.ToBase64String(signature));
    }

    /// <summary>Sign with a base64 private seed (the WINDOWS_UPDATE_SIGNING_KEY secret form).</summary>
    public UpdateFeedEntry Sign(UpdateFeedEntry entry, string privateSeedBase64)
    {
        if (string.IsNullOrWhiteSpace(privateSeedBase64))
        {
            throw new ArgumentException("Private seed base64 must be non-empty.", nameof(privateSeedBase64));
        }

        byte[] seed;
        try
        {
            seed = Convert.FromBase64String(privateSeedBase64.Trim());
        }
        catch (FormatException ex)
        {
            throw new ArgumentException("Private seed is not valid base64.", nameof(privateSeedBase64), ex);
        }

        return Sign(entry, seed);
    }
}

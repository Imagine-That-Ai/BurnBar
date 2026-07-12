// Ed25519 signing + verification for CapabilityToken bodies.
//
// Port of CapabilityTokenSigner.swift. Wire layout:
//   signature = Ed25519.sign(privKey, UTF-8(canonicalJSON(bodyWithoutSignature)))

using System;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Capability;

/// <summary>Signs and verifies <see cref="CapabilityToken"/> signatures.</summary>
public sealed class CapabilityTokenSigner
{
    /// <summary>Canonical UTF-8 bytes signed for <paramref name="token"/>.</summary>
    public byte[] CanonicalSignableBytes(CapabilityToken token)
        => CanonicalJson.Encode(token.SignableBody());

    /// <summary>Returns a copy of <paramref name="token"/> carrying a fresh signature.</summary>
    public CapabilityToken Sign(CapabilityToken token, ICapabilitySigner signer)
    {
        var signature = signer.Sign(CanonicalSignableBytes(token));
        return token.WithSignature(Convert.ToBase64String(signature));
    }

    /// <summary>True iff the token's signature verifies against <paramref name="verifier"/>.</summary>
    public bool Verify(CapabilityToken token, ICapabilityVerifier verifier)
    {
        if (string.IsNullOrEmpty(token.SignatureEd25519Base64))
        {
            return false;
        }

        byte[] signature;
        try
        {
            signature = Convert.FromBase64String(token.SignatureEd25519Base64);
        }
        catch (FormatException)
        {
            return false;
        }

        return verifier.Verify(CanonicalSignableBytes(token), signature);
    }
}

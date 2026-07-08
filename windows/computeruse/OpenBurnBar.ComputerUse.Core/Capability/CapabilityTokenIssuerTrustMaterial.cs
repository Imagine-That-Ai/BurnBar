// Published issuer trust for offline bridge verification (public key only).
//
// Port of CapabilityTokenIssuerTrustMaterial.swift. The signing private key
// never leaves the issuer; only this material — the raw Ed25519 public key,
// its key id, and a revocation flag — is published to the leaf.

using System;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Capability;

/// <summary>The published, public-only issuer trust document.</summary>
public sealed class CapabilityTokenIssuerTrustMaterial
{
    public const int CurrentSchemaVersion = 1;

    public CapabilityTokenIssuerTrustMaterial(
        string keyId,
        string publicKeyEd25519Base64,
        bool revoked = false,
        string? publishedAt = null,
        int schemaVersion = CurrentSchemaVersion)
    {
        KeyId = keyId ?? throw new ArgumentNullException(nameof(keyId));
        PublicKeyEd25519Base64 = publicKeyEd25519Base64 ?? throw new ArgumentNullException(nameof(publicKeyEd25519Base64));
        Revoked = revoked;
        PublishedAt = publishedAt ?? CapabilityToken.CanonicalDateString(DateTimeOffset.UtcNow);
        SchemaVersion = schemaVersion;
    }

    public int SchemaVersion { get; }

    public string KeyId { get; }

    public string PublicKeyEd25519Base64 { get; }

    public bool Revoked { get; }

    public string PublishedAt { get; }

    /// <summary>An Ed25519 verifier over the published key, or null if the key is malformed.</summary>
    public ICapabilityVerifier? SigningVerifier() => Ed25519Verifier.FromBase64PublicKey(PublicKeyEd25519Base64);

    /// <summary>Materializes the runtime issuer-trust the leaf verifier consults.</summary>
    public CapabilityTokenIssuerTrust? IssuerTrust()
    {
        var verifier = SigningVerifier();
        return verifier is null ? null : new CapabilityTokenIssuerTrust(verifier, KeyId, Revoked);
    }
}

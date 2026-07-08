// Capability-token model for the input path.
//
// Ported 1:1 from OpenBurnBarComputerUseCore.CapabilityToken. Short-lived, domain-tagged
// capability that a privileged input leaf (the ViGEm virtual-HID sink) requires before
// dispatching a non-bypassable action. The signature is Ed25519 over the canonical
// signable bytes (CapabilityTokenCanonicalizer); the macOS PDP mints these with
// CryptoKit Curve25519.Signing over the identical bytes, so a mac-minted token verifies
// here unchanged.

using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.Pal.Input;

/// <summary>Capability domain. Only <see cref="ComputerUse"/> is used by the input path;
/// <see cref="RemoteUnlock"/> is carried for schema parity with the macOS enum so a
/// cross-domain token is rejected as a domain mismatch rather than silently accepted.</summary>
public enum CapabilityTokenDomain
{
    RemoteUnlock,
    ComputerUse,
}

/// <summary>Wire strings for <see cref="CapabilityTokenDomain"/>, matching the macOS
/// <c>CapabilityToken.Domain</c> raw values ("remote_unlock" / "computer_use").</summary>
public static class CapabilityTokenDomainWire
{
    public static string ToWire(this CapabilityTokenDomain domain) => domain switch
    {
        CapabilityTokenDomain.RemoteUnlock => "remote_unlock",
        CapabilityTokenDomain.ComputerUse => "computer_use",
        _ => throw new ArgumentOutOfRangeException(nameof(domain), domain, "Unknown domain."),
    };

    public static bool TryFromWire(string value, out CapabilityTokenDomain domain)
    {
        switch (value)
        {
            case "remote_unlock": domain = CapabilityTokenDomain.RemoteUnlock; return true;
            case "computer_use": domain = CapabilityTokenDomain.ComputerUse; return true;
            default: domain = default; return false;
        }
    }
}

/// <summary>
/// A short-lived signed capability. Value type; <see cref="AllowedActionKinds"/> is
/// compared by content. Mirrors the macOS record field-for-field including the pinned
/// <see cref="SchemaVersion"/> = 1.
/// </summary>
public sealed class VirtualHidCapabilityToken
{
    public const int CurrentSchemaVersion = 1;

    public VirtualHidCapabilityToken(
        CapabilityTokenDomain domain,
        string nonce,
        DateTimeOffset issuedAt,
        DateTimeOffset expiresAt,
        IReadOnlyList<string> allowedActionKinds,
        string scopeHash,
        int actionBudget,
        string? boundEscrowDeviceId = null,
        string? attestationHashBlake3 = null,
        string? signatureEd25519Base64 = null,
        int schemaVersion = CurrentSchemaVersion)
    {
        Domain = domain;
        Nonce = nonce ?? throw new ArgumentNullException(nameof(nonce));
        IssuedAt = issuedAt;
        ExpiresAt = expiresAt;
        AllowedActionKinds = allowedActionKinds?.ToArray() ?? throw new ArgumentNullException(nameof(allowedActionKinds));
        ScopeHash = scopeHash ?? throw new ArgumentNullException(nameof(scopeHash));
        ActionBudget = actionBudget;
        BoundEscrowDeviceId = boundEscrowDeviceId;
        AttestationHashBlake3 = attestationHashBlake3;
        SignatureEd25519Base64 = signatureEd25519Base64;
        SchemaVersion = schemaVersion;
    }

    public int SchemaVersion { get; }
    public CapabilityTokenDomain Domain { get; }
    public string Nonce { get; }
    public DateTimeOffset IssuedAt { get; }
    public DateTimeOffset ExpiresAt { get; }
    public IReadOnlyList<string> AllowedActionKinds { get; }
    public string ScopeHash { get; }
    public int ActionBudget { get; }
    public string? BoundEscrowDeviceId { get; }
    public string? AttestationHashBlake3 { get; }

    /// <summary>Ed25519 signature over <see cref="CapabilityTokenCanonicalizer"/> bytes,
    /// base64. Null on an unsigned draft; the verifier rejects a null/empty signature.</summary>
    public string? SignatureEd25519Base64 { get; set; }

    public bool IsExpired(DateTimeOffset now) => now >= ExpiresAt;

    /// <summary>Case-insensitive, whitespace-trimmed membership of the action kind in
    /// <see cref="AllowedActionKinds"/> (mirrors macOS <c>allows(actionKind:)</c>).</summary>
    public bool Allows(string actionKind)
    {
        var normalized = (actionKind ?? string.Empty).Trim();
        return AllowedActionKinds.Any(k => string.Equals(k, normalized, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Returns a copy of this token carrying <paramref name="signatureBase64"/>.</summary>
    public VirtualHidCapabilityToken WithSignature(string signatureBase64) => new(
        Domain, Nonce, IssuedAt, ExpiresAt, AllowedActionKinds, ScopeHash, ActionBudget,
        BoundEscrowDeviceId, AttestationHashBlake3, signatureBase64, SchemaVersion);
}

/// <summary>
/// Trust material for the token issuer (the PDP): the raw 32-byte Ed25519 public key,
/// its id, and a revocation flag. Mirrors macOS <c>CapabilityTokenIssuerTrust</c>.
/// </summary>
public sealed class CapabilityTokenIssuerTrust
{
    public CapabilityTokenIssuerTrust(byte[] publicKey, string keyId, bool revoked = false)
    {
        PublicKey = publicKey ?? throw new ArgumentNullException(nameof(publicKey));
        KeyId = keyId ?? throw new ArgumentNullException(nameof(keyId));
        Revoked = revoked;
    }

    /// <summary>Raw 32-byte Ed25519 public key (CryptoKit Curve25519.Signing raw form).</summary>
    public byte[] PublicKey { get; }
    public string KeyId { get; }
    public bool Revoked { get; }
}

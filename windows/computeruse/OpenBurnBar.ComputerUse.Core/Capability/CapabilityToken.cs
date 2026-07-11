// Short-lived, domain-tagged capability for privileged input leaves.
//
// Port of CapabilityToken.swift + CapabilityTokenSigning.SignableBody. The
// signed body is everything except the signature, serialized as canonical JSON
// with ISO-8601 (fractional-second) dates — matching CapabilityTokenSigner's
// encoder so a token minted here verifies here byte-for-byte.

using System;
using System.Collections.Generic;
using System.Globalization;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Capability;

/// <summary>Which privileged-input leaf a token authorizes.</summary>
public enum CapabilityDomain
{
    /// <summary>Single-use token verified offline at the Virtual-HID bridge.</summary>
    RemoteUnlock,

    /// <summary>Token minted in-process by the Computer-Use policy decision point.</summary>
    ComputerUse,
}

/// <summary>Wire encoding for <see cref="CapabilityDomain"/>.</summary>
public static class CapabilityDomainWire
{
    public static string ToWire(this CapabilityDomain domain) => domain switch
    {
        CapabilityDomain.RemoteUnlock => "remote_unlock",
        CapabilityDomain.ComputerUse => "computer_use",
        _ => throw new ArgumentOutOfRangeException(nameof(domain), domain, null),
    };
}

/// <summary>
/// A domain-tagged capability token. Remote-Unlock tokens are single-use;
/// Computer-Use tokens carry an action budget and a bounded TTL.
/// </summary>
public sealed class CapabilityToken
{
    /// <summary>Current schema version. Bumped when the signed field set changes.</summary>
    public const int CurrentSchemaVersion = 1;

    public CapabilityToken(
        CapabilityDomain domain,
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
        SchemaVersion = schemaVersion;
        Domain = domain;
        Nonce = nonce ?? throw new ArgumentNullException(nameof(nonce));
        IssuedAt = issuedAt;
        ExpiresAt = expiresAt;
        AllowedActionKinds = allowedActionKinds ?? throw new ArgumentNullException(nameof(allowedActionKinds));
        ScopeHash = scopeHash ?? throw new ArgumentNullException(nameof(scopeHash));
        ActionBudget = actionBudget;
        BoundEscrowDeviceId = boundEscrowDeviceId;
        AttestationHashBlake3 = attestationHashBlake3;
        SignatureEd25519Base64 = signatureEd25519Base64;
    }

    public int SchemaVersion { get; }

    public CapabilityDomain Domain { get; }

    public string Nonce { get; }

    public DateTimeOffset IssuedAt { get; }

    public DateTimeOffset ExpiresAt { get; }

    public IReadOnlyList<string> AllowedActionKinds { get; }

    public string ScopeHash { get; }

    public int ActionBudget { get; }

    public string? BoundEscrowDeviceId { get; }

    public string? AttestationHashBlake3 { get; }

    /// <summary>Detached Ed25519 signature over the canonical signable body, base64.</summary>
    public string? SignatureEd25519Base64 { get; }

    /// <summary>Returns a copy carrying <paramref name="signature"/> as the base64 signature.</summary>
    public CapabilityToken WithSignature(string signature) => new(
        Domain,
        Nonce,
        IssuedAt,
        ExpiresAt,
        AllowedActionKinds,
        ScopeHash,
        ActionBudget,
        BoundEscrowDeviceId,
        AttestationHashBlake3,
        signature,
        SchemaVersion);

    /// <summary>True once <paramref name="now"/> reaches or passes <see cref="ExpiresAt"/>.</summary>
    public bool IsExpired(DateTimeOffset now) => now >= ExpiresAt;

    /// <summary>Case-insensitive membership test against <see cref="AllowedActionKinds"/>.</summary>
    public bool Allows(string actionKind)
    {
        var normalized = actionKind.Trim();
        foreach (var kind in AllowedActionKinds)
        {
            if (string.Equals(kind, normalized, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>ISO-8601 UTC string with millisecond precision (Swift canonicalDateString).</summary>
    public static string CanonicalDateString(DateTimeOffset date)
        => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    /// <summary>The canonical-JSON signable body: every field except the signature.</summary>
    public CanonicalJsonObject SignableBody()
    {
        var body = new CanonicalJsonObject()
            .Set("schemaVersion", SchemaVersion)
            .Set("domain", Domain.ToWire())
            .Set("nonce", Nonce)
            .Set("issuedAt", CanonicalDateString(IssuedAt))
            .Set("expiresAt", CanonicalDateString(ExpiresAt))
            .Set("allowedActionKinds", AllowedActionKinds)
            .Set("scopeHash", ScopeHash)
            .Set("actionBudget", ActionBudget)
            .Set("boundEscrowDeviceId", BoundEscrowDeviceId)
            .Set("attestationHashBlake3", AttestationHashBlake3);
        return body;
    }
}

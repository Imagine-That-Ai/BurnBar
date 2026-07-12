// Mints short-lived, domain-tagged capability tokens.
//
// Port of CapabilityTokenIssuer.swift.

using System;
using System.Collections.Generic;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Capability;

/// <summary>Issues Remote-Unlock and Computer-Use capability tokens.</summary>
public sealed class CapabilityTokenIssuer
{
    /// <summary>Default Remote-Unlock TTL — 30 s.</summary>
    public static readonly TimeSpan RemoteUnlockDefaultTtl = TimeSpan.FromSeconds(30);

    /// <summary>Default Computer-Use TTL — 120 s.</summary>
    public static readonly TimeSpan ComputerUseDefaultTtl = TimeSpan.FromSeconds(120);

    /// <summary>The fixed Remote-Unlock action-kind allowlist.</summary>
    public static readonly IReadOnlyList<string> RemoteUnlockAllowedActionKinds = new[]
    {
        "click",
        "pointer_move",
        "key",
        "shortcut",
        "type_credential",
    };

    private readonly CapabilityTokenSigner _signer = new();

    /// <summary>
    /// Mints a single-use Remote-Unlock token (action budget 1). When
    /// <paramref name="actionKind"/> is one of the allowlisted kinds the token
    /// is scoped to that kind; otherwise it carries the full allowlist.
    /// </summary>
    public CapabilityToken MintRemoteUnlockToken(
        ICapabilitySigner signer,
        string scopeHash,
        string actionKind,
        DateTimeOffset now,
        string? boundEscrowDeviceId = null,
        string? attestationHashBlake3 = null,
        TimeSpan? ttl = null,
        string? nonce = null)
    {
        var allowed = RemoteUnlockContains(actionKind)
            ? new[] { actionKind }
            : RemoteUnlockAllowedActionKinds;
        var token = new CapabilityToken(
            domain: CapabilityDomain.RemoteUnlock,
            nonce: nonce ?? NewNonce(),
            issuedAt: now,
            expiresAt: now + (ttl ?? RemoteUnlockDefaultTtl),
            allowedActionKinds: allowed,
            scopeHash: scopeHash,
            actionBudget: 1,
            boundEscrowDeviceId: boundEscrowDeviceId,
            attestationHashBlake3: attestationHashBlake3);
        return _signer.Sign(token, signer);
    }

    /// <summary>Mints a Computer-Use token with an explicit action budget (clamped ≥ 1).</summary>
    public CapabilityToken MintComputerUseToken(
        ICapabilitySigner signer,
        string scopeHash,
        IReadOnlyList<string> allowedActionKinds,
        int actionBudget,
        DateTimeOffset now,
        string? attestationHashBlake3 = null,
        string? boundEscrowDeviceId = null,
        TimeSpan? ttl = null,
        string? nonce = null)
    {
        var token = new CapabilityToken(
            domain: CapabilityDomain.ComputerUse,
            nonce: nonce ?? NewNonce(),
            issuedAt: now,
            expiresAt: now + (ttl ?? ComputerUseDefaultTtl),
            allowedActionKinds: allowedActionKinds,
            scopeHash: scopeHash,
            actionBudget: Math.Max(1, actionBudget),
            boundEscrowDeviceId: boundEscrowDeviceId,
            attestationHashBlake3: attestationHashBlake3);
        return _signer.Sign(token, signer);
    }

    private static bool RemoteUnlockContains(string actionKind)
    {
        foreach (var kind in RemoteUnlockAllowedActionKinds)
        {
            if (string.Equals(kind, actionKind, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    private static string NewNonce() => Guid.NewGuid().ToString("D").ToLowerInvariant();
}

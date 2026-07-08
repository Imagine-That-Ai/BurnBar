// Terminal audit-chain head with an Ed25519 signature for offline verification.
//
// Port of ComputerUseAuditSignedHead.swift + ComputerUseAuditHeadFinalizer.swift.
// The signed head anchors the LAST entry so a truncation of the final entry
// cannot pass a parent-chain walk, and its signature proves the chain was closed
// by the holder of the export signing key.

using System;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Audit;

/// <summary>An Ed25519-signed terminal audit-chain head.</summary>
public sealed class ComputerUseAuditSignedHead
{
    public const int CurrentSchemaVersion = 1;

    public ComputerUseAuditSignedHead(
        string sessionId,
        int lastEntryIndex,
        string headHashHex,
        DateTimeOffset closedAt,
        string signatureEd25519Base64,
        string signerPublicKeyEd25519Base64,
        int schemaVersion = CurrentSchemaVersion)
    {
        SchemaVersion = schemaVersion;
        SessionId = sessionId;
        LastEntryIndex = lastEntryIndex;
        HeadHashHex = headHashHex;
        ClosedAt = closedAt;
        SignatureEd25519Base64 = signatureEd25519Base64;
        SignerPublicKeyEd25519Base64 = signerPublicKeyEd25519Base64;
    }

    public int SchemaVersion { get; }

    public string SessionId { get; }

    public int LastEntryIndex { get; }

    public string HeadHashHex { get; }

    public DateTimeOffset ClosedAt { get; }

    public string SignatureEd25519Base64 { get; }

    public string SignerPublicKeyEd25519Base64 { get; }

    /// <summary>Canonical payload bytes signed by the audit exporter.</summary>
    public byte[] SigningPayload()
    {
        var map = new CanonicalJsonObject()
            .Set("sessionId", SessionId)
            .Set("lastEntryIndex", LastEntryIndex)
            .Set("headHashHex", HeadHashHex)
            .Set("closedAtMs", ClosedAt.ToUnixTimeMilliseconds());
        return CanonicalJson.Encode(map);
    }

    /// <summary>True iff the embedded signature verifies against the embedded public key.</summary>
    public bool VerifySignature()
    {
        var verifier = Ed25519Verifier.FromBase64PublicKey(SignerPublicKeyEd25519Base64);
        if (verifier is null)
        {
            return false;
        }

        byte[] signature;
        try
        {
            signature = Convert.FromBase64String(SignatureEd25519Base64);
        }
        catch (FormatException)
        {
            return false;
        }

        return verifier.Verify(SigningPayload(), signature);
    }

    /// <summary>Signs a terminal head with <paramref name="signer"/>.</summary>
    public static ComputerUseAuditSignedHead Sign(
        string sessionId,
        int lastEntryIndex,
        string headHashHex,
        DateTimeOffset closedAt,
        ICapabilitySigner signer)
    {
        var draft = new ComputerUseAuditSignedHead(
            sessionId,
            lastEntryIndex,
            headHashHex,
            closedAt,
            signatureEd25519Base64: string.Empty,
            signerPublicKeyEd25519Base64: signer.PublicKeyBase64);
        var signature = signer.Sign(draft.SigningPayload());
        return new ComputerUseAuditSignedHead(
            sessionId,
            lastEntryIndex,
            headHashHex,
            closedAt,
            signatureEd25519Base64: Convert.ToBase64String(signature),
            signerPublicKeyEd25519Base64: signer.PublicKeyBase64);
    }
}

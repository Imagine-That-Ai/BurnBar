// Offline capability-token leaf verifier.
//
// Ported 1:1 (order + semantics) from OpenBurnBarComputerUseCore.CapabilityTokenLeafVerifier:
//   present → domain → TTL → signature-present → issuer-trust → not-revoked → signature →
//   scope binding → attestation binding → escrow-device binding → action ∈ allowed →
//   budget > 0 → nonce-unseen → consume.
// The harshest failure wins (early return). Pure decision + the single nonce-consume side
// effect. Fail-closed: a missing token, missing/invalid signature, or unavailable issuer
// key all reject.

using System;

namespace OpenBurnBar.Pal.Input;

/// <summary>The verdict for one capability-token verification. Exactly one value per call;
/// only <see cref="Accepted"/> authorizes dispatch. Names mirror the macOS
/// <c>CapabilityTokenVerificationFailure</c> cases.</summary>
public enum CapabilityTokenVerification
{
    Accepted,
    MissingToken,
    MissingSignature,
    SignatureInvalid,
    Expired,
    DomainMismatch,
    NonceReplay,
    ActionNotAllowed,
    ActionBudgetExhausted,
    ScopeMismatch,
    AttestationMismatch,
    EscrowDeviceMismatch,
    IssuerKeyUnavailable,
    IssuerRevoked,
}

/// <summary>Inputs to one verification. The three binding fields are normalized to null
/// when blank so a whitespace value never masquerades as a binding.</summary>
public sealed class CapabilityTokenVerifyRequest
{
    public CapabilityTokenVerifyRequest(
        VirtualHidCapabilityToken? token,
        CapabilityTokenDomain expectedDomain,
        string actionKind,
        string? requiredScopeHash = null,
        string? requiredAttestationHashBlake3 = null,
        string? boundEscrowDeviceId = null)
    {
        Token = token;
        ExpectedDomain = expectedDomain;
        ActionKind = actionKind ?? throw new ArgumentNullException(nameof(actionKind));
        RequiredScopeHash = NormalizeBinding(requiredScopeHash);
        RequiredAttestationHashBlake3 = NormalizeBinding(requiredAttestationHashBlake3);
        BoundEscrowDeviceId = NormalizeBinding(boundEscrowDeviceId);
    }

    public VirtualHidCapabilityToken? Token { get; }
    public CapabilityTokenDomain ExpectedDomain { get; }
    public string ActionKind { get; }
    public string? RequiredScopeHash { get; }
    public string? RequiredAttestationHashBlake3 { get; }
    public string? BoundEscrowDeviceId { get; }

    private static string? NormalizeBinding(string? value)
    {
        if (value is null)
        {
            return null;
        }
        var trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }
}

/// <summary>Offline leaf verifier: signature + TTL + nonce-unseen + action ∈ allowed
/// (+ scope / attestation / escrow binding). Consumes the nonce on acceptance.</summary>
public sealed class VirtualHidCapabilityTokenVerifier
{
    private readonly ICapabilityTokenNonceStore _nonceStore;
    private readonly Func<CapabilityTokenIssuerTrust?> _issuerTrustProvider;
    private readonly ICapabilityTokenSignatureVerifier _signatureVerifier;

    public VirtualHidCapabilityTokenVerifier(
        ICapabilityTokenNonceStore nonceStore,
        Func<CapabilityTokenIssuerTrust?> issuerTrustProvider,
        ICapabilityTokenSignatureVerifier? signatureVerifier = null)
    {
        _nonceStore = nonceStore ?? throw new ArgumentNullException(nameof(nonceStore));
        _issuerTrustProvider = issuerTrustProvider ?? throw new ArgumentNullException(nameof(issuerTrustProvider));
        _signatureVerifier = signatureVerifier ?? new Ed25519CapabilityTokenSignatureVerifier();
    }

    public CapabilityTokenVerification Verify(CapabilityTokenVerifyRequest request, DateTimeOffset now)
    {
        if (request is null)
        {
            throw new ArgumentNullException(nameof(request));
        }

        var token = request.Token;
        if (token is null)
        {
            return CapabilityTokenVerification.MissingToken;
        }
        if (token.Domain != request.ExpectedDomain)
        {
            return CapabilityTokenVerification.DomainMismatch;
        }
        if (token.IsExpired(now))
        {
            return CapabilityTokenVerification.Expired;
        }
        if (string.IsNullOrEmpty(token.SignatureEd25519Base64))
        {
            return CapabilityTokenVerification.MissingSignature;
        }

        var trust = _issuerTrustProvider();
        if (trust is null)
        {
            return CapabilityTokenVerification.IssuerKeyUnavailable;
        }
        if (trust.Revoked)
        {
            return CapabilityTokenVerification.IssuerRevoked;
        }

        if (!TryVerifySignature(token, trust.PublicKey))
        {
            return CapabilityTokenVerification.SignatureInvalid;
        }

        if (request.RequiredScopeHash is not null && token.ScopeHash != request.RequiredScopeHash)
        {
            return CapabilityTokenVerification.ScopeMismatch;
        }

        // Attestation binding, enforced without self-matching: a bound token requires the
        // caller to supply the expected binding from a trusted presenter context.
        var tokenAttestation = token.AttestationHashBlake3;
        if (request.RequiredAttestationHashBlake3 is not null || tokenAttestation is not null)
        {
            if (request.RequiredAttestationHashBlake3 is null
                || tokenAttestation is null
                || tokenAttestation != request.RequiredAttestationHashBlake3)
            {
                return CapabilityTokenVerification.AttestationMismatch;
            }
        }

        // Escrow-device binding follows the same rule.
        var tokenDevice = token.BoundEscrowDeviceId;
        if (request.BoundEscrowDeviceId is not null || tokenDevice is not null)
        {
            if (request.BoundEscrowDeviceId is null
                || tokenDevice is null
                || tokenDevice != request.BoundEscrowDeviceId)
            {
                return CapabilityTokenVerification.EscrowDeviceMismatch;
            }
        }

        var normalizedKind = request.ActionKind.Trim();
        if (!token.Allows(normalizedKind))
        {
            return CapabilityTokenVerification.ActionNotAllowed;
        }
        if (token.ActionBudget <= 0)
        {
            return CapabilityTokenVerification.ActionBudgetExhausted;
        }
        if (_nonceStore.HasConsumed(token.Nonce, token.Domain))
        {
            return CapabilityTokenVerification.NonceReplay;
        }

        try
        {
            _nonceStore.Consume(token.Nonce, token.Domain);
        }
        catch (CapabilityTokenNonceReplayException)
        {
            return CapabilityTokenVerification.NonceReplay;
        }

        return CapabilityTokenVerification.Accepted;
    }

    private bool TryVerifySignature(VirtualHidCapabilityToken token, byte[] publicKey)
    {
        byte[] signature;
        try
        {
            signature = Convert.FromBase64String(token.SignatureEd25519Base64!);
        }
        catch (FormatException)
        {
            return false;
        }

        var message = CapabilityTokenCanonicalizer.CanonicalBytes(token);
        return _signatureVerifier.Verify(message, signature, publicKey);
    }
}

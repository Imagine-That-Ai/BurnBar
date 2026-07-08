// Offline leaf verifier for capability tokens.
//
// Port of CapabilityTokenVerifier.swift. Verifies, in the SAME order as the
// Swift core so the harshest failure wins:
//   missingToken -> domainMismatch -> expired -> missingSignature ->
//   issuerKeyUnavailable -> issuerRevoked -> signatureInvalid -> scopeMismatch ->
//   attestation binding (no self-matching) -> escrow-device binding ->
//   actionNotAllowed -> actionBudgetExhausted -> nonceReplay (check then consume).

using System;
using System.Collections.Generic;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Capability;

/// <summary>Why a capability-token verification failed. Wire strings match the Swift core.</summary>
public enum CapabilityTokenVerificationFailure
{
    None = 0,
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

/// <summary>Stable wire strings for <see cref="CapabilityTokenVerificationFailure"/>.</summary>
public static class CapabilityTokenVerificationFailureWire
{
    public static string ToWire(this CapabilityTokenVerificationFailure failure) => failure switch
    {
        CapabilityTokenVerificationFailure.MissingToken => "capability_token_missing",
        CapabilityTokenVerificationFailure.MissingSignature => "capability_token_missing_signature",
        CapabilityTokenVerificationFailure.SignatureInvalid => "capability_token_signature_invalid",
        CapabilityTokenVerificationFailure.Expired => "capability_token_expired",
        CapabilityTokenVerificationFailure.DomainMismatch => "capability_token_domain_mismatch",
        CapabilityTokenVerificationFailure.NonceReplay => "capability_token_nonce_replay",
        CapabilityTokenVerificationFailure.ActionNotAllowed => "capability_token_action_not_allowed",
        CapabilityTokenVerificationFailure.ActionBudgetExhausted => "capability_token_action_budget_exhausted",
        CapabilityTokenVerificationFailure.ScopeMismatch => "capability_token_scope_mismatch",
        CapabilityTokenVerificationFailure.AttestationMismatch => "capability_token_attestation_mismatch",
        CapabilityTokenVerificationFailure.EscrowDeviceMismatch => "capability_token_escrow_device_mismatch",
        CapabilityTokenVerificationFailure.IssuerKeyUnavailable => "capability_token_issuer_key_unavailable",
        CapabilityTokenVerificationFailure.IssuerRevoked => "capability_token_issuer_revoked",
        CapabilityTokenVerificationFailure.None => "none",
        _ => throw new ArgumentOutOfRangeException(nameof(failure), failure, null),
    };
}

/// <summary>Tracks consumed single-use nonces for offline leaf verification.</summary>
public interface ICapabilityTokenNonceStore
{
    /// <summary>True iff (<paramref name="nonce"/>, <paramref name="domain"/>) was consumed.</summary>
    bool HasConsumed(string nonce, CapabilityDomain domain);

    /// <summary>Marks (<paramref name="nonce"/>, <paramref name="domain"/>) consumed;
    /// throws <see cref="CapabilityTokenReplayException"/> if already consumed.</summary>
    void Consume(string nonce, CapabilityDomain domain);
}

/// <summary>Thrown when a nonce is consumed twice.</summary>
public sealed class CapabilityTokenReplayException : Exception
{
    public CapabilityTokenReplayException()
        : base("Capability-token nonce replay.")
    {
    }
}

/// <summary>In-memory nonce store for tests and ephemeral coordinators.</summary>
public sealed class InMemoryCapabilityTokenNonceStore : ICapabilityTokenNonceStore
{
    private readonly HashSet<string> _consumed = new(StringComparer.Ordinal);
    private readonly object _gate = new();

    public bool HasConsumed(string nonce, CapabilityDomain domain)
    {
        lock (_gate)
        {
            return _consumed.Contains(Key(nonce, domain));
        }
    }

    public void Consume(string nonce, CapabilityDomain domain)
    {
        lock (_gate)
        {
            if (!_consumed.Add(Key(nonce, domain)))
            {
                throw new CapabilityTokenReplayException();
            }
        }
    }

    private static string Key(string nonce, CapabilityDomain domain) => $"{domain.ToWire()}:{nonce}";
}

/// <summary>Published issuer trust: the pinned public key + revocation flag.</summary>
public sealed class CapabilityTokenIssuerTrust
{
    public CapabilityTokenIssuerTrust(ICapabilityVerifier verifier, string keyId, bool revoked = false)
    {
        Verifier = verifier ?? throw new ArgumentNullException(nameof(verifier));
        KeyId = keyId ?? throw new ArgumentNullException(nameof(keyId));
        Revoked = revoked;
    }

    public ICapabilityVerifier Verifier { get; }

    public string KeyId { get; }

    public bool Revoked { get; }
}

/// <summary>A verification request: the token plus the bindings the presenter asserts.</summary>
public sealed class CapabilityTokenVerificationRequest
{
    public CapabilityTokenVerificationRequest(
        CapabilityToken? token,
        CapabilityDomain expectedDomain,
        string actionKind,
        string? requiredScopeHash = null,
        string? requiredAttestationHashBlake3 = null,
        string? boundEscrowDeviceId = null)
    {
        Token = token;
        ExpectedDomain = expectedDomain;
        ActionKind = actionKind ?? throw new ArgumentNullException(nameof(actionKind));
        RequiredScopeHash = Normalize(requiredScopeHash);
        RequiredAttestationHashBlake3 = Normalize(requiredAttestationHashBlake3);
        BoundEscrowDeviceId = Normalize(boundEscrowDeviceId);
    }

    public CapabilityToken? Token { get; }

    public CapabilityDomain ExpectedDomain { get; }

    public string ActionKind { get; }

    public string? RequiredScopeHash { get; }

    public string? RequiredAttestationHashBlake3 { get; }

    public string? BoundEscrowDeviceId { get; }

    private static string? Normalize(string? value)
    {
        if (value is null)
        {
            return null;
        }

        var trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }
}

/// <summary>The verdict of a leaf verification: success, or the harshest failure.</summary>
public readonly struct CapabilityTokenVerificationResult
{
    private CapabilityTokenVerificationResult(bool ok, CapabilityTokenVerificationFailure failure)
    {
        IsSuccess = ok;
        Failure = failure;
    }

    public bool IsSuccess { get; }

    public CapabilityTokenVerificationFailure Failure { get; }

    public static CapabilityTokenVerificationResult Success { get; } =
        new(true, CapabilityTokenVerificationFailure.None);

    public static CapabilityTokenVerificationResult Fail(CapabilityTokenVerificationFailure failure)
        => new(false, failure);
}

/// <summary>
/// Offline leaf verifier: signature + TTL + domain + scope/attestation/escrow
/// bindings + action-allowed + budget + single-use nonce. Attestation and
/// escrow bindings never self-match: if the token is bound, the presenter must
/// supply the expected binding from a trusted context.
/// </summary>
public sealed class CapabilityTokenLeafVerifier
{
    private readonly CapabilityTokenSigner _signer = new();
    private readonly ICapabilityTokenNonceStore _nonceStore;
    private readonly Func<CapabilityTokenIssuerTrust?> _issuerTrustProvider;

    public CapabilityTokenLeafVerifier(
        ICapabilityTokenNonceStore nonceStore,
        Func<CapabilityTokenIssuerTrust?> issuerTrustProvider)
    {
        _nonceStore = nonceStore ?? throw new ArgumentNullException(nameof(nonceStore));
        _issuerTrustProvider = issuerTrustProvider ?? throw new ArgumentNullException(nameof(issuerTrustProvider));
    }

    public CapabilityTokenVerificationResult Verify(
        CapabilityTokenVerificationRequest request,
        DateTimeOffset now)
    {
        var token = request.Token;
        if (token is null)
        {
            return Fail(CapabilityTokenVerificationFailure.MissingToken);
        }

        if (token.Domain != request.ExpectedDomain)
        {
            return Fail(CapabilityTokenVerificationFailure.DomainMismatch);
        }

        if (token.IsExpired(now))
        {
            return Fail(CapabilityTokenVerificationFailure.Expired);
        }

        if (string.IsNullOrEmpty(token.SignatureEd25519Base64))
        {
            return Fail(CapabilityTokenVerificationFailure.MissingSignature);
        }

        var trust = _issuerTrustProvider();
        if (trust is null)
        {
            return Fail(CapabilityTokenVerificationFailure.IssuerKeyUnavailable);
        }

        if (trust.Revoked)
        {
            return Fail(CapabilityTokenVerificationFailure.IssuerRevoked);
        }

        if (!_signer.Verify(token, trust.Verifier))
        {
            return Fail(CapabilityTokenVerificationFailure.SignatureInvalid);
        }

        if (request.RequiredScopeHash is not null && token.ScopeHash != request.RequiredScopeHash)
        {
            return Fail(CapabilityTokenVerificationFailure.ScopeMismatch);
        }

        // Attestation binding without self-matching: if either side is bound,
        // both must be present and equal.
        var tokenAttestation = token.AttestationHashBlake3;
        if (request.RequiredAttestationHashBlake3 is not null || tokenAttestation is not null)
        {
            if (request.RequiredAttestationHashBlake3 is null
                || tokenAttestation is null
                || tokenAttestation != request.RequiredAttestationHashBlake3)
            {
                return Fail(CapabilityTokenVerificationFailure.AttestationMismatch);
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
                return Fail(CapabilityTokenVerificationFailure.EscrowDeviceMismatch);
            }
        }

        var normalizedKind = request.ActionKind.Trim();
        if (!token.Allows(normalizedKind))
        {
            return Fail(CapabilityTokenVerificationFailure.ActionNotAllowed);
        }

        if (token.ActionBudget <= 0)
        {
            return Fail(CapabilityTokenVerificationFailure.ActionBudgetExhausted);
        }

        if (_nonceStore.HasConsumed(token.Nonce, token.Domain))
        {
            return Fail(CapabilityTokenVerificationFailure.NonceReplay);
        }

        try
        {
            _nonceStore.Consume(token.Nonce, token.Domain);
        }
        catch (CapabilityTokenReplayException)
        {
            return Fail(CapabilityTokenVerificationFailure.NonceReplay);
        }

        return CapabilityTokenVerificationResult.Success;
    }

    private static CapabilityTokenVerificationResult Fail(CapabilityTokenVerificationFailure failure)
        => CapabilityTokenVerificationResult.Fail(failure);
}

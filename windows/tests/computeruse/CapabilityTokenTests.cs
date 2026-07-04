using System;
using System.IO;
using OpenBurnBar.ComputerUse.Core.Capability;
using OpenBurnBar.ComputerUse.Core.Crypto;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class CapabilityTokenTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);

    private static (CapabilityTokenLeafVerifier verifier, ICapabilityTokenNonceStore store, Ed25519KeyPair issuer)
        BuildVerifier(bool revoked = false, bool trustNull = false)
    {
        var issuer = Ed25519KeyPair.Generate();
        var store = new InMemoryCapabilityTokenNonceStore();
        var verifier = new CapabilityTokenLeafVerifier(
            store,
            () => trustNull
                ? null
                : new CapabilityTokenIssuerTrust(issuer.Verifier(), keyId: "k1", revoked: revoked));
        return (verifier, store, issuer);
    }

    private static CapabilityToken MintComputerUse(
        Ed25519KeyPair issuer,
        string[] kinds,
        int budget = 5,
        string scope = "scope-1",
        string? attestation = null,
        string? escrow = null,
        TimeSpan? ttl = null)
    {
        return new CapabilityTokenIssuer().MintComputerUseToken(
            issuer.Signer(),
            scopeHash: scope,
            allowedActionKinds: kinds,
            actionBudget: budget,
            now: Now,
            attestationHashBlake3: attestation,
            boundEscrowDeviceId: escrow,
            ttl: ttl);
    }

    [Fact]
    public void IssueThenVerifySucceeds_ThenReplayIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var token = MintComputerUse(issuer, new[] { "click" });

        var request = new CapabilityTokenVerificationRequest(
            token, CapabilityDomain.ComputerUse, actionKind: "click", requiredScopeHash: "scope-1");

        var first = verifier.Verify(request, Now);
        Assert.True(first.IsSuccess);

        // The SAME token / nonce presented a second time is a replay.
        var second = verifier.Verify(request, Now);
        Assert.False(second.IsSuccess);
        Assert.Equal(CapabilityTokenVerificationFailure.NonceReplay, second.Failure);
    }

    [Fact]
    public void ExpiredTokenIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var token = MintComputerUse(issuer, new[] { "click" }, ttl: TimeSpan.FromSeconds(10));

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(token, CapabilityDomain.ComputerUse, "click"),
            Now.AddSeconds(11));

        Assert.Equal(CapabilityTokenVerificationFailure.Expired, result.Failure);
    }

    [Fact]
    public void DomainMismatchIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var token = MintComputerUse(issuer, new[] { "click" });

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(token, CapabilityDomain.RemoteUnlock, "click"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.DomainMismatch, result.Failure);
    }

    [Fact]
    public void MissingTokenIsRejected()
    {
        var (verifier, _, _) = BuildVerifier();
        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(null, CapabilityDomain.ComputerUse, "click"),
            Now);
        Assert.Equal(CapabilityTokenVerificationFailure.MissingToken, result.Failure);
    }

    [Fact]
    public void TamperedBodyFailsSignatureVerification()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var token = MintComputerUse(issuer, new[] { "click" }, scope: "scope-1");

        // Re-home the valid signature onto a token whose scopeHash was changed.
        var tampered = new CapabilityToken(
            token.Domain, token.Nonce, token.IssuedAt, token.ExpiresAt, token.AllowedActionKinds,
            scopeHash: "scope-ELEVATED", actionBudget: token.ActionBudget,
            boundEscrowDeviceId: token.BoundEscrowDeviceId, attestationHashBlake3: token.AttestationHashBlake3,
            signatureEd25519Base64: token.SignatureEd25519Base64);

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(tampered, CapabilityDomain.ComputerUse, "click"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.SignatureInvalid, result.Failure);
    }

    [Fact]
    public void MissingSignatureIsRejected()
    {
        var (verifier, _, _) = BuildVerifier();
        var unsigned = new CapabilityToken(
            CapabilityDomain.ComputerUse, "nonce-x", Now, Now.AddSeconds(60),
            new[] { "click" }, "scope-1", actionBudget: 3);

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(unsigned, CapabilityDomain.ComputerUse, "click"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.MissingSignature, result.Failure);
    }

    [Fact]
    public void ScopeMismatchIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var token = MintComputerUse(issuer, new[] { "click" }, scope: "scope-1");

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(
                token, CapabilityDomain.ComputerUse, "click", requiredScopeHash: "scope-OTHER"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.ScopeMismatch, result.Failure);
    }

    [Fact]
    public void AttestationBinding_MatchingSucceeds_MismatchAndSelfMatchRejected()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var bound = MintComputerUse(issuer, new[] { "click" }, attestation: "att-A");

        // Matching binding from the presenter succeeds.
        Assert.True(verifier.Verify(
            new CapabilityTokenVerificationRequest(
                bound, CapabilityDomain.ComputerUse, "click", requiredScopeHash: "scope-1",
                requiredAttestationHashBlake3: "att-A"),
            Now).IsSuccess);

        // A bound token cannot satisfy itself when the presenter omits the binding.
        var (verifier2, _, issuer2) = BuildVerifier();
        var bound2 = MintComputerUse(issuer2, new[] { "click" }, attestation: "att-A");
        Assert.Equal(
            CapabilityTokenVerificationFailure.AttestationMismatch,
            verifier2.Verify(
                new CapabilityTokenVerificationRequest(bound2, CapabilityDomain.ComputerUse, "click"),
                Now).Failure);

        // Divergent bindings are rejected.
        var (verifier3, _, issuer3) = BuildVerifier();
        var bound3 = MintComputerUse(issuer3, new[] { "click" }, attestation: "att-A");
        Assert.Equal(
            CapabilityTokenVerificationFailure.AttestationMismatch,
            verifier3.Verify(
                new CapabilityTokenVerificationRequest(
                    bound3, CapabilityDomain.ComputerUse, "click", requiredAttestationHashBlake3: "att-B"),
                Now).Failure);
    }

    [Fact]
    public void UnboundTokenWithRequiredAttestationIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var unbound = MintComputerUse(issuer, new[] { "click" });

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(
                unbound, CapabilityDomain.ComputerUse, "click", requiredAttestationHashBlake3: "att-A"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.AttestationMismatch, result.Failure);
    }

    [Fact]
    public void EscrowDeviceBindingMismatchIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var bound = MintComputerUse(issuer, new[] { "click" }, escrow: "device-1");

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(
                bound, CapabilityDomain.ComputerUse, "click", boundEscrowDeviceId: "device-2"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.EscrowDeviceMismatch, result.Failure);
    }

    [Fact]
    public void ActionNotAllowedIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var token = MintComputerUse(issuer, new[] { "click" });

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(token, CapabilityDomain.ComputerUse, "type"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.ActionNotAllowed, result.Failure);
    }

    [Fact]
    public void ZeroBudgetIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier();
        var zeroBudget = new CapabilityTokenSigner().Sign(
            new CapabilityToken(
                CapabilityDomain.ComputerUse, "nonce-zero", Now, Now.AddSeconds(60),
                new[] { "click" }, "scope-1", actionBudget: 0),
            issuer.Signer());

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(zeroBudget, CapabilityDomain.ComputerUse, "click"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.ActionBudgetExhausted, result.Failure);
    }

    [Fact]
    public void RevokedIssuerIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier(revoked: true);
        var token = MintComputerUse(issuer, new[] { "click" });

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(token, CapabilityDomain.ComputerUse, "click"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.IssuerRevoked, result.Failure);
    }

    [Fact]
    public void AbsentIssuerTrustIsRejected()
    {
        var (verifier, _, issuer) = BuildVerifier(trustNull: true);
        var token = MintComputerUse(issuer, new[] { "click" });

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(token, CapabilityDomain.ComputerUse, "click"),
            Now);

        Assert.Equal(CapabilityTokenVerificationFailure.IssuerKeyUnavailable, result.Failure);
    }

    [Fact]
    public void ExpiryIsCheckedBeforeSignature()
    {
        // An expired AND tampered token reports expiry — the harsher-earlier ordering.
        var (verifier, _, issuer) = BuildVerifier();
        var token = MintComputerUse(issuer, new[] { "click" }, ttl: TimeSpan.FromSeconds(5));
        var tampered = new CapabilityToken(
            token.Domain, token.Nonce, token.IssuedAt, token.ExpiresAt, token.AllowedActionKinds,
            "scope-ELEVATED", token.ActionBudget, signatureEd25519Base64: token.SignatureEd25519Base64);

        var result = verifier.Verify(
            new CapabilityTokenVerificationRequest(tampered, CapabilityDomain.ComputerUse, "click"),
            Now.AddSeconds(6));

        Assert.Equal(CapabilityTokenVerificationFailure.Expired, result.Failure);
    }

    [Fact]
    public void RemoteUnlockTokenIsSingleUse()
    {
        var issuer = Ed25519KeyPair.Generate();
        var store = new InMemoryCapabilityTokenNonceStore();
        var verifier = new CapabilityTokenLeafVerifier(
            store, () => new CapabilityTokenIssuerTrust(issuer.Verifier(), "k1"));

        var token = new CapabilityTokenIssuer().MintRemoteUnlockToken(
            issuer.Signer(), scopeHash: "unlock", actionKind: "type_credential", now: Now);

        var request = new CapabilityTokenVerificationRequest(
            token, CapabilityDomain.RemoteUnlock, "type_credential");

        Assert.True(verifier.Verify(request, Now).IsSuccess);
        Assert.Equal(CapabilityTokenVerificationFailure.NonceReplay, verifier.Verify(request, Now).Failure);
    }

    [Fact]
    public void NonceStoreSeparatesDomains()
    {
        var store = new InMemoryCapabilityTokenNonceStore();
        store.Consume("shared-nonce", CapabilityDomain.ComputerUse);

        Assert.True(store.HasConsumed("shared-nonce", CapabilityDomain.ComputerUse));
        Assert.False(store.HasConsumed("shared-nonce", CapabilityDomain.RemoteUnlock));
    }

    [Fact]
    public void FileNonceLedgerRejectsReplayAcrossInstances()
    {
        var path = Path.Combine(Path.GetTempPath(), "cu-nonce-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var first = new FileCapabilityTokenNonceStore(path);
            first.Consume("n-1", CapabilityDomain.ComputerUse);

            // A fresh instance reading the SAME ledger sees the nonce consumed.
            var second = new FileCapabilityTokenNonceStore(path);
            Assert.True(second.HasConsumed("n-1", CapabilityDomain.ComputerUse));
            Assert.Throws<CapabilityTokenReplayException>(
                () => second.Consume("n-1", CapabilityDomain.ComputerUse));
        }
        finally
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    [Fact]
    public void IssuerTrustMaterialMaterializesVerifierFromPublicKey()
    {
        var issuer = Ed25519KeyPair.Generate();
        var material = new CapabilityTokenIssuerTrustMaterial("k1", issuer.PublicKeyBase64);
        var trust = material.IssuerTrust();

        Assert.NotNull(trust);
        Assert.Equal("k1", trust!.KeyId);

        var token = MintComputerUse(issuer, new[] { "click" });
        var verifier = new CapabilityTokenLeafVerifier(
            new InMemoryCapabilityTokenNonceStore(), () => trust);
        Assert.True(verifier.Verify(
            new CapabilityTokenVerificationRequest(token, CapabilityDomain.ComputerUse, "click"),
            Now).IsSuccess);
    }
}

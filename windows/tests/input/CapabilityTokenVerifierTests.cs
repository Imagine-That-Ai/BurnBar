// Capability-token leaf verifier, exercised with REAL Ed25519 (BouncyCastle) over the real
// canonical bytes. Proves every verdict of the ported state machine, including cryptographic
// tamper detection (a mutated token or a mutated signature fails to verify) and single-use
// nonce replay rejection.

using System;
using System.Collections.Generic;
using OpenBurnBar.Pal.Input;
using Xunit;

namespace OpenBurnBar.Pal.Input.Tests;

public sealed class CapabilityTokenVerifierTests
{
    private static readonly DateTimeOffset Now = InputTestClock.Now;
    private static readonly string[] ClickOnly = { "mac.input.click" };

    private static VirtualHidCapabilityTokenVerifier Verifier(
        TestIssuer issuer,
        ICapabilityTokenNonceStore? nonceStore = null)
    {
        return new VirtualHidCapabilityTokenVerifier(
            nonceStore ?? new InMemoryCapabilityTokenNonceStore(),
            () => issuer.Trust);
    }

    private static CapabilityTokenVerifyRequest Req(
        VirtualHidCapabilityToken? token,
        string actionKind = "mac.input.click",
        CapabilityTokenDomain domain = CapabilityTokenDomain.ComputerUse,
        string? scope = null,
        string? attestation = null,
        string? escrow = null)
    {
        return new CapabilityTokenVerifyRequest(token, domain, actionKind, scope, attestation, escrow);
    }

    [Fact]
    public void Valid_signed_token_is_accepted()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5));
        var result = Verifier(issuer).Verify(Req(token), Now);
        Assert.Equal(CapabilityTokenVerification.Accepted, result);
    }

    [Fact]
    public void Missing_token_is_rejected()
    {
        var issuer = new TestIssuer();
        Assert.Equal(CapabilityTokenVerification.MissingToken, Verifier(issuer).Verify(Req(null), Now));
    }

    [Fact]
    public void Expired_token_is_rejected()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-10), Now.AddMinutes(-1));
        Assert.Equal(CapabilityTokenVerification.Expired, Verifier(issuer).Verify(Req(token), Now));
    }

    [Fact]
    public void Domain_mismatch_is_rejected()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5),
            domain: CapabilityTokenDomain.RemoteUnlock);
        Assert.Equal(CapabilityTokenVerification.DomainMismatch, Verifier(issuer).Verify(Req(token), Now));
    }

    [Fact]
    public void Missing_signature_is_rejected()
    {
        var issuer = new TestIssuer();
        var unsigned = new VirtualHidCapabilityToken(
            CapabilityTokenDomain.ComputerUse, "n", Now.AddMinutes(-1), Now.AddMinutes(5),
            ClickOnly, "scope", 5);
        Assert.Equal(CapabilityTokenVerification.MissingSignature, Verifier(issuer).Verify(Req(unsigned), Now));
    }

    [Fact]
    public void Tampered_token_body_fails_signature_verification()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5), actionBudget: 5);
        // Keep the signature but mutate a signed field: budget 5 -> 999. The canonical bytes
        // change, so the real Ed25519 signature no longer verifies.
        var tampered = new VirtualHidCapabilityToken(
            token.Domain, token.Nonce, token.IssuedAt, token.ExpiresAt, token.AllowedActionKinds,
            token.ScopeHash, actionBudget: 999, token.BoundEscrowDeviceId, token.AttestationHashBlake3,
            token.SignatureEd25519Base64);
        Assert.Equal(CapabilityTokenVerification.SignatureInvalid, Verifier(issuer).Verify(Req(tampered), Now));
    }

    [Fact]
    public void Tampered_signature_bytes_fail_verification()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5));
        var sig = Convert.FromBase64String(token.SignatureEd25519Base64!);
        sig[0] ^= 0xFF;
        var tampered = token.WithSignature(Convert.ToBase64String(sig));
        Assert.Equal(CapabilityTokenVerification.SignatureInvalid, Verifier(issuer).Verify(Req(tampered), Now));
    }

    [Fact]
    public void Token_signed_by_a_different_issuer_is_rejected()
    {
        var realIssuer = new TestIssuer();
        var attacker = new TestIssuer();
        var forged = attacker.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5));
        // Verifier trusts the REAL issuer's key, so the attacker-signed token fails.
        Assert.Equal(CapabilityTokenVerification.SignatureInvalid, Verifier(realIssuer).Verify(Req(forged), Now));
    }

    [Fact]
    public void Issuer_key_unavailable_is_rejected()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5));
        var verifier = new VirtualHidCapabilityTokenVerifier(
            new InMemoryCapabilityTokenNonceStore(), () => null);
        Assert.Equal(CapabilityTokenVerification.IssuerKeyUnavailable, verifier.Verify(Req(token), Now));
    }

    [Fact]
    public void Revoked_issuer_is_rejected()
    {
        var issuer = new TestIssuer(revoked: true);
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5));
        Assert.Equal(CapabilityTokenVerification.IssuerRevoked, Verifier(issuer).Verify(Req(token), Now));
    }

    [Fact]
    public void Action_not_in_allowed_kinds_is_rejected()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5));
        Assert.Equal(
            CapabilityTokenVerification.ActionNotAllowed,
            Verifier(issuer).Verify(Req(token, actionKind: "mac.input.type"), Now));
    }

    [Fact]
    public void Zero_action_budget_is_rejected()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5), actionBudget: 0);
        Assert.Equal(CapabilityTokenVerification.ActionBudgetExhausted, Verifier(issuer).Verify(Req(token), Now));
    }

    [Fact]
    public void Replayed_nonce_is_rejected_on_second_use()
    {
        var issuer = new TestIssuer();
        var store = new InMemoryCapabilityTokenNonceStore();
        var verifier = Verifier(issuer, store);
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5), nonce: "single-use");

        Assert.Equal(CapabilityTokenVerification.Accepted, verifier.Verify(Req(token), Now));
        Assert.Equal(CapabilityTokenVerification.NonceReplay, verifier.Verify(Req(token), Now));
    }

    [Fact]
    public void Scope_mismatch_is_rejected_and_match_is_accepted()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5), scopeHash: "scope-A");
        Assert.Equal(
            CapabilityTokenVerification.ScopeMismatch,
            Verifier(issuer).Verify(Req(token, scope: "scope-B"), Now));
        Assert.Equal(
            CapabilityTokenVerification.Accepted,
            Verifier(issuer).Verify(Req(token, scope: "scope-A"), Now));
    }

    [Fact]
    public void Bound_token_without_expected_attestation_binding_is_rejected()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5), attestationHashBlake3: "att-1");
        // A bound token cannot satisfy itself when the caller omits the expected binding.
        Assert.Equal(
            CapabilityTokenVerification.AttestationMismatch,
            Verifier(issuer).Verify(Req(token), Now));
        Assert.Equal(
            CapabilityTokenVerification.Accepted,
            Verifier(issuer).Verify(Req(token, attestation: "att-1"), Now));
    }

    [Fact]
    public void Bound_token_with_wrong_escrow_device_is_rejected()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickOnly, Now.AddMinutes(-1), Now.AddMinutes(5), boundEscrowDeviceId: "device-A");
        Assert.Equal(
            CapabilityTokenVerification.EscrowDeviceMismatch,
            Verifier(issuer).Verify(Req(token, escrow: "device-B"), Now));
        Assert.Equal(
            CapabilityTokenVerification.Accepted,
            Verifier(issuer).Verify(Req(token, escrow: "device-A"), Now));
    }
}

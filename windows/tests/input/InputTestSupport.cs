// Shared fixtures for the input-path tests: a real Ed25519 issuer, a token builder, and
// spy/throwing sinks that let the tests observe the R17 structural guarantees directly.

using System;
using System.Collections.Generic;
using OpenBurnBar.Pal.Input;

namespace OpenBurnBar.Pal.Input.Tests;

/// <summary>A real Ed25519 issuer: generates a key pair, mints signed tokens, and exposes
/// the trust material the verifier consults. This exercises the SAME signature primitive
/// (Ed25519) and canonical bytes the macOS PDP uses, end to end, on macOS.</summary>
internal sealed class TestIssuer
{
    private readonly Ed25519CapabilityTokenSigner _signer = new();
    private readonly Ed25519CapabilityKeyPair _keyPair;

    public TestIssuer(string keyId = "test-issuer", bool revoked = false)
    {
        _keyPair = _signer.GenerateKeyPair();
        Trust = new CapabilityTokenIssuerTrust(_keyPair.PublicKey, keyId, revoked);
    }

    public CapabilityTokenIssuerTrust Trust { get; }

    public byte[] PublicKey => _keyPair.PublicKey;

    /// <summary>Mint a signed computer-use token for the given action kinds.</summary>
    public VirtualHidCapabilityToken Mint(
        IReadOnlyList<string> allowedActionKinds,
        DateTimeOffset issuedAt,
        DateTimeOffset expiresAt,
        int actionBudget = 5,
        string nonce = "nonce-1",
        string scopeHash = "scope-hash",
        string? boundEscrowDeviceId = null,
        string? attestationHashBlake3 = null,
        CapabilityTokenDomain domain = CapabilityTokenDomain.ComputerUse)
    {
        var unsigned = new VirtualHidCapabilityToken(
            domain,
            nonce,
            issuedAt,
            expiresAt,
            allowedActionKinds,
            scopeHash,
            actionBudget,
            boundEscrowDeviceId,
            attestationHashBlake3);
        return _signer.Sign(unsigned, _keyPair.PrivateKey);
    }
}

/// <summary>A sink that records every report it is asked to submit and can be told to fail
/// or throw. Used to PROVE the ViGEm (non-bypassable) sink is never reached on a rejected
/// or token-absent request (R17).</summary>
internal sealed class SpyInputSink : IVirtualHidInputSink
{
    private readonly bool _fail;

    public SpyInputSink(InputDispatchRoute route, bool fail = false)
    {
        Route = route;
        _fail = fail;
    }

    public InputDispatchRoute Route { get; }

    public List<VirtualHidInputReport> Submitted { get; } = new();

    public int SubmitCount => Submitted.Count;

    public VirtualHidSinkOutcome Submit(VirtualHidInputReport report)
    {
        Submitted.Add(report);
        return _fail ? VirtualHidSinkOutcome.Failure("spy-forced-failure") : VirtualHidSinkOutcome.Success;
    }
}

/// <summary>An audit sink that always throws — proves the fail-closed-audit invariant
/// (a durable audit append that fails must block dispatch).</summary>
internal sealed class ThrowingAuditSink : IInputAuditSink
{
    public void Record(VirtualHidAuditRecord record) =>
        throw new InvalidOperationException("audit persistence unavailable");
}

/// <summary>Convenience builders + a fixed clock the tests share.</summary>
internal static class InputTestClock
{
    public static readonly DateTimeOffset Now =
        new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);

    public static VirtualHidInputRequest Request(InputActionKind kind) =>
        VirtualHidInputRequest.For(new VirtualHidInputReport(kind, x: 100, y: 200));

    public static VirtualHidInputDispatcher Dispatcher(
        VirtualHidCapabilityTokenVerifier verifier,
        IInputAuditSink auditSink,
        out SpyInputSink nonBypassableSink,
        out SpyInputSink advisorySink,
        long clockMs = 1_700_000_000_000)
    {
        nonBypassableSink = new SpyInputSink(InputDispatchRoute.NonBypassable);
        advisorySink = new SpyInputSink(InputDispatchRoute.Advisory);
        var gate = new VirtualHidInputGate(verifier);
        return new VirtualHidInputDispatcher(gate, auditSink, nonBypassableSink, advisorySink, () => clockMs);
    }
}

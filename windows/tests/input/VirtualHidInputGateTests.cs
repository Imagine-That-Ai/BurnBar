// The gate-before-dispatch decision (R17) — the three lane contracts and their edges:
//   • a NON-BYPASSABLE action requires a valid capability token,
//   • an ADVISORY action logs (dispatches without a hard token gate),
//   • a token-absent non-bypassable action is REJECTED,
//   • the kill switch (incl. a throwing source) rejects everything, fail-closed.

using System;
using OpenBurnBar.Pal.Input;
using Xunit;

namespace OpenBurnBar.Pal.Input.Tests;

public sealed class VirtualHidInputGateTests
{
    private static readonly DateTimeOffset Now = InputTestClock.Now;
    private static readonly string[] ClickAndType = { "mac.input.click", "mac.input.type" };

    private static VirtualHidInputGate Gate(TestIssuer issuer, ICapabilityTokenNonceStore? store = null)
    {
        var verifier = new VirtualHidCapabilityTokenVerifier(
            store ?? new InMemoryCapabilityTokenNonceStore(), () => issuer.Trust);
        return new VirtualHidInputGate(verifier);
    }

    private static VirtualHidGateContext Context(IInputKillSwitch? killSwitch = null) =>
        new(killSwitch ?? StaticInputKillSwitch.Open, Now);

    // ── Contract 1: a non-bypassable action requires a valid capability token ──────────

    [Fact]
    public void NonBypassable_with_valid_token_dispatches_via_virtual_hid()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickAndType, Now.AddMinutes(-1), Now.AddMinutes(5));
        var decision = Gate(issuer).Decide(InputTestClock.Request(InputActionKind.Click), token, Context());

        Assert.True(decision.Allowed);
        Assert.Equal(InputDispatchRoute.NonBypassable, decision.Route);
        Assert.Equal(InputDispatchAuthorization.CapabilityTokenEnforced, decision.Authorization);
        Assert.Equal(token.Nonce, decision.TokenNonce);
    }

    [Fact]
    public void NonBypassable_with_invalid_token_is_rejected_not_downgraded()
    {
        var issuer = new TestIssuer();
        // Token only allows type, but the action is click.
        var token = issuer.Mint(new[] { "mac.input.type" }, Now.AddMinutes(-1), Now.AddMinutes(5));
        var decision = Gate(issuer).Decide(InputTestClock.Request(InputActionKind.Click), token, Context());

        Assert.False(decision.Allowed);
        Assert.Equal(VirtualHidGateDenyReason.CapabilityTokenActionNotAllowed, decision.DenyReason);
    }

    [Fact]
    public void NonBypassable_with_expired_token_is_rejected()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickAndType, Now.AddMinutes(-10), Now.AddMinutes(-1));
        var decision = Gate(issuer).Decide(InputTestClock.Request(InputActionKind.Click), token, Context());

        Assert.False(decision.Allowed);
        Assert.Equal(VirtualHidGateDenyReason.CapabilityTokenExpired, decision.DenyReason);
    }

    // ── Contract 2: an advisory action logs (dispatches without a hard token gate) ──────

    [Fact]
    public void Advisory_action_dispatches_via_sendinput_without_a_token()
    {
        var issuer = new TestIssuer();
        var decision = Gate(issuer).Decide(InputTestClock.Request(InputActionKind.PointerMove), token: null, Context());

        Assert.True(decision.Allowed);
        Assert.Equal(InputDispatchRoute.Advisory, decision.Route);
        Assert.Equal(InputDispatchAuthorization.Advisory, decision.Authorization);
        Assert.Null(decision.TokenNonce);
    }

    [Fact]
    public void Advisory_action_with_a_bad_token_is_rejected_not_silently_ignored()
    {
        var issuer = new TestIssuer();
        var expired = issuer.Mint(new[] { "mac.input.scroll" }, Now.AddMinutes(-10), Now.AddMinutes(-1));
        var decision = Gate(issuer).Decide(InputTestClock.Request(InputActionKind.Scroll), expired, Context());

        Assert.False(decision.Allowed);
        Assert.Equal(VirtualHidGateDenyReason.CapabilityTokenExpired, decision.DenyReason);
    }

    // ── Contract 3: token-absent non-bypassable action is rejected ─────────────────────

    [Fact]
    public void NonBypassable_without_a_token_is_rejected()
    {
        var issuer = new TestIssuer();
        var decision = Gate(issuer).Decide(InputTestClock.Request(InputActionKind.Type), token: null, Context());

        Assert.False(decision.Allowed);
        Assert.Equal(VirtualHidGateDenyReason.MissingCapabilityToken, decision.DenyReason);
    }

    // ── Kill switch (fail-closed) beats everything ─────────────────────────────────────

    [Fact]
    public void Kill_switch_engaged_rejects_a_valid_non_bypassable_action()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickAndType, Now.AddMinutes(-1), Now.AddMinutes(5));
        var decision = Gate(issuer).Decide(
            InputTestClock.Request(InputActionKind.Click), token, Context(StaticInputKillSwitch.Engaged));

        Assert.False(decision.Allowed);
        Assert.Equal(VirtualHidGateDenyReason.KillSwitchEngaged, decision.DenyReason);
    }

    [Fact]
    public void Kill_switch_engaged_rejects_an_advisory_action()
    {
        var issuer = new TestIssuer();
        var decision = Gate(issuer).Decide(
            InputTestClock.Request(InputActionKind.PointerMove), token: null, Context(StaticInputKillSwitch.Engaged));

        Assert.False(decision.Allowed);
        Assert.Equal(VirtualHidGateDenyReason.KillSwitchEngaged, decision.DenyReason);
    }

    [Fact]
    public void A_throwing_kill_switch_source_is_treated_as_engaged()
    {
        var issuer = new TestIssuer();
        var token = issuer.Mint(ClickAndType, Now.AddMinutes(-1), Now.AddMinutes(5));
        var throwing = new DelegatingInputKillSwitch(() => throw new InvalidOperationException("rc unreachable"));
        var decision = Gate(issuer).Decide(
            InputTestClock.Request(InputActionKind.Click), token, Context(throwing));

        Assert.False(decision.Allowed);
        Assert.Equal(VirtualHidGateDenyReason.KillSwitchEngaged, decision.DenyReason);
    }

    [Fact]
    public void Kill_switch_short_circuits_before_consuming_the_token_nonce()
    {
        var issuer = new TestIssuer();
        var store = new InMemoryCapabilityTokenNonceStore();
        var gate = Gate(issuer, store);
        var token = issuer.Mint(ClickAndType, Now.AddMinutes(-1), Now.AddMinutes(5), nonce: "keep-me");

        var blocked = gate.Decide(
            InputTestClock.Request(InputActionKind.Click), token, Context(StaticInputKillSwitch.Engaged));
        Assert.False(blocked.Allowed);
        // The nonce was NOT consumed, so the same token still works once the switch clears.
        Assert.False(store.HasConsumed("keep-me", CapabilityTokenDomain.ComputerUse));

        var allowed = gate.Decide(InputTestClock.Request(InputActionKind.Click), token, Context());
        Assert.True(allowed.Allowed);
    }
}

// The dispatcher's R17 structural guarantees:
//   • the ViGEm (non-bypassable) sink is UNREACHABLE without a valid token — a token-absent
//     or otherwise-rejected non-bypassable request never calls Submit,
//   • an advisory action is logged AND dispatched via the advisory (SendInput) sink,
//   • a durable audit record is appended BEFORE dispatch, and a failing audit sink blocks
//     dispatch (fail-closed audit),
//   • the two routes go to their own sinks and never cross.

using System;
using OpenBurnBar.Pal.Input;
using Xunit;

namespace OpenBurnBar.Pal.Input.Tests;

public sealed class VirtualHidInputDispatcherTests
{
    private static readonly DateTimeOffset Now = InputTestClock.Now;
    private static readonly string[] ClickAndType = { "mac.input.click", "mac.input.type" };

    private static VirtualHidCapabilityTokenVerifier Verifier(TestIssuer issuer, ICapabilityTokenNonceStore store) =>
        new(store, () => issuer.Trust);

    private static VirtualHidGateContext Context() => new(StaticInputKillSwitch.Open, Now);

    [Fact]
    public void Token_absent_non_bypassable_request_never_reaches_the_virtual_hid_sink()
    {
        var issuer = new TestIssuer();
        var audit = new InMemoryInputAuditSink();
        var dispatcher = InputTestClock.Dispatcher(
            Verifier(issuer, new InMemoryCapabilityTokenNonceStore()), audit,
            out var vigem, out var sendInput);

        var result = dispatcher.Dispatch(InputTestClock.Request(InputActionKind.Type), token: null, Context());

        Assert.Equal(VirtualHidDispatchStatus.RejectedByGate, result.Status);
        Assert.Equal(VirtualHidGateDenyReason.MissingCapabilityToken, result.DenyReason);
        // The R17 guarantee: NEITHER sink executed.
        Assert.Equal(0, vigem.SubmitCount);
        Assert.Equal(0, sendInput.SubmitCount);
        // The refusal was still audited.
        Assert.Single(audit.Records);
        Assert.Equal(InputDispatchDecision.Rejected, audit.Records[0].Decision);
    }

    [Fact]
    public void Valid_non_bypassable_request_dispatches_only_to_the_virtual_hid_sink()
    {
        var issuer = new TestIssuer();
        var audit = new InMemoryInputAuditSink();
        var dispatcher = InputTestClock.Dispatcher(
            Verifier(issuer, new InMemoryCapabilityTokenNonceStore()), audit,
            out var vigem, out var sendInput);
        var token = issuer.Mint(ClickAndType, Now.AddMinutes(-1), Now.AddMinutes(5));

        var result = dispatcher.Dispatch(InputTestClock.Request(InputActionKind.Click), token, Context());

        Assert.True(result.Dispatched);
        Assert.Equal(InputDispatchRoute.NonBypassable, result.Route);
        Assert.Equal(InputDispatchAuthorization.CapabilityTokenEnforced, result.Authorization);
        Assert.Equal(1, vigem.SubmitCount);
        Assert.Equal(0, sendInput.SubmitCount);

        Assert.Single(audit.Records);
        var record = audit.Records[0];
        Assert.Equal(InputDispatchDecision.Dispatched, record.Decision);
        Assert.Equal("mac.input.click", record.AuditKind);
        Assert.Equal(token.Nonce, record.CapabilityTokenNonce);
    }

    [Fact]
    public void Advisory_request_logs_and_dispatches_only_to_the_sendinput_sink()
    {
        var issuer = new TestIssuer();
        var audit = new InMemoryInputAuditSink();
        var dispatcher = InputTestClock.Dispatcher(
            Verifier(issuer, new InMemoryCapabilityTokenNonceStore()), audit,
            out var vigem, out var sendInput);

        var result = dispatcher.Dispatch(InputTestClock.Request(InputActionKind.PointerMove), token: null, Context());

        Assert.True(result.Dispatched);
        Assert.Equal(InputDispatchRoute.Advisory, result.Route);
        Assert.Equal(InputDispatchAuthorization.Advisory, result.Authorization);
        Assert.Equal(0, vigem.SubmitCount);
        Assert.Equal(1, sendInput.SubmitCount);

        Assert.Single(audit.Records);
        Assert.Equal(InputDispatchDecision.Dispatched, audit.Records[0].Decision);
        Assert.Equal(InputDispatchAuthorization.Advisory, audit.Records[0].Authorization);
    }

    [Fact]
    public void Audit_failure_blocks_dispatch_fail_closed()
    {
        var issuer = new TestIssuer();
        var dispatcher = InputTestClock.Dispatcher(
            Verifier(issuer, new InMemoryCapabilityTokenNonceStore()), new ThrowingAuditSink(),
            out var vigem, out var sendInput);
        var token = issuer.Mint(ClickAndType, Now.AddMinutes(-1), Now.AddMinutes(5));

        var result = dispatcher.Dispatch(InputTestClock.Request(InputActionKind.Click), token, Context());

        Assert.Equal(VirtualHidDispatchStatus.RejectedAuditFailure, result.Status);
        // No durable audit ⇒ no dispatch, on either sink.
        Assert.Equal(0, vigem.SubmitCount);
        Assert.Equal(0, sendInput.SubmitCount);
    }

    [Fact]
    public void Kill_switch_engaged_blocks_dispatch_on_both_routes()
    {
        var issuer = new TestIssuer();
        var audit = new InMemoryInputAuditSink();
        var gate = new VirtualHidInputGate(Verifier(issuer, new InMemoryCapabilityTokenNonceStore()));
        var vigem = new SpyInputSink(InputDispatchRoute.NonBypassable);
        var sendInput = new SpyInputSink(InputDispatchRoute.Advisory);
        var dispatcher = new VirtualHidInputDispatcher(gate, audit, vigem, sendInput, () => 1L);
        var context = new VirtualHidGateContext(StaticInputKillSwitch.Engaged, Now);
        var token = issuer.Mint(ClickAndType, Now.AddMinutes(-1), Now.AddMinutes(5));

        var nonBypassable = dispatcher.Dispatch(InputTestClock.Request(InputActionKind.Click), token, context);
        var advisory = dispatcher.Dispatch(InputTestClock.Request(InputActionKind.PointerMove), token: null, context);

        Assert.Equal(VirtualHidGateDenyReason.KillSwitchEngaged, nonBypassable.DenyReason);
        Assert.Equal(VirtualHidGateDenyReason.KillSwitchEngaged, advisory.DenyReason);
        Assert.Equal(0, vigem.SubmitCount);
        Assert.Equal(0, sendInput.SubmitCount);
    }

    [Fact]
    public void Sink_failure_surfaces_but_the_action_was_still_audited()
    {
        var issuer = new TestIssuer();
        var audit = new InMemoryInputAuditSink();
        var gate = new VirtualHidInputGate(Verifier(issuer, new InMemoryCapabilityTokenNonceStore()));
        var vigem = new SpyInputSink(InputDispatchRoute.NonBypassable, fail: true);
        var sendInput = new SpyInputSink(InputDispatchRoute.Advisory);
        var dispatcher = new VirtualHidInputDispatcher(gate, audit, vigem, sendInput, () => 1L);
        var token = issuer.Mint(ClickAndType, Now.AddMinutes(-1), Now.AddMinutes(5));

        var result = dispatcher.Dispatch(InputTestClock.Request(InputActionKind.Click), token, Context());

        Assert.Equal(VirtualHidDispatchStatus.SinkFailed, result.Status);
        Assert.False(result.SinkOutcome!.Ok);
        Assert.Equal(1, vigem.SubmitCount);
        Assert.Single(audit.Records); // audited BEFORE the sink was invoked
    }

    [Fact]
    public void Constructor_rejects_a_sink_wired_to_the_wrong_route()
    {
        var issuer = new TestIssuer();
        var gate = new VirtualHidInputGate(Verifier(issuer, new InMemoryCapabilityTokenNonceStore()));
        var swapped = new SpyInputSink(InputDispatchRoute.Advisory); // wrong route for the non-bypassable slot
        Assert.Throws<ArgumentException>(() => new VirtualHidInputDispatcher(
            gate, new InMemoryInputAuditSink(), swapped, new SpyInputSink(InputDispatchRoute.Advisory)));
    }
}

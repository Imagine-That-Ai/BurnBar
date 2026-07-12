// The dispatcher: gate → audit-before-dispatch → route to the sink.
//
// This type is the STRUCTURAL enforcement of R17. The ViGEm (non-bypassable) sink is
// private to the dispatcher and reachable ONLY after VirtualHidInputGate authorizes. The
// audit record is appended BEFORE the sink is called; if the audit sink throws, the action
// is REJECTED (AuditFailure) and never dispatched — the macOS fail-closed-audit invariant
// (ComputerUseDenyReason.auditFailure).

using System;

namespace OpenBurnBar.Pal.Input;

/// <summary>Terminal outcome of a dispatch attempt.</summary>
public enum VirtualHidDispatchStatus
{
    /// <summary>Gate authorized, audit persisted, sink executed.</summary>
    Dispatched,

    /// <summary>Gate refused.</summary>
    RejectedByGate,

    /// <summary>Gate authorized but the durable audit append failed — fail-closed, not
    /// dispatched.</summary>
    RejectedAuditFailure,

    /// <summary>Gate authorized + audited, but the sink reported a failure executing it.</summary>
    SinkFailed,
}

/// <summary>The result of a dispatch attempt.</summary>
public sealed class VirtualHidInputDispatchResult
{
    private VirtualHidInputDispatchResult(
        VirtualHidDispatchStatus status,
        InputDispatchRoute route,
        InputDispatchAuthorization authorization,
        VirtualHidGateDenyReason? denyReason,
        VirtualHidSinkOutcome? sinkOutcome,
        string? tokenNonce)
    {
        Status = status;
        Route = route;
        Authorization = authorization;
        DenyReason = denyReason;
        SinkOutcome = sinkOutcome;
        TokenNonce = tokenNonce;
    }

    public VirtualHidDispatchStatus Status { get; }
    public InputDispatchRoute Route { get; }
    public InputDispatchAuthorization Authorization { get; }
    public VirtualHidGateDenyReason? DenyReason { get; }
    public VirtualHidSinkOutcome? SinkOutcome { get; }
    public string? TokenNonce { get; }

    public bool Dispatched => Status == VirtualHidDispatchStatus.Dispatched;

    internal static VirtualHidInputDispatchResult RejectedByGate(VirtualHidGateDenyReason reason) =>
        new(VirtualHidDispatchStatus.RejectedByGate, default, default, reason, null, null);

    internal static VirtualHidInputDispatchResult AuditFailure(VirtualHidGateDecision decision) =>
        new(VirtualHidDispatchStatus.RejectedAuditFailure, decision.Route, decision.Authorization, null, null, decision.TokenNonce);

    internal static VirtualHidInputDispatchResult FromSink(VirtualHidGateDecision decision, VirtualHidSinkOutcome outcome) =>
        new(
            outcome.Ok ? VirtualHidDispatchStatus.Dispatched : VirtualHidDispatchStatus.SinkFailed,
            decision.Route,
            decision.Authorization,
            null,
            outcome,
            decision.TokenNonce);
}

/// <summary>
/// Wires the gate, the audit sink, and the two route sinks. This is the ONLY path to the
/// virtual-HID device. Callers hand it a request + optional token + context; it decides,
/// audits, and dispatches — never the reverse.
/// </summary>
public sealed class VirtualHidInputDispatcher
{
    private readonly IVirtualHidInputGate _gate;
    private readonly IInputAuditSink _auditSink;
    private readonly IVirtualHidInputSink _nonBypassableSink;
    private readonly IVirtualHidInputSink _advisorySink;
    private readonly Func<long> _clockUnixMs;

    public VirtualHidInputDispatcher(
        IVirtualHidInputGate gate,
        IInputAuditSink auditSink,
        IVirtualHidInputSink nonBypassableSink,
        IVirtualHidInputSink advisorySink,
        Func<long>? clockUnixMs = null)
    {
        _gate = gate ?? throw new ArgumentNullException(nameof(gate));
        _auditSink = auditSink ?? throw new ArgumentNullException(nameof(auditSink));
        _nonBypassableSink = nonBypassableSink ?? throw new ArgumentNullException(nameof(nonBypassableSink));
        _advisorySink = advisorySink ?? throw new ArgumentNullException(nameof(advisorySink));
        _clockUnixMs = clockUnixMs ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

        if (_nonBypassableSink.Route != InputDispatchRoute.NonBypassable)
        {
            throw new ArgumentException("Non-bypassable sink must serve the NonBypassable route.", nameof(nonBypassableSink));
        }
        if (_advisorySink.Route != InputDispatchRoute.Advisory)
        {
            throw new ArgumentException("Advisory sink must serve the Advisory route.", nameof(advisorySink));
        }
    }

    public VirtualHidInputDispatchResult Dispatch(
        VirtualHidInputRequest request,
        VirtualHidCapabilityToken? token,
        VirtualHidGateContext context)
    {
        if (request is null)
        {
            throw new ArgumentNullException(nameof(request));
        }

        var decision = _gate.Decide(request, token, context);
        var auditKind = InputActionClassifier.AuditKind(request.Kind);

        if (!decision.Allowed)
        {
            // Record the refusal best-effort; a failing audit sink must not throw out of a
            // rejection (the action is already denied).
            TryRecord(new VirtualHidAuditRecord(
                auditKind,
                decision.Route,
                decision.Authorization,
                InputDispatchDecision.Rejected,
                decision.DenyReason,
                capabilityTokenNonce: null,
                _clockUnixMs()));
            return VirtualHidInputDispatchResult.RejectedByGate(decision.DenyReason!.Value);
        }

        // Fail-closed audit BEFORE dispatch: no durable record ⇒ no action.
        var record = new VirtualHidAuditRecord(
            auditKind,
            decision.Route,
            decision.Authorization,
            InputDispatchDecision.Dispatched,
            denyReason: null,
            decision.TokenNonce,
            _clockUnixMs());
        try
        {
            _auditSink.Record(record);
        }
        catch (Exception)
        {
            return VirtualHidInputDispatchResult.AuditFailure(decision);
        }

        var sink = decision.Route == InputDispatchRoute.NonBypassable ? _nonBypassableSink : _advisorySink;
        var outcome = sink.Submit(request.Report);
        return VirtualHidInputDispatchResult.FromSink(decision, outcome);
    }

    private void TryRecord(VirtualHidAuditRecord record)
    {
        try
        {
            _auditSink.Record(record);
        }
        catch (Exception)
        {
            // Best-effort on the reject path.
        }
    }
}

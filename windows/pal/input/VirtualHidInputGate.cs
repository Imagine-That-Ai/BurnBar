// The gate-before-dispatch decision for the ViGEm virtual-HID input path (R17).
//
// This is the heart of the lane. Order matters (harshest denial wins):
//
//   0. Kill switch (fail-closed): engaged — OR a throwing kill-switch source — rejects.
//   1. Classify advisory vs non-bypassable.
//   2. NON-BYPASSABLE: require a token; a token-absent request is REJECTED. Otherwise run
//      the full capability-token verification; only an Accepted verdict authorizes
//      dispatch (CapabilityTokenEnforced). This is the R17 guarantee: the ViGEm sink is
//      unreachable without a valid, signed, unexpired, unreplayed token.
//   3. ADVISORY: logged and dispatched via SendInput (Advisory authorization). The gate
//      here is advisory only — a same-integrity process could bypass SendInput anyway — so
//      a token is not required. If a token IS supplied it is still verified (advisory) and
//      a failing token downgrades to a reject so callers cannot smuggle a bad token in.
//
// The gate is a pure function of its inputs plus the single nonce-consume performed by the
// verifier on acceptance; it has no dispatch side effect (VirtualHidInputDispatcher does).

using System;

namespace OpenBurnBar.Pal.Input;

/// <summary>Why the gate refused an action. Names mirror the relevant subset of
/// <c>ComputerUseDenyReason</c> + <c>CapabilityTokenVerificationFailure</c> on macOS.</summary>
public enum VirtualHidGateDenyReason
{
    KillSwitchEngaged,
    MissingCapabilityToken,
    CapabilityTokenExpired,
    CapabilityTokenDomainMismatch,
    CapabilityTokenMissingSignature,
    CapabilityTokenSignatureInvalid,
    CapabilityTokenActionNotAllowed,
    CapabilityTokenBudgetExhausted,
    CapabilityTokenScopeMismatch,
    CapabilityTokenAttestationMismatch,
    CapabilityTokenEscrowDeviceMismatch,
    CapabilityTokenNonceReplay,
    CapabilityTokenIssuerKeyUnavailable,
    CapabilityTokenIssuerRevoked,
}

/// <summary>Live inputs the gate needs beyond the token: the kill switch, the clock, and
/// the required scope/attestation/escrow bindings a presenter context supplies.</summary>
public sealed class VirtualHidGateContext
{
    public VirtualHidGateContext(
        IInputKillSwitch killSwitch,
        DateTimeOffset now,
        string? requiredScopeHash = null,
        string? requiredAttestationHashBlake3 = null,
        string? boundEscrowDeviceId = null)
    {
        KillSwitch = killSwitch ?? throw new ArgumentNullException(nameof(killSwitch));
        Now = now;
        RequiredScopeHash = requiredScopeHash;
        RequiredAttestationHashBlake3 = requiredAttestationHashBlake3;
        BoundEscrowDeviceId = boundEscrowDeviceId;
    }

    public IInputKillSwitch KillSwitch { get; }
    public DateTimeOffset Now { get; }
    public string? RequiredScopeHash { get; }
    public string? RequiredAttestationHashBlake3 { get; }
    public string? BoundEscrowDeviceId { get; }
}

/// <summary>The gate outcome: dispatch on a route with an authorization, or reject with a
/// reason. Immutable; consumed directly by <see cref="VirtualHidInputDispatcher"/>.</summary>
public sealed class VirtualHidGateDecision
{
    private VirtualHidGateDecision(
        bool allowed,
        InputDispatchRoute route,
        InputDispatchAuthorization authorization,
        VirtualHidGateDenyReason? denyReason,
        string? tokenNonce)
    {
        Allowed = allowed;
        Route = route;
        Authorization = authorization;
        DenyReason = denyReason;
        TokenNonce = tokenNonce;
    }

    public bool Allowed { get; }
    public InputDispatchRoute Route { get; }
    public InputDispatchAuthorization Authorization { get; }
    public VirtualHidGateDenyReason? DenyReason { get; }

    /// <summary>The consumed token's nonce when a non-bypassable action was authorized;
    /// null for advisory dispatches and rejections.</summary>
    public string? TokenNonce { get; }

    public static VirtualHidGateDecision Dispatch(
        InputDispatchRoute route,
        InputDispatchAuthorization authorization,
        string? tokenNonce = null) =>
        new(true, route, authorization, null, tokenNonce);

    public static VirtualHidGateDecision Reject(VirtualHidGateDenyReason reason) =>
        new(false, default, default, reason, null);
}

/// <summary>The gate contract.</summary>
public interface IVirtualHidInputGate
{
    VirtualHidGateDecision Decide(VirtualHidInputRequest request, VirtualHidCapabilityToken? token, VirtualHidGateContext context);
}

/// <summary>Default gate. Pure decision tree; the only side effect is the verifier's
/// single-use nonce consume on acceptance.</summary>
public sealed class VirtualHidInputGate : IVirtualHidInputGate
{
    private readonly VirtualHidCapabilityTokenVerifier _verifier;

    public VirtualHidInputGate(VirtualHidCapabilityTokenVerifier verifier) =>
        _verifier = verifier ?? throw new ArgumentNullException(nameof(verifier));

    public VirtualHidGateDecision Decide(
        VirtualHidInputRequest request,
        VirtualHidCapabilityToken? token,
        VirtualHidGateContext context)
    {
        if (request is null)
        {
            throw new ArgumentNullException(nameof(request));
        }
        if (context is null)
        {
            throw new ArgumentNullException(nameof(context));
        }

        // 0. Kill switch, fail-closed even if the source throws.
        if (IsKillSwitchEngaged(context.KillSwitch))
        {
            return VirtualHidGateDecision.Reject(VirtualHidGateDenyReason.KillSwitchEngaged);
        }

        var route = InputActionClassifier.Classify(request.Kind);

        if (route == InputDispatchRoute.NonBypassable)
        {
            // A non-bypassable action REQUIRES a valid capability token. Token-absent is a
            // hard reject (fail-closed) — never a silent SendInput fallback.
            if (token is null)
            {
                return VirtualHidGateDecision.Reject(VirtualHidGateDenyReason.MissingCapabilityToken);
            }

            var verdict = VerifyToken(request, token, context);
            return verdict == CapabilityTokenVerification.Accepted
                ? VirtualHidGateDecision.Dispatch(
                    InputDispatchRoute.NonBypassable,
                    InputDispatchAuthorization.CapabilityTokenEnforced,
                    token.Nonce)
                : VirtualHidGateDecision.Reject(MapDeny(verdict));
        }

        // Advisory route (SendInput). A token is not required, but if one is presented it
        // is still verified so a caller cannot pass a bad token and have it silently ignored.
        if (token is not null)
        {
            var verdict = VerifyToken(request, token, context);
            if (verdict != CapabilityTokenVerification.Accepted)
            {
                return VirtualHidGateDecision.Reject(MapDeny(verdict));
            }
        }

        return VirtualHidGateDecision.Dispatch(InputDispatchRoute.Advisory, InputDispatchAuthorization.Advisory);
    }

    private CapabilityTokenVerification VerifyToken(
        VirtualHidInputRequest request,
        VirtualHidCapabilityToken token,
        VirtualHidGateContext context)
    {
        var verifyRequest = new CapabilityTokenVerifyRequest(
            token,
            CapabilityTokenDomain.ComputerUse,
            request.CapabilityActionKind,
            context.RequiredScopeHash,
            context.RequiredAttestationHashBlake3,
            context.BoundEscrowDeviceId);
        return _verifier.Verify(verifyRequest, context.Now);
    }

    private static bool IsKillSwitchEngaged(IInputKillSwitch killSwitch)
    {
        try
        {
            return killSwitch.IsEngaged;
        }
        catch (Exception)
        {
            // Fail-closed (R17): a kill-switch source that cannot be read halts the path.
            return true;
        }
    }

    private static VirtualHidGateDenyReason MapDeny(CapabilityTokenVerification verdict) => verdict switch
    {
        CapabilityTokenVerification.MissingToken => VirtualHidGateDenyReason.MissingCapabilityToken,
        CapabilityTokenVerification.MissingSignature => VirtualHidGateDenyReason.CapabilityTokenMissingSignature,
        CapabilityTokenVerification.SignatureInvalid => VirtualHidGateDenyReason.CapabilityTokenSignatureInvalid,
        CapabilityTokenVerification.Expired => VirtualHidGateDenyReason.CapabilityTokenExpired,
        CapabilityTokenVerification.DomainMismatch => VirtualHidGateDenyReason.CapabilityTokenDomainMismatch,
        CapabilityTokenVerification.NonceReplay => VirtualHidGateDenyReason.CapabilityTokenNonceReplay,
        CapabilityTokenVerification.ActionNotAllowed => VirtualHidGateDenyReason.CapabilityTokenActionNotAllowed,
        CapabilityTokenVerification.ActionBudgetExhausted => VirtualHidGateDenyReason.CapabilityTokenBudgetExhausted,
        CapabilityTokenVerification.ScopeMismatch => VirtualHidGateDenyReason.CapabilityTokenScopeMismatch,
        CapabilityTokenVerification.AttestationMismatch => VirtualHidGateDenyReason.CapabilityTokenAttestationMismatch,
        CapabilityTokenVerification.EscrowDeviceMismatch => VirtualHidGateDenyReason.CapabilityTokenEscrowDeviceMismatch,
        CapabilityTokenVerification.IssuerKeyUnavailable => VirtualHidGateDenyReason.CapabilityTokenIssuerKeyUnavailable,
        CapabilityTokenVerification.IssuerRevoked => VirtualHidGateDenyReason.CapabilityTokenIssuerRevoked,
        CapabilityTokenVerification.Accepted =>
            throw new ArgumentOutOfRangeException(nameof(verdict), verdict, "Accepted is not a deny reason."),
        _ => throw new ArgumentOutOfRangeException(nameof(verdict), verdict, "Unknown verification verdict."),
    };
}

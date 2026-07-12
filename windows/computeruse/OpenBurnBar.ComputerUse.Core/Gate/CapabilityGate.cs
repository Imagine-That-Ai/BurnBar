// The capability gate the dispatcher consults before every action.
//
// Port of ComputerUseCapabilityGate.swift (DefaultComputerUseCapabilityGate).
// Order matters — early returns mean "the harshest denial wins." The decision
// tree is a pure function of immutable state, so every branch is drivable from a
// fixture with no platform runtime.

using System;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Scope;

namespace OpenBurnBar.ComputerUse.Core.Gate;

/// <summary>Why an attempted action was refused. Recorded in the audit chain's denyReason.</summary>
public enum ComputerUseDenyReason
{
    Entitlement,
    SessionLimit,
    DailyLimit,
    DailySpendCeiling,
    SoftCap,
    HardCap,
    ScopeNotMatched,
    ScopeDenied,
    DenyRegion,
    KillSwitch,
    ConcurrentSession,
    AccessibilityRevoked,
    SignatureFailure,
    CounterReplay,
    StaleTimestamp,
    UserRejected,
    AuditFailure,
    ClipboardConsentRequired,
}

/// <summary>Wire strings for <see cref="ComputerUseDenyReason"/>.</summary>
public static class ComputerUseDenyReasonWire
{
    public static string ToWire(this ComputerUseDenyReason reason) => reason switch
    {
        ComputerUseDenyReason.Entitlement => "entitlement",
        ComputerUseDenyReason.SessionLimit => "session_limit",
        ComputerUseDenyReason.DailyLimit => "daily_limit",
        ComputerUseDenyReason.DailySpendCeiling => "daily_spend_ceiling",
        ComputerUseDenyReason.SoftCap => "soft_cap",
        ComputerUseDenyReason.HardCap => "hard_cap",
        ComputerUseDenyReason.ScopeNotMatched => "scope_not_matched",
        ComputerUseDenyReason.ScopeDenied => "scope_denied",
        ComputerUseDenyReason.DenyRegion => "deny_region",
        ComputerUseDenyReason.KillSwitch => "kill_switch",
        ComputerUseDenyReason.ConcurrentSession => "concurrent_session",
        ComputerUseDenyReason.AccessibilityRevoked => "accessibility_revoked",
        ComputerUseDenyReason.SignatureFailure => "signature_failure",
        ComputerUseDenyReason.CounterReplay => "counter_replay",
        ComputerUseDenyReason.StaleTimestamp => "stale_timestamp",
        ComputerUseDenyReason.UserRejected => "user_rejected",
        ComputerUseDenyReason.AuditFailure => "audit_failure",
        ComputerUseDenyReason.ClipboardConsentRequired => "clipboard_consent_required",
        _ => throw new ArgumentOutOfRangeException(nameof(reason), reason, null),
    };
}

/// <summary>The gate's verdict: allowed (with the audit approvedBy) or denied.</summary>
public readonly struct ComputerUseCapabilityCheck : IEquatable<ComputerUseCapabilityCheck>
{
    private ComputerUseCapabilityCheck(bool allowed, AuditApprovedBy approvedBy, ComputerUseDenyReason denyReason)
    {
        IsAllowed = allowed;
        ApprovedBy = approvedBy;
        DenyReason = denyReason;
    }

    public bool IsAllowed { get; }

    public AuditApprovedBy ApprovedBy { get; }

    public ComputerUseDenyReason DenyReason { get; }

    public static ComputerUseCapabilityCheck Allowed(AuditApprovedBy approvedBy)
        => new(true, approvedBy, default);

    public static ComputerUseCapabilityCheck Denied(ComputerUseDenyReason reason)
        => new(false, default, reason);

    public bool Equals(ComputerUseCapabilityCheck other)
        => IsAllowed == other.IsAllowed
            && (IsAllowed ? ApprovedBy == other.ApprovedBy : DenyReason == other.DenyReason);

    public override bool Equals(object? obj) => obj is ComputerUseCapabilityCheck other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(IsAllowed, ApprovedBy, DenyReason);
}

/// <summary>Daily quota counters mirrored from the cloud + local caches.</summary>
public sealed class ComputerUseQuotaUsage
{
    public ComputerUseQuotaUsage(
        string dayKey,
        int browserActionsExecuted = 0,
        int systemActionsExecuted = 0,
        double visionModelSpendUsd = 0)
    {
        DayKey = dayKey;
        BrowserActionsExecuted = browserActionsExecuted;
        SystemActionsExecuted = systemActionsExecuted;
        VisionModelSpendUsd = visionModelSpendUsd;
    }

    public string DayKey { get; }

    public int BrowserActionsExecuted { get; }

    public int SystemActionsExecuted { get; }

    public double VisionModelSpendUsd { get; }

    public int TotalActionsExecuted => BrowserActionsExecuted + SystemActionsExecuted;
}

/// <summary>Live entitlement snapshot governing which lanes are unlocked.</summary>
public sealed class ComputerUseEntitlementSnapshot
{
    public ComputerUseEntitlementSnapshot(
        bool isActive,
        string? productId = null,
        DateTimeOffset? expireAt = null,
        bool allowsBrowser = false,
        bool allowsSystem = false,
        bool allowsPhoneControl = false,
        bool allowsTrustedScopes = false,
        bool allowsAuditExport = false)
    {
        IsActive = isActive;
        ProductId = productId;
        ExpireAt = expireAt;
        AllowsBrowser = allowsBrowser;
        AllowsSystem = allowsSystem;
        AllowsPhoneControl = allowsPhoneControl;
        AllowsTrustedScopes = allowsTrustedScopes;
        AllowsAuditExport = allowsAuditExport;
    }

    public bool IsActive { get; }

    public string? ProductId { get; }

    public DateTimeOffset? ExpireAt { get; }

    public bool AllowsBrowser { get; }

    public bool AllowsSystem { get; }

    public bool AllowsPhoneControl { get; }

    public bool AllowsTrustedScopes { get; }

    public bool AllowsAuditExport { get; }

    public static ComputerUseEntitlementSnapshot Inactive { get; } = new(isActive: false);
}

/// <summary>Immutable per-check inputs. The gate is a pure function of this context.</summary>
public sealed class ComputerUseCapabilityContext
{
    public ComputerUseCapabilityContext(
        ComputerUseEntitlementSnapshot entitlement,
        ComputerUseBudgetEnvelope envelope,
        ComputerUseQuotaUsage usage,
        ComputerUseSessionState session,
        bool concurrentSessionActive,
        bool killSwitch,
        bool accessibilityTrusted,
        bool originatedFromPhone = false,
        bool phoneControlRespectsDenyRegions = true,
        bool phoneSessionFirstActionConfirmed = false,
        bool clipboardConsentGranted = false)
    {
        Entitlement = entitlement;
        Envelope = envelope;
        Usage = usage;
        Session = session;
        ConcurrentSessionActive = concurrentSessionActive;
        KillSwitch = killSwitch;
        AccessibilityTrusted = accessibilityTrusted;
        OriginatedFromPhone = originatedFromPhone;
        PhoneControlRespectsDenyRegions = phoneControlRespectsDenyRegions;
        PhoneSessionFirstActionConfirmed = phoneSessionFirstActionConfirmed;
        ClipboardConsentGranted = clipboardConsentGranted;
    }

    public ComputerUseEntitlementSnapshot Entitlement { get; }

    public ComputerUseBudgetEnvelope Envelope { get; }

    public ComputerUseQuotaUsage Usage { get; }

    public ComputerUseSessionState Session { get; }

    public bool ConcurrentSessionActive { get; }

    public bool KillSwitch { get; }

    public bool AccessibilityTrusted { get; }

    public bool OriginatedFromPhone { get; }

    /// <summary>Default true (F3): even a signed remote authority obeys deny regions.</summary>
    public bool PhoneControlRespectsDenyRegions { get; }

    /// <summary>Set true once the operator confirmed the phone session on the desktop/overlay.</summary>
    public bool PhoneSessionFirstActionConfirmed { get; }

    /// <summary>Dedicated, short-lived clipboard consent. Fail-closed default false.</summary>
    public bool ClipboardConsentGranted { get; }
}

/// <summary>The default capability gate: the pure decision tree shared across platforms.</summary>
public sealed class DefaultComputerUseCapabilityGate
{
    public ComputerUseCapabilityCheck Check(
        ComputerUseAction action,
        ScopeOutcome scopeOutcome,
        AccessibilityDenyReason? accessibilityDeny,
        ComputerUseCapabilityContext context,
        DateTimeOffset now)
    {
        // 0. Org-wide kill switch.
        if (context.KillSwitch)
        {
            return Denied(ComputerUseDenyReason.KillSwitch);
        }

        // 1. Entitlement. Direct phone control is a local paired lane and must
        //    not depend on the hosted Computer-Use subscription being active.
        var directPhoneControl = context.OriginatedFromPhone
            && context.Entitlement.AllowsPhoneControl
            && !string.IsNullOrEmpty(context.Session.Manifest.PhoneViewerNodeId);
        if (!context.Entitlement.IsActive && !directPhoneControl)
        {
            return Denied(ComputerUseDenyReason.Entitlement);
        }

        switch (action.Category)
        {
            case ActionCategory.Browser:
                if (!context.Entitlement.AllowsBrowser)
                {
                    return Denied(ComputerUseDenyReason.Entitlement);
                }

                break;
            case ActionCategory.MacInput:
            case ActionCategory.MacInspect:
                if (!context.Entitlement.AllowsSystem)
                {
                    return Denied(ComputerUseDenyReason.Entitlement);
                }

                if (context.OriginatedFromPhone && !context.Entitlement.AllowsPhoneControl)
                {
                    return Denied(ComputerUseDenyReason.Entitlement);
                }

                if (!context.AccessibilityTrusted)
                {
                    return Denied(ComputerUseDenyReason.AccessibilityRevoked);
                }

                break;
            case ActionCategory.RemoteClipboard:
                if (!context.Entitlement.AllowsSystem)
                {
                    return Denied(ComputerUseDenyReason.Entitlement);
                }

                if (context.OriginatedFromPhone && !context.Entitlement.AllowsPhoneControl)
                {
                    return Denied(ComputerUseDenyReason.Entitlement);
                }

                if (!context.AccessibilityTrusted)
                {
                    return Denied(ComputerUseDenyReason.AccessibilityRevoked);
                }

                if (!context.ClipboardConsentGranted)
                {
                    return Denied(ComputerUseDenyReason.ClipboardConsentRequired);
                }

                break;
            case ActionCategory.PhoneIntent:
                if (!context.Entitlement.AllowsPhoneControl)
                {
                    return Denied(ComputerUseDenyReason.Entitlement);
                }

                break;
        }

        // 2. Concurrency.
        if (context.ConcurrentSessionActive)
        {
            return Denied(ComputerUseDenyReason.ConcurrentSession);
        }

        var skipsMeteredCaps = SkipsMeteredCapsForDirectPhoneControl(action, context);

        // Safety caps are never metering — direct phone control still obeys the
        // declared action cap and the wall-clock timeout.
        if (context.Session.ActionsExecuted >= context.Session.Manifest.ActionCap)
        {
            return Denied(ComputerUseDenyReason.SessionLimit);
        }

        if (context.Session.Manifest.SessionTimeoutSeconds > 0
            && (now - context.Session.Manifest.StartedAt).TotalSeconds
                >= context.Session.Manifest.SessionTimeoutSeconds)
        {
            return Denied(ComputerUseDenyReason.SessionLimit);
        }

        if (!skipsMeteredCaps)
        {
            // 3. Budget caps (hard > soft).
            if (context.Envelope.Level == BudgetLevel.HardCap)
            {
                return Denied(ComputerUseDenyReason.HardCap);
            }

            if (context.Envelope.Level == BudgetLevel.SoftCap && ExceedsSoftCap(context))
            {
                return Denied(ComputerUseDenyReason.SoftCap);
            }

            // 4. Daily caps.
            if (context.Usage.TotalActionsExecuted >= context.Envelope.ActiveActionsPerDay)
            {
                return Denied(ComputerUseDenyReason.DailyLimit);
            }

            if (context.Usage.VisionModelSpendUsd >= context.Envelope.PerUserDailySpendCeilingUsd)
            {
                return Denied(ComputerUseDenyReason.DailySpendCeiling);
            }
        }

        // 6. Legacy phone escape hatch — explicit opt-out ONLY, and it can NEVER
        //    override a deny region: it fires only when accessibilityDeny == null.
        if (directPhoneControl && !context.PhoneControlRespectsDenyRegions && accessibilityDeny is null)
        {
            switch (action.Category)
            {
                case ActionCategory.MacInput:
                case ActionCategory.PhoneIntent:
                    return Allowed(AuditApprovedBy.Phone);
                default:
                    break;
            }
        }

        // 7. Deny region beats EVERYTHING — agent, desktop, AND phone.
        if (accessibilityDeny is not null)
        {
            return Denied(ComputerUseDenyReason.DenyRegion);
        }

        // 8. Verified phone input that cleared the deny-region check: honor the
        //    signed authority but still require the one-time per-session approval.
        if (directPhoneControl)
        {
            switch (action.Category)
            {
                case ActionCategory.MacInput:
                case ActionCategory.PhoneIntent:
                    return PhoneControlApproval(context);
                default:
                    break;
            }
        }

        // 9. Scope rules (deny precedence enforced by the matcher).
        switch (scopeOutcome.Result)
        {
            case ScopeOutcome.Kind.Denied:
                return Denied(ComputerUseDenyReason.ScopeDenied);
            case ScopeOutcome.Kind.Allowed:
                if (context.OriginatedFromPhone)
                {
                    return PhoneControlApproval(context);
                }

                return context.Session.LiveTrustMode == ComputerUseTrustMode.Trusted
                    ? Allowed(AuditApprovedBy.TrustedScope)
                    : Allowed(AuditApprovedBy.Mac);
            case ScopeOutcome.Kind.NotMatched:
            default:
                if (context.OriginatedFromPhone)
                {
                    return PhoneControlApproval(context);
                }

                return Allowed(AuditApprovedBy.Mac);
        }
    }

    private static ComputerUseCapabilityCheck PhoneControlApproval(ComputerUseCapabilityContext context)
        => context.PhoneSessionFirstActionConfirmed
            ? Allowed(AuditApprovedBy.Phone)
            : Allowed(AuditApprovedBy.Mac);

    private static bool SkipsMeteredCapsForDirectPhoneControl(ComputerUseAction action, ComputerUseCapabilityContext context)
    {
        if (!context.OriginatedFromPhone)
        {
            return false;
        }

        return action.Category is ActionCategory.MacInput
            or ActionCategory.PhoneIntent
            or ActionCategory.RemoteClipboard;
    }

    private static bool ExceedsSoftCap(ComputerUseCapabilityContext context)
        => context.Usage.TotalActionsExecuted + 1 >= context.Envelope.ActiveActionsPerDay;

    private static ComputerUseCapabilityCheck Allowed(AuditApprovedBy approvedBy)
        => ComputerUseCapabilityCheck.Allowed(approvedBy);

    private static ComputerUseCapabilityCheck Denied(ComputerUseDenyReason reason)
        => ComputerUseCapabilityCheck.Denied(reason);
}

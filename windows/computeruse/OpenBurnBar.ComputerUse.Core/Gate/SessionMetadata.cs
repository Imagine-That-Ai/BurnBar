// Computer-Use session identity, mode, trust, and lifecycle metadata.
//
// Port of ComputerUseSessionMetadata.swift. The immutable session-start manifest
// is hashed by the audit chain as the parent of the first entry, binding every
// entry to the session's declared identity, scope, and trust mode.

using System;
using System.Collections.Generic;
using OpenBurnBar.ComputerUse.Core.Crypto;
using OpenBurnBar.ComputerUse.Core.Scope;

namespace OpenBurnBar.ComputerUse.Core.Gate;

/// <summary>Which surface a session drives.</summary>
public enum ComputerUseMode
{
    /// <summary>Path A — read-only mirror; no synthesized input.</summary>
    AgentWatch,

    /// <summary>Path B — a managed Chromium/WebView2 window; browser tool kinds only.</summary>
    Browser,

    /// <summary>Path C — the whole desktop via SendInput + UIA. Requires input privileges.</summary>
    System,
}

/// <summary>Approval granularity. Never sticky across sessions; resets to Manual.</summary>
public enum ComputerUseTrustMode
{
    /// <summary>Every action gates through an approval request. Default.</summary>
    Manual = 0,

    /// <summary>Every action gates, but an approval can cover a short burst window.</summary>
    Step = 1,

    /// <summary>Actions covered by an active scope rule dispatch without per-action approval.</summary>
    Trusted = 2,
}

/// <summary>Why a session ended.</summary>
public enum ComputerUseEndReason
{
    Completed,
    UserHalt,
    PanicHotkey,
    PanicPhoneGesture,
    PanicMacLock,
    PanicRemoteConfig,
    PanicAccessibilityRevoked,
    Timeout,
    EntitlementLost,
    BudgetSoftCap,
    BudgetHardCap,
    Error,
}

/// <summary>Which independent kill path fired. Recorded on every panic audit entry.</summary>
public enum ComputerUsePanicSource
{
    Hotkey,
    PhoneGesture,
    MacLock,
    RemoteConfig,
    AccessibilityRevoked,
    Stalled,
    Revoked,
}

/// <summary>Wire strings for the session enums (stable; match the Swift core).</summary>
public static class SessionEnumWire
{
    public static string ToWire(this ComputerUseMode mode) => mode switch
    {
        ComputerUseMode.AgentWatch => "agent_watch",
        ComputerUseMode.Browser => "browser",
        ComputerUseMode.System => "system",
        _ => throw new ArgumentOutOfRangeException(nameof(mode), mode, null),
    };

    public static string ToWire(this ComputerUseTrustMode trust) => trust switch
    {
        ComputerUseTrustMode.Manual => "manual",
        ComputerUseTrustMode.Step => "step",
        ComputerUseTrustMode.Trusted => "trusted",
        _ => throw new ArgumentOutOfRangeException(nameof(trust), trust, null),
    };

    public static string ToWire(this ComputerUseEndReason reason) => reason switch
    {
        ComputerUseEndReason.Completed => "completed",
        ComputerUseEndReason.UserHalt => "user_halt",
        ComputerUseEndReason.PanicHotkey => "panic_hotkey",
        ComputerUseEndReason.PanicPhoneGesture => "panic_phone_gesture",
        ComputerUseEndReason.PanicMacLock => "panic_mac_lock",
        ComputerUseEndReason.PanicRemoteConfig => "panic_remote_config",
        ComputerUseEndReason.PanicAccessibilityRevoked => "panic_accessibility_revoked",
        ComputerUseEndReason.Timeout => "timeout",
        ComputerUseEndReason.EntitlementLost => "entitlement_lost",
        ComputerUseEndReason.BudgetSoftCap => "budget_soft_cap",
        ComputerUseEndReason.BudgetHardCap => "budget_hard_cap",
        ComputerUseEndReason.Error => "error",
        _ => throw new ArgumentOutOfRangeException(nameof(reason), reason, null),
    };

    public static string ToWire(this ComputerUsePanicSource source) => source switch
    {
        ComputerUsePanicSource.Hotkey => "hotkey",
        ComputerUsePanicSource.PhoneGesture => "phone_gesture",
        ComputerUsePanicSource.MacLock => "mac_lock",
        ComputerUsePanicSource.RemoteConfig => "remote_config",
        ComputerUsePanicSource.AccessibilityRevoked => "accessibility_revoked",
        ComputerUsePanicSource.Stalled => "stalled",
        ComputerUsePanicSource.Revoked => "revoked",
        _ => throw new ArgumentOutOfRangeException(nameof(source), source, null),
    };
}

/// <summary>Immutable session-start manifest. Hashed as the audit chain's genesis parent.</summary>
public sealed class ComputerUseSessionManifest
{
    public ComputerUseSessionManifest(
        string sessionId,
        ComputerUseMode mode,
        ComputerUseTrustMode trustMode,
        DateTimeOffset startedAt,
        string userId,
        string entitlementProductId,
        int actionCap,
        int sessionTimeoutSeconds,
        string? macHostNodeId = null,
        string? phoneViewerNodeId = null,
        IReadOnlyList<string>? scopeRuleIds = null,
        IReadOnlyList<ScopeRule>? scopeRules = null)
    {
        SessionId = sessionId ?? throw new ArgumentNullException(nameof(sessionId));
        Mode = mode;
        TrustMode = trustMode;
        StartedAt = startedAt;
        UserId = userId ?? throw new ArgumentNullException(nameof(userId));
        EntitlementProductId = entitlementProductId ?? throw new ArgumentNullException(nameof(entitlementProductId));
        ActionCap = actionCap;
        SessionTimeoutSeconds = sessionTimeoutSeconds;
        MacHostNodeId = macHostNodeId;
        PhoneViewerNodeId = phoneViewerNodeId;
        ScopeRuleIds = scopeRuleIds ?? Array.Empty<string>();
        ScopeRules = scopeRules ?? Array.Empty<ScopeRule>();
    }

    public string SessionId { get; }

    public ComputerUseMode Mode { get; }

    public ComputerUseTrustMode TrustMode { get; }

    public DateTimeOffset StartedAt { get; }

    public string UserId { get; }

    public string EntitlementProductId { get; }

    public int ActionCap { get; }

    public int SessionTimeoutSeconds { get; }

    public string? MacHostNodeId { get; }

    public string? PhoneViewerNodeId { get; }

    public IReadOnlyList<string> ScopeRuleIds { get; }

    public IReadOnlyList<ScopeRule> ScopeRules { get; }

    /// <summary>Canonical-JSON map (audit-hasher form) used to hash the genesis parent.</summary>
    public CanonicalJsonObject ToCanonicalMap()
    {
        var scopeRules = new List<CanonicalJsonObject>(ScopeRules.Count);
        foreach (var rule in ScopeRules)
        {
            scopeRules.Add(rule.ToCanonicalMap());
        }

        return new CanonicalJsonObject()
            .Set("sessionId", SessionId)
            .Set("mode", Mode.ToWire())
            .Set("trustMode", TrustMode.ToWire())
            .Set("startedAt", StartedAt.ToUnixTimeMilliseconds())
            .Set("userId", UserId)
            .Set("macHostNodeId", MacHostNodeId)
            .Set("phoneViewerNodeId", PhoneViewerNodeId)
            .Set("scopeRuleIds", ScopeRuleIds)
            .Set("scopeRules", scopeRules)
            .Set("entitlementProductId", EntitlementProductId)
            .Set("actionCap", ActionCap)
            .Set("sessionTimeoutSeconds", SessionTimeoutSeconds);
    }
}

/// <summary>Live, mutable session state. Trust mode moves down freely; up needs UI confirmation.</summary>
public sealed class ComputerUseSessionState
{
    public ComputerUseSessionState(
        string sessionId,
        ComputerUseSessionManifest manifest,
        ComputerUseTrustMode liveTrustMode,
        int actionsExecuted = 0,
        int actionsRejected = 0,
        DateTimeOffset? lastActionAt = null,
        ComputerUseEndReason? endReason = null,
        DateTimeOffset? endedAt = null,
        string? auditChainHeadHashHex = null,
        int sessionTokensConsumed = 0)
    {
        SessionId = sessionId;
        Manifest = manifest;
        LiveTrustMode = liveTrustMode;
        ActionsExecuted = actionsExecuted;
        ActionsRejected = actionsRejected;
        LastActionAt = lastActionAt;
        EndReason = endReason;
        EndedAt = endedAt;
        AuditChainHeadHashHex = auditChainHeadHashHex;
        SessionTokensConsumed = sessionTokensConsumed;
    }

    public string SessionId { get; }

    public ComputerUseSessionManifest Manifest { get; }

    public ComputerUseTrustMode LiveTrustMode { get; set; }

    public int ActionsExecuted { get; set; }

    public int ActionsRejected { get; set; }

    public DateTimeOffset? LastActionAt { get; set; }

    public ComputerUseEndReason? EndReason { get; set; }

    public DateTimeOffset? EndedAt { get; set; }

    public string? AuditChainHeadHashHex { get; set; }

    public int SessionTokensConsumed { get; set; }
}

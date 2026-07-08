using System;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.Scope;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class GateTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);
    private readonly DefaultComputerUseCapabilityGate _gate = new();

    private static ComputerUseEntitlementSnapshot FullEntitlement => new(
        isActive: true, productId: "prod", allowsBrowser: true, allowsSystem: true,
        allowsPhoneControl: true, allowsTrustedScopes: true, allowsAuditExport: true);

    private static ComputerUseSessionState Session(
        ComputerUseTrustMode trust = ComputerUseTrustMode.Manual,
        int actionsExecuted = 0,
        int actionCap = 50,
        int timeoutSeconds = 0,
        string? phoneViewerNodeId = null,
        DateTimeOffset? startedAt = null)
    {
        var manifest = new ComputerUseSessionManifest(
            sessionId: "s1",
            mode: ComputerUseMode.System,
            trustMode: trust,
            startedAt: startedAt ?? Now,
            userId: "u1",
            entitlementProductId: "prod",
            actionCap: actionCap,
            sessionTimeoutSeconds: timeoutSeconds,
            phoneViewerNodeId: phoneViewerNodeId);
        return new ComputerUseSessionState("s1", manifest, trust, actionsExecuted: actionsExecuted);
    }

    private static ComputerUseCapabilityContext Ctx(
        ComputerUseEntitlementSnapshot? entitlement = null,
        ComputerUseBudgetEnvelope? envelope = null,
        ComputerUseQuotaUsage? usage = null,
        ComputerUseSessionState? session = null,
        bool concurrent = false,
        bool killSwitch = false,
        bool accessibilityTrusted = true,
        bool originatedFromPhone = false,
        bool phoneRespectsDenyRegions = true,
        bool phoneFirstActionConfirmed = false,
        bool clipboardConsent = false)
        => new(
            entitlement ?? FullEntitlement,
            envelope ?? ComputerUseBudgetEnvelope.InitialNormal,
            usage ?? new ComputerUseQuotaUsage("2026-07-03"),
            session ?? Session(),
            concurrent, killSwitch, accessibilityTrusted, originatedFromPhone,
            phoneRespectsDenyRegions, phoneFirstActionConfirmed, clipboardConsent);

    private static readonly BrowserAction BrowserClick = new(BrowserAction.Kind.Click, selector: "#go");
    private static readonly MacInputAction DesktopClick = new(MacInputAction.Kind.Click, displayX: 10, displayY: 10);

    [Fact]
    public void KillSwitchDeniesBeforeAnythingElse()
    {
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null, Ctx(killSwitch: true), Now);
        Assert.False(result.IsAllowed);
        Assert.Equal(ComputerUseDenyReason.KillSwitch, result.DenyReason);
    }

    [Fact]
    public void InactiveEntitlementDeniesNonPhone()
    {
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null,
            Ctx(entitlement: ComputerUseEntitlementSnapshot.Inactive), Now);
        Assert.Equal(ComputerUseDenyReason.Entitlement, result.DenyReason);
    }

    [Fact]
    public void BrowserWithoutBrowserEntitlementDenies()
    {
        var ent = new ComputerUseEntitlementSnapshot(isActive: true, allowsBrowser: false, allowsSystem: true);
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null, Ctx(entitlement: ent), Now);
        Assert.Equal(ComputerUseDenyReason.Entitlement, result.DenyReason);
    }

    [Fact]
    public void DesktopInputWhenAccessibilityRevokedDenies()
    {
        var result = _gate.Check(DesktopClick, ScopeOutcome.NotMatched, null,
            Ctx(accessibilityTrusted: false), Now);
        Assert.Equal(ComputerUseDenyReason.AccessibilityRevoked, result.DenyReason);
    }

    [Fact]
    public void ClipboardRequiresDedicatedConsent()
    {
        var clip = new RemoteClipboardAction(RemoteClipboardAction.Kind.PasteToMac, "r1", "text/plain", 1024);
        var denied = _gate.Check(clip, ScopeOutcome.NotMatched, null, Ctx(clipboardConsent: false), Now);
        Assert.Equal(ComputerUseDenyReason.ClipboardConsentRequired, denied.DenyReason);

        var allowed = _gate.Check(clip, ScopeOutcome.NotMatched, null, Ctx(clipboardConsent: true), Now);
        Assert.True(allowed.IsAllowed);
    }

    [Fact]
    public void ConcurrentSessionDenies()
    {
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null, Ctx(concurrent: true), Now);
        Assert.Equal(ComputerUseDenyReason.ConcurrentSession, result.DenyReason);
    }

    [Fact]
    public void SessionActionCapDenies()
    {
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null,
            Ctx(session: Session(actionsExecuted: 50, actionCap: 50)), Now);
        Assert.Equal(ComputerUseDenyReason.SessionLimit, result.DenyReason);
    }

    [Fact]
    public void SessionTimeoutDenies()
    {
        var session = Session(timeoutSeconds: 60, startedAt: Now.AddSeconds(-120));
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null, Ctx(session: session), Now);
        Assert.Equal(ComputerUseDenyReason.SessionLimit, result.DenyReason);
    }

    [Fact]
    public void HardCapDenies()
    {
        var envelope = ComputerUseBudgetEnvelope.HardCapEnvelope(3000, 2000, Now);
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null, Ctx(envelope: envelope), Now);
        Assert.Equal(ComputerUseDenyReason.HardCap, result.DenyReason);
    }

    [Fact]
    public void SoftCapDeniesWhenNearTightenedBudget()
    {
        var envelope = ComputerUseBudgetEnvelope.SoftCapEnvelope(1800, 1500, Now); // 100 actions/day
        var usage = new ComputerUseQuotaUsage("2026-07-03", browserActionsExecuted: 100);
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null,
            Ctx(envelope: envelope, usage: usage), Now);
        Assert.Equal(ComputerUseDenyReason.SoftCap, result.DenyReason);
    }

    [Fact]
    public void DailyLimitDenies()
    {
        var usage = new ComputerUseQuotaUsage("2026-07-03", browserActionsExecuted: 200); // == normal 200/day
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null, Ctx(usage: usage), Now);
        Assert.Equal(ComputerUseDenyReason.DailyLimit, result.DenyReason);
    }

    [Fact]
    public void DailySpendCeilingDenies()
    {
        var usage = new ComputerUseQuotaUsage("2026-07-03", visionModelSpendUsd: 5.0); // == $5 ceiling
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null, Ctx(usage: usage), Now);
        Assert.Equal(ComputerUseDenyReason.DailySpendCeiling, result.DenyReason);
    }

    [Fact]
    public void DenyRegionBeatsAnAllowRule()
    {
        var result = _gate.Check(
            DesktopClick, ScopeOutcome.Allowed("rule-1"),
            AccessibilityDenyReason.SecureTextField, Ctx(), Now);
        Assert.Equal(ComputerUseDenyReason.DenyRegion, result.DenyReason);
    }

    [Fact]
    public void ScopeDeniedDenies()
    {
        var result = _gate.Check(BrowserClick, ScopeOutcome.Denied("deny-1"), null, Ctx(), Now);
        Assert.Equal(ComputerUseDenyReason.ScopeDenied, result.DenyReason);
    }

    [Fact]
    public void TrustedModeAllowedScopeReturnsTrustedScope()
    {
        var result = _gate.Check(
            BrowserClick, ScopeOutcome.Allowed("rule-1"), null,
            Ctx(session: Session(trust: ComputerUseTrustMode.Trusted)), Now);
        Assert.True(result.IsAllowed);
        Assert.Equal(AuditApprovedBy.TrustedScope, result.ApprovedBy);
    }

    [Fact]
    public void ManualAllowedScopeReturnsMac()
    {
        var result = _gate.Check(BrowserClick, ScopeOutcome.Allowed("rule-1"), null, Ctx(), Now);
        Assert.True(result.IsAllowed);
        Assert.Equal(AuditApprovedBy.Mac, result.ApprovedBy);
    }

    [Fact]
    public void NotMatchedFallsBackToMacApproval()
    {
        var result = _gate.Check(BrowserClick, ScopeOutcome.NotMatched, null, Ctx(), Now);
        Assert.True(result.IsAllowed);
        Assert.Equal(AuditApprovedBy.Mac, result.ApprovedBy);
    }

    [Fact]
    public void PhoneFirstActionRaisesMacApprovalThenFlowsAsPhone()
    {
        var session = Session(phoneViewerNodeId: "phone-node");

        var first = _gate.Check(DesktopClick, ScopeOutcome.NotMatched, null,
            Ctx(session: session, originatedFromPhone: true, phoneFirstActionConfirmed: false), Now);
        Assert.True(first.IsAllowed);
        Assert.Equal(AuditApprovedBy.Mac, first.ApprovedBy);

        var later = _gate.Check(DesktopClick, ScopeOutcome.NotMatched, null,
            Ctx(session: session, originatedFromPhone: true, phoneFirstActionConfirmed: true), Now);
        Assert.True(later.IsAllowed);
        Assert.Equal(AuditApprovedBy.Phone, later.ApprovedBy);
    }

    [Fact]
    public void PhoneEscapeHatchFiresOnlyWithOptOutAndNeverOverDenyRegion()
    {
        var session = Session(phoneViewerNodeId: "phone-node");

        // Opt-out set + no deny region => escape hatch grants phone directly.
        var hatch = _gate.Check(DesktopClick, ScopeOutcome.NotMatched, null,
            Ctx(session: session, originatedFromPhone: true, phoneRespectsDenyRegions: false,
                phoneFirstActionConfirmed: false), Now);
        Assert.True(hatch.IsAllowed);
        Assert.Equal(AuditApprovedBy.Phone, hatch.ApprovedBy);

        // Even with the opt-out, a deny region wins.
        var blocked = _gate.Check(DesktopClick, ScopeOutcome.NotMatched,
            AccessibilityDenyReason.SecureTextField,
            Ctx(session: session, originatedFromPhone: true, phoneRespectsDenyRegions: false), Now);
        Assert.Equal(ComputerUseDenyReason.DenyRegion, blocked.DenyReason);
    }
}

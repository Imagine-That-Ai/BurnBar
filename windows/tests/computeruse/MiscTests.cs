using System;
using System.IO;
using OpenBurnBar.ComputerUse.Core;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Scope;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class BudgetProjectorTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void NormalBelowSoftThreshold()
    {
        var envelope = ComputerUseBudgetProjector.Envelope(1000, 500, Now);
        Assert.Equal(BudgetLevel.Normal, envelope.Level);
        Assert.Equal(200, envelope.ActiveActionsPerDay);
    }

    [Fact]
    public void SoftCapAtThreshold()
    {
        var envelope = ComputerUseBudgetProjector.Envelope(1500, 900, Now);
        Assert.Equal(BudgetLevel.SoftCap, envelope.Level);
        Assert.Equal(100, envelope.ActiveActionsPerDay);
    }

    [Fact]
    public void HardCapAtThreshold()
    {
        var envelope = ComputerUseBudgetProjector.Envelope(2500, 2000, Now);
        Assert.Equal(BudgetLevel.HardCap, envelope.Level);
        Assert.Equal(0, envelope.ActiveActionsPerDay);
    }

    [Fact]
    public void MonthEndProjectionExtrapolatesLinearlyAndClamps()
    {
        Assert.Equal(300, ComputerUseBudgetProjector.ProjectMonthEnd(100, 10, 30));
        // Divide-by-zero and negative days clamp to at least one elapsed day.
        Assert.Equal(50, ComputerUseBudgetProjector.ProjectMonthEnd(50, 0, 0));
    }
}

public sealed class AttestationBindingTests
{
    [Fact]
    public void DigestIsDeterministicAndAppBound()
    {
        var a = AppCheckAttestationBinding.DigestHex("app-1", 1000);
        var b = AppCheckAttestationBinding.DigestHex("app-1", 1000);
        var c = AppCheckAttestationBinding.DigestHex("app-2", 1000);

        Assert.Equal(a, b);
        Assert.NotEqual(a, c);
        Assert.Equal(64, a.Length);
    }

    [Fact]
    public void FreshnessWindowIsThirtyDays()
    {
        var claim = new AppCheckAttestationBinding.Claim("app-1", boundAtMillis: 0);
        Assert.True(AppCheckAttestationBinding.IsFresh(claim, AppCheckAttestationBinding.MaxAgeMillis));
        Assert.False(AppCheckAttestationBinding.IsFresh(claim, AppCheckAttestationBinding.MaxAgeMillis + 1));
    }
}

public sealed class EndToEndSafetyTests : IDisposable
{
    private static readonly DateTimeOffset Now = new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "cu-e2e-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_dir))
        {
            Directory.Delete(_dir, recursive: true);
        }
    }

    [Fact]
    public void GateAllows_AuditAppends_ChainVerifies_ThenPanicBlocksFurtherDispatch()
    {
        // 1. The gate allows a browser action under a matching allow rule.
        var entitlement = new ComputerUseEntitlementSnapshot(
            isActive: true, allowsBrowser: true, allowsSystem: true);
        var manifest = new ComputerUseSessionManifest(
            "e2e", ComputerUseMode.Browser, ComputerUseTrustMode.Manual, Now, "u1", "prod",
            actionCap: 50, sessionTimeoutSeconds: 0);
        var session = new ComputerUseSessionState("e2e", manifest, ComputerUseTrustMode.Manual);
        var context = new ComputerUseCapabilityContext(
            entitlement, ComputerUseBudgetEnvelope.InitialNormal,
            new ComputerUseQuotaUsage("2026-07-03"), session,
            concurrentSessionActive: false, killSwitch: false, accessibilityTrusted: true);

        var action = new BrowserAction(BrowserAction.Kind.Click, selector: "#submit");
        var verdict = new DefaultComputerUseCapabilityGate()
            .Check(action, ScopeOutcome.Allowed("rule-allow"), null, context, Now);
        Assert.True(verdict.IsAllowed);

        // 2. The fail-closed audit reservation is appended BEFORE dispatch.
        var flag = new InMemoryKillSwitchFlag();
        var kill = new KillSwitchStateMachine(flag);
        var logger = new ComputerUseAuditLogger("e2e", _dir, "1.0.0");
        logger.BeginSession(manifest);

        Assert.False(kill.ShouldBlockDispatch());
        var entry = logger.MakeEntry(action, Now, verdict.ApprovedBy, scopeRuleId: "rule-allow");
        logger.Append(entry);

        // 3. The chain verifies against the manifest hash.
        var chain = File.ReadAllBytes(Path.Combine(logger.Directory, "chain.jsonl"));
        var manifestHash = new ComputerUseAuditChain().HashSessionManifest(manifest.ToCanonicalMap());
        Assert.True(new ComputerUseAuditChain().Validate(chain, manifestHash).IsValid);

        // 4. A panic fires: the very next dispatch check blocks, and no further
        //    action is appended after the panic is observed.
        kill.SignalHotkey();
        Assert.True(kill.ShouldBlockDispatch());
        Assert.Equal(ComputerUsePanicSource.Hotkey, kill.HaltSource);

        var beforeIndex = logger.NextEntryIndex;
        if (!kill.ShouldBlockDispatch())
        {
            logger.Append(logger.MakeEntry(action, Now, verdict.ApprovedBy));
        }

        Assert.Equal(beforeIndex, logger.NextEntryIndex); // nothing appended post-panic
    }
}

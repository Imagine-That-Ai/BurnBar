using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Budget;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Budget;

// Real, macOS-runnable port of AgentLensTests/Active/BudgetGateMattersTests.swift — the
// FAIL-CLOSED contract that is the entire reason this gate exists: a failed ledger read means
// current spend is UNKNOWN and must never silently let a possibly-over-budget request through.
// Plus the warn-threshold / hard-cap classification the WinUI chip + blocked card render.

public sealed class BudgetGateTests
{
    // ── Fail CLOSED: a failed ledger read must not let a request through ─────────────

    [Fact]
    public async Task HardBlock_LedgerReadFails_FailsClosedToBlock()
    {
        BudgetRule blocking = BudgetFixtures.Rule(BudgetBehavior.HardBlock);
        BudgetGate gate = BudgetFixtures.Gate(new[] { blocking }, new StubLedger(null));

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 1.0);

        var block = Assert.IsType<BudgetGateDecision.Block>(decision);
        Assert.Equal(blocking.Id, block.Rule.Id);
        Assert.Equal(blocking.AmountUsd, block.Limit);
        // Fails closed at the limit (not at 0) so the surfaced error reads "$X of $X".
        Assert.Equal(blocking.AmountUsd, block.Used);
        Assert.Null(block.Fallback);
    }

    [Fact]
    public async Task WarnThenBlock_LedgerReadFails_FailsClosedToBlock()
    {
        BudgetRule blocking = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock);
        BudgetGate gate = BudgetFixtures.Gate(new[] { blocking }, new StubLedger(null));

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 1.0);

        Assert.IsType<BudgetGateDecision.Block>(decision);
    }

    [Fact]
    public async Task HardBlockWithFallback_LedgerReadFails_FailsClosedToBlock()
    {
        BudgetRule blocking = BudgetFixtures.Rule(BudgetBehavior.HardBlockWithFallback);
        BudgetGate gate = BudgetFixtures.Gate(new[] { blocking }, new StubLedger(null));

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 1.0);

        Assert.IsType<BudgetGateDecision.Block>(decision);
    }

    [Fact]
    public async Task WarnOnly_LedgerReadFails_SurfacesWarnNotAllowAndNeverBlocks()
    {
        BudgetRule observe = BudgetFixtures.Rule(BudgetBehavior.WarnOnly);
        BudgetGate gate = BudgetFixtures.Gate(new[] { observe }, new StubLedger(null));

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 1.0);

        // .warnOnly is contractually non-blocking: it must NOT fail to .block, and must NOT
        // silently .allow — a failed read is surfaced as a warning.
        var warn = Assert.IsType<BudgetGateDecision.Warn>(decision);
        Assert.Equal(observe.Id, warn.Rule.Id);
        Assert.Equal(observe.AmountUsd, warn.Limit);
        Assert.Equal(1.0, warn.UsedPercent);
    }

    [Fact]
    public async Task OneRuleReadsAllow_OtherRuleReadFails_OverallFailsClosed()
    {
        // Both rules match the same credential. healthy reads cleanly and is well under budget
        // (would be .allow); faulting's read throws. Most-restrictive must win => overall
        // .block, proving a single failed read cannot be masked by another rule's healthy allow.
        BudgetRule healthy = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, amountUsd: 100, accountId: "slot-1");
        BudgetRule faulting = BudgetFixtures.Rule(BudgetBehavior.HardBlock, amountUsd: 50, accountId: "slot-1");

        var ledger = new StubLedger(1.0, new Dictionary<string, double?> { [faulting.Id] = null });
        BudgetGate gate = BudgetFixtures.Gate(new[] { healthy, faulting }, ledger);

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 1.0);

        var block = Assert.IsType<BudgetGateDecision.Block>(decision);
        Assert.Equal(faulting.Id, block.Rule.Id);
    }

    // ── Subscription credentials short-circuit BEFORE any ledger read ────────────────

    [Fact]
    public async Task SubscriptionCredential_NeverReadsLedger_AndAllows()
    {
        BudgetRule blocking = BudgetFixtures.Rule(BudgetBehavior.HardBlock);
        var ledger = new StubLedger(null);
        BudgetGate gate = BudgetFixtures.Gate(new[] { blocking }, ledger);

        BudgetGateDecision decision = await gate.EvaluateAsync(
            BudgetFixtures.Credential(BudgetBillingMode.Subscription),
            estimatedCost: 1.0);

        Assert.IsType<BudgetGateDecision.Allow>(decision);
        Assert.Equal(0, ledger.ReadCount);
    }

    [Fact]
    public async Task NoMatchingRules_AllowsWithoutReadingLedger()
    {
        var ledger = new StubLedger(null);
        BudgetRule unrelated = BudgetFixtures.Rule(BudgetBehavior.HardBlock, accountId: "other-slot");
        BudgetGate gate = BudgetFixtures.Gate(new[] { unrelated }, ledger);

        BudgetGateDecision decision = await gate.EvaluateAsync(
            BudgetFixtures.Credential(slotId: "slot-1"),
            estimatedCost: 1.0);

        Assert.IsType<BudgetGateDecision.Allow>(decision);
        Assert.Equal(0, ledger.ReadCount);
    }

    // ── Healthy read paths ───────────────────────────────────────────────────────────

    [Fact]
    public async Task HealthyRead_UnderBudget_Allows()
    {
        BudgetRule blocking = BudgetFixtures.Rule(BudgetBehavior.HardBlock, amountUsd: 50);
        BudgetGate gate = BudgetFixtures.Gate(new[] { blocking }, new StubLedger(5.0));

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 1.0);

        Assert.IsType<BudgetGateDecision.Allow>(decision);
    }

    [Fact]
    public async Task HealthyRead_OverBudget_Blocks()
    {
        BudgetRule blocking = BudgetFixtures.Rule(BudgetBehavior.HardBlock, amountUsd: 50);
        BudgetGate gate = BudgetFixtures.Gate(new[] { blocking }, new StubLedger(50.0));

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 1.0);

        var block = Assert.IsType<BudgetGateDecision.Block>(decision);
        Assert.Equal(50.0, block.Used);
        Assert.Equal(50.0, block.Limit);
    }

    // ── Threshold classification (the 80% warn band the chip + toast key off) ────────

    [Fact]
    public async Task WarnThenBlock_ProjectedCrossesWarnThreshold_Warns()
    {
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, amountUsd: 100);
        // used 78 + estimated 5 = 83 projected = 83% >= 80% warn, < 100% block.
        BudgetGate gate = BudgetFixtures.Gate(new[] { rule }, new StubLedger(78.0));

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 5.0);

        var warn = Assert.IsType<BudgetGateDecision.Warn>(decision);
        Assert.Equal(0.78, warn.UsedPercent, 3);
        Assert.Equal(78.0, warn.Used);
        Assert.Equal(100.0, warn.Limit);
    }

    [Fact]
    public async Task WarnThenBlock_ProjectedCostTipsOverLimit_Blocks()
    {
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, amountUsd: 100);
        // used 98 + estimated 5 = 103 projected >= 100% => block even though used < limit.
        BudgetGate gate = BudgetFixtures.Gate(new[] { rule }, new StubLedger(98.0));

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 5.0);

        var block = Assert.IsType<BudgetGateDecision.Block>(decision);
        Assert.Equal(98.0, block.Used);
    }

    [Fact]
    public async Task HardBlock_BelowLimit_DoesNotWarn_Allows()
    {
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.HardBlock, amountUsd: 100);
        // 85% projected — hardBlock has no warn band, so it allows until 100%.
        BudgetGate gate = BudgetFixtures.Gate(new[] { rule }, new StubLedger(80.0));

        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 5.0);

        Assert.IsType<BudgetGateDecision.Allow>(decision);
    }

    // ── Paused rules surface as paused, not block, and are less restrictive than a block ─

    [Fact]
    public async Task PausedRule_SurfacesPaused_WithoutReadingLedger()
    {
        System.DateTimeOffset now = System.DateTimeOffset.UtcNow;
        BudgetRule paused = BudgetFixtures.Rule(BudgetBehavior.HardBlock) with { PausedUntil = now.AddHours(1) };
        var ledger = new StubLedger(null);
        BudgetGate gate = BudgetFixtures.Gate(new[] { paused }, ledger);

        BudgetGateDecision decision = await gate.EvaluateAsync(
            BudgetFixtures.Credential(), estimatedCost: 1.0, reference: now);

        Assert.IsType<BudgetGateDecision.Paused>(decision);
        Assert.Equal(0, ledger.ReadCount);
    }
}

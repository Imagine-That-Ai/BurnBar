using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Budget;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Budget;

// The end-to-end enforcement proof required by the lane brief: create a rule, simulate spend,
// and assert enforcement fires at the WARN threshold and the HARD-CAP threshold. Drives the
// FULL portable pipeline — BudgetSettingsModel (create) -> BudgetGate (classify at spend) ->
// BudgetEnforcementCoordinator (notify with debounce) -> RecordingNotifier — so the rule the
// UI creates is the same object the gate enforces and the toast surfaces.

public sealed class BudgetEnforcementTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);

    /// <summary>A mutable ledger whose spend the test dials to simulate accumulating cost.</summary>
    private sealed class DialLedger : IBudgetLedgerReading
    {
        public double Spend { get; set; }

        public Task<double> CurrentSpendAsync(BudgetRule rule, DateTimeOffset reference, System.Threading.CancellationToken cancellationToken = default) =>
            Task.FromResult(Spend);
    }

    private static async Task<(BudgetSettingsModel Settings, BudgetRule Rule)> CreateWarnThenBlockRuleAsync(double limit)
    {
        var settings = new BudgetSettingsModel(new InMemoryBudgetRuleStore(), deviceId: "test", now: () => Now);
        BudgetRule created = await settings.UpsertRuleAsync(new BudgetRule
        {
            Scope = BudgetRuleScope.Credential,
            ProviderId = "openrouter",
            AccountId = "slot-1",
            Label = "OpenRouter main",
            AmountUsd = limit,
            Period = BudgetPeriod.Month,
            Behavior = BudgetBehavior.WarnThenBlock,
        });
        return (settings, created);
    }

    [Fact]
    public async Task CreateRule_SpendClimbs_EnforcementFiresWarnThenBlock()
    {
        (BudgetSettingsModel settings, BudgetRule rule) = await CreateWarnThenBlockRuleAsync(limit: 100);

        // The rule the UI created is now visible to the gate through the same settings model.
        Assert.Single(settings.CredentialRules);
        Assert.Equal(rule.Id, settings.CredentialRules[0].Id);

        var ledger = new DialLedger();
        var gate = new BudgetGate(settings, ledger, warningThreshold: 0.8);
        var notifier = new RecordingNotifier();
        var coordinator = new BudgetEnforcementCoordinator(notifier, BudgetClock.Default);
        BudgetCredentialIdentity credential = BudgetFixtures.Credential();

        // 1) Spend well under the cap => allow, nothing surfaced.
        ledger.Spend = 40;
        BudgetGateDecision d1 = await gate.EvaluateAsync(credential, estimatedCost: 1.0, reference: Now);
        Assert.IsType<BudgetGateDecision.Allow>(d1);
        Assert.Equal(BudgetEnforcementOutcome.None, coordinator.Handle(d1, Now));
        Assert.Empty(notifier.Warnings);
        Assert.Empty(notifier.Blocks);

        // 2) Spend crosses the 80% warn threshold => warn + exactly one warning notification.
        ledger.Spend = 85;
        BudgetGateDecision d2 = await gate.EvaluateAsync(credential, estimatedCost: 1.0, reference: Now);
        Assert.IsType<BudgetGateDecision.Warn>(d2);
        Assert.Equal(BudgetEnforcementOutcome.WarningEmitted, coordinator.Handle(d2, Now));
        Assert.Single(notifier.Warnings);
        Assert.Equal(rule.Id, notifier.Warnings[0].Rule.Id);
        Assert.Equal(85, notifier.Warnings[0].Used);

        // 3) A second warn in the SAME period debounces — no duplicate spam.
        ledger.Spend = 90;
        BudgetGateDecision d3 = await gate.EvaluateAsync(credential, estimatedCost: 1.0, reference: Now);
        Assert.IsType<BudgetGateDecision.Warn>(d3);
        Assert.Equal(BudgetEnforcementOutcome.WarningDebounced, coordinator.Handle(d3, Now));
        Assert.Single(notifier.Warnings);

        // 4) Spend hits the hard cap => block + a block notification (always fires).
        ledger.Spend = 100;
        BudgetGateDecision d4 = await gate.EvaluateAsync(credential, estimatedCost: 1.0, reference: Now);
        var block = Assert.IsType<BudgetGateDecision.Block>(d4);
        Assert.Equal(rule.Id, block.Rule.Id);
        Assert.Equal(BudgetEnforcementOutcome.BlockEmitted, coordinator.Handle(d4, Now));
        Assert.Single(notifier.Blocks);
        Assert.Equal(100, notifier.Blocks[0].Used);
        Assert.Equal(100, notifier.Blocks[0].Limit);
    }

    [Fact]
    public async Task HardCap_BlockNotificationFiresEveryTime_NotDebounced()
    {
        (BudgetSettingsModel settings, _) = await CreateWarnThenBlockRuleAsync(limit: 50);
        var ledger = new DialLedger { Spend = 60 };
        var gate = new BudgetGate(settings, ledger, warningThreshold: 0.8);
        var notifier = new RecordingNotifier();
        var coordinator = new BudgetEnforcementCoordinator(notifier);
        BudgetCredentialIdentity credential = BudgetFixtures.Credential();

        BudgetGateDecision first = await gate.EvaluateAsync(credential, estimatedCost: 1.0, reference: Now);
        BudgetGateDecision second = await gate.EvaluateAsync(credential, estimatedCost: 1.0, reference: Now);
        coordinator.Handle(first, Now);
        coordinator.Handle(second, Now);

        // Blocks are never debounced — the user must act each time a blocked request is retried.
        Assert.Equal(2, notifier.Blocks.Count);
    }

    [Fact]
    public async Task WarnOnlyRule_OverCap_NeverBlocks_ButStillNotifies()
    {
        var settings = new BudgetSettingsModel(new InMemoryBudgetRuleStore(), now: () => Now);
        BudgetRule rule = await settings.UpsertRuleAsync(new BudgetRule
        {
            Scope = BudgetRuleScope.Global,
            Label = "Observe only",
            AmountUsd = 100,
            Period = BudgetPeriod.Month,
            Behavior = BudgetBehavior.WarnOnly,
        });

        var ledger = new DialLedger { Spend = 130 };
        var gate = new BudgetGate(settings, ledger, warningThreshold: 0.8);
        var notifier = new RecordingNotifier();
        var coordinator = new BudgetEnforcementCoordinator(notifier);

        // Global rules apply to any per-usage credential.
        BudgetGateDecision decision = await gate.EvaluateAsync(BudgetFixtures.Credential(), estimatedCost: 1.0, reference: Now);

        Assert.IsType<BudgetGateDecision.Warn>(decision);
        Assert.Equal(BudgetEnforcementOutcome.WarningEmitted, coordinator.Handle(decision, Now));
        Assert.Single(notifier.Warnings);
        Assert.Empty(notifier.Blocks);
        Assert.Equal(rule.Id, notifier.Warnings[0].Rule.Id);
    }

    [Fact]
    public void ResetWarningDebounce_AllowsANewWarningNextPeriod()
    {
        var notifier = new RecordingNotifier();
        var coordinator = new BudgetEnforcementCoordinator(notifier);
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, amountUsd: 100);
        var warn = new BudgetGateDecision.Warn(rule, 0.85, 85, 100);

        Assert.Equal(BudgetEnforcementOutcome.WarningEmitted, coordinator.Handle(warn, Now));
        Assert.Equal(BudgetEnforcementOutcome.WarningDebounced, coordinator.Handle(warn, Now));

        coordinator.ResetWarningDebounce();
        Assert.Equal(BudgetEnforcementOutcome.WarningEmitted, coordinator.Handle(warn, Now));
        Assert.Equal(2, notifier.Warnings.Count);
    }

    [Fact]
    public void BlockDecision_ProducesBlockedCardErrorMatchingTheRule()
    {
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, amountUsd: 50);
        var block = new BudgetGateDecision.Block(rule, 52.37, 50, null);
        DateTimeOffset reset = Now.AddDays(4);

        BudgetBlockedError error = BudgetBlockedError.FromDecision(block, reset);
        var card = new BudgetBlockedCardModel(error);

        Assert.Equal(rule.DisplayLabel, card.RuleLabel);
        Assert.Equal("$52.37", card.UsedText);
        Assert.Equal("$50.00", card.LimitText);
        Assert.Equal("per month", card.PeriodLabel);
        Assert.True(card.HasReset);
        // The "+$25" raise produces a rule 25 dollars higher, ready for upsert.
        Assert.Equal(75, card.RaisedRule().AmountUsd);
        Assert.Contains("Budget limit reached on", error.ErrorDescription);
    }
}

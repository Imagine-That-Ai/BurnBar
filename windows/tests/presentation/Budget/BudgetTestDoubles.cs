using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Budget;

namespace OpenBurnBar.App.Presentation.Tests.Budget;

// In-memory doubles that let the Budget gate/coordinator run without any storage. The rule
// provider filtering mirrors BudgetSettingsModel exactly; the ledger can throw on demand
// (the whole point of the fail-closed gate); the notifier records every call. These mirror
// the fakes in AgentLensTests/Active/BudgetGateMattersTests.swift.

/// <summary>In-memory <see cref="IBudgetRuleProvider"/> with BudgetSettings-parity filtering.</summary>
internal sealed class FakeRuleProvider : IBudgetRuleProvider
{
    private readonly List<BudgetRule> _all;

    public FakeRuleProvider(IEnumerable<BudgetRule> rules)
    {
        _all = rules.ToList();
    }

    public IReadOnlyList<BudgetRule> Rules => _all;

    public IReadOnlyList<BudgetRule> GlobalRules =>
        _all.Where(r => r.Scope == BudgetRuleScope.Global).ToList();

    public IReadOnlyList<BudgetRule> RulesForCredential(string providerId, string? accountId) =>
        _all.Where(r =>
        {
            if (r.Scope != BudgetRuleScope.Credential || !string.Equals(r.ProviderId, providerId, StringComparison.Ordinal))
            {
                return false;
            }

            if (accountId is not null)
            {
                return string.Equals(r.AccountId, accountId, StringComparison.Ordinal);
            }

            return string.IsNullOrEmpty(r.AccountId);
        }).ToList();

    public IReadOnlyList<BudgetRule> RulesForProject(string projectName) =>
        _all.Where(r => r.Scope == BudgetRuleScope.Project &&
                        string.Equals(r.ProjectName, projectName, StringComparison.Ordinal)).ToList();
}

/// <summary>
/// A ledger that either throws or returns a fixed spend, with per-rule overrides, and records
/// how many reads it served (so a subscription short-circuit can be proven to touch it zero
/// times). Mirrors the Swift StubLedger.
/// </summary>
internal sealed class StubLedger : IBudgetLedgerReading
{
    private readonly double? _defaultSpend;
    private readonly Dictionary<string, double?> _perRule;

    /// <summary>Pass <c>null</c> to throw; a value returns that spend.</summary>
    public StubLedger(double? defaultSpend, IDictionary<string, double?>? perRule = null)
    {
        _defaultSpend = defaultSpend;
        _perRule = perRule is null ? new Dictionary<string, double?>() : new Dictionary<string, double?>(perRule);
    }

    public int ReadCount { get; private set; }

    public Task<double> CurrentSpendAsync(BudgetRule rule, DateTimeOffset reference, CancellationToken cancellationToken = default)
    {
        ReadCount++;
        double? mode = _perRule.TryGetValue(rule.Id, out double? v) ? v : _defaultSpend;
        if (mode is not double spend)
        {
            throw new InvalidOperationException("simulated ledger read fault");
        }

        return Task.FromResult(spend);
    }
}

/// <summary>Records every notification the enforcement coordinator drives.</summary>
internal sealed class RecordingNotifier : IBudgetNotifier
{
    public List<(BudgetRule Rule, double Used, double Limit, DateTimeOffset? PeriodStart)> Warnings { get; } = new();

    public List<(BudgetRule Rule, double Used, double Limit)> Blocks { get; } = new();

    public void EmitWarning(BudgetRule rule, double used, double limit, DateTimeOffset? periodStart) =>
        Warnings.Add((rule, used, limit, periodStart));

    public void EmitBlock(BudgetRule rule, double used, double limit) =>
        Blocks.Add((rule, used, limit));
}

/// <summary>Shared fixture builders.</summary>
internal static class BudgetFixtures
{
    public static BudgetRule Rule(
        BudgetBehavior behavior,
        BudgetRuleScope scope = BudgetRuleScope.Credential,
        double amountUsd = 50,
        string? providerId = "openrouter",
        string? accountId = "slot-1",
        string? projectName = null,
        bool isEnabled = true)
    {
        return new BudgetRule
        {
            Id = "rule-" + Guid.NewGuid().ToString("N"),
            Scope = scope,
            ProviderId = providerId,
            AccountId = accountId,
            ProjectName = projectName,
            Label = "Test rule",
            AmountUsd = amountUsd,
            Period = BudgetPeriod.Month,
            Behavior = behavior,
            IsEnabled = isEnabled,
        };
    }

    public static BudgetCredentialIdentity Credential(
        BudgetBillingMode billingMode = BudgetBillingMode.PerUsage,
        string providerId = "openrouter",
        string slotId = "slot-1") => new(providerId, slotId, "Test credential", billingMode);

    public static BudgetGate Gate(IEnumerable<BudgetRule> rules, StubLedger ledger) =>
        new(new FakeRuleProvider(rules), ledger, warningThreshold: 0.8);
}

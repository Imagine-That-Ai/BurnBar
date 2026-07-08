using OpenBurnBar.App.Presentation.Budget;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Budget;

// Locks the enum raw-value strings + displayLabel synthesis + billing-mode prefix mapping to
// byte parity with the Swift model, so a future cross-platform budget_rules table round-trips.

public sealed class BudgetModelParityTests
{
    [Theory]
    [InlineData(BudgetRuleScope.Credential, "credential")]
    [InlineData(BudgetRuleScope.Project, "project")]
    [InlineData(BudgetRuleScope.Global, "global")]
    [InlineData(BudgetRuleScope.Organization, "organization")]
    public void Scope_RawValue_RoundTrips(BudgetRuleScope scope, string raw)
    {
        Assert.Equal(raw, scope.Raw());
        Assert.Equal(scope, BudgetEnumRaw.ParseScope(raw));
    }

    [Theory]
    [InlineData(BudgetPeriod.Day, "day")]
    [InlineData(BudgetPeriod.Week, "week")]
    [InlineData(BudgetPeriod.Month, "month")]
    [InlineData(BudgetPeriod.AllTime, "allTime")]
    public void Period_RawValue_RoundTrips(BudgetPeriod period, string raw)
    {
        Assert.Equal(raw, period.Raw());
        Assert.Equal(period, BudgetEnumRaw.ParsePeriod(raw));
    }

    [Theory]
    [InlineData(BudgetBehavior.WarnThenBlock, "warnThenBlock")]
    [InlineData(BudgetBehavior.HardBlock, "hardBlock")]
    [InlineData(BudgetBehavior.WarnOnly, "warnOnly")]
    [InlineData(BudgetBehavior.HardBlockWithFallback, "hardBlockWithFallback")]
    public void Behavior_RawValue_RoundTrips(BudgetBehavior behavior, string raw)
    {
        Assert.Equal(raw, behavior.Raw());
        Assert.Equal(behavior, BudgetEnumRaw.ParseBehavior(raw));
    }

    [Fact]
    public void EventKind_RawValues_MatchSwift()
    {
        Assert.Equal("warning", BudgetEventKind.Warning.Raw());
        Assert.Equal("ruleCreated", BudgetEventKind.RuleCreated.Raw());
        Assert.Equal("ruleDeleted", BudgetEventKind.RuleDeleted.Raw());
    }

    [Fact]
    public void DisplayLabel_UsesExplicitLabelWhenPresent()
    {
        var rule = new BudgetRule { Scope = BudgetRuleScope.Global, Label = "My cap", AmountUsd = 10 };
        Assert.Equal("My cap", rule.DisplayLabel);
    }

    [Fact]
    public void DisplayLabel_SynthesizesPerScope()
    {
        Assert.Equal("All per-usage credentials",
            new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 10 }.DisplayLabel);

        Assert.Equal("openrouter · …abc123",
            new BudgetRule { Scope = BudgetRuleScope.Credential, ProviderId = "openrouter", AccountId = "slot-abc123", AmountUsd = 10 }.DisplayLabel);

        Assert.Equal("openai · default",
            new BudgetRule { Scope = BudgetRuleScope.Credential, ProviderId = "openai", AmountUsd = 10 }.DisplayLabel);

        Assert.Equal("burnbar",
            new BudgetRule { Scope = BudgetRuleScope.Project, ProjectName = "burnbar", AmountUsd = 10 }.DisplayLabel);

        Assert.Equal("Unnamed project",
            new BudgetRule { Scope = BudgetRuleScope.Project, AmountUsd = 10 }.DisplayLabel);
    }

    [Theory]
    [InlineData("sk-ant-oat01-secret", BudgetBillingMode.Subscription)]
    [InlineData("tp-plan-token", BudgetBillingMode.Subscription)]
    [InlineData("sk-ant-api03-secret", BudgetBillingMode.PerUsage)]
    [InlineData("sk-proj-openaisecret", BudgetBillingMode.PerUsage)]
    [InlineData("glpat-something", BudgetBillingMode.Unknown)]
    public void BillingMode_ForSecretPrefix_MatchesSwift(string prefix, BudgetBillingMode expected)
    {
        Assert.Equal(expected, BudgetCredentialIdentity.BillingModeForSecretPrefix(prefix));
    }

    [Fact]
    public void IsPaused_TrueOnlyWhenPauseIsInTheFuture()
    {
        System.DateTimeOffset now = new(2026, 7, 3, 12, 0, 0, System.TimeSpan.Zero);
        var future = new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 10, PausedUntil = now.AddHours(1) };
        var past = new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 10, PausedUntil = now.AddHours(-1) };

        Assert.True(future.IsPaused(now));
        Assert.False(past.IsPaused(now));
        Assert.False(new BudgetRule { Scope = BudgetRuleScope.Global, AmountUsd = 10 }.IsPaused(now));
    }
}

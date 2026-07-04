using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Budget;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Budget;

// Port of BurnRailBudgetChip's visibility (>= 50%), severity banding (80% / 100%), and
// most-restrictive-rule selection.

public sealed class BurnRailBudgetChipModelTests
{
    private static BudgetRule Rule(string id, double amount, bool enabled = true) => new()
    {
        Id = id,
        Scope = BudgetRuleScope.Credential,
        ProviderId = "openrouter",
        Label = id,
        AmountUsd = amount,
        IsEnabled = enabled,
    };

    [Fact]
    public void Below50Percent_ChipIsHidden()
    {
        BudgetRule rule = Rule("r", 100);
        BudgetChipState? state = BurnRailBudgetChipModel.Compute(
            new[] { rule }, new Dictionary<string, double> { [rule.Id] = 40 });

        Assert.Null(state);
    }

    [Fact]
    public void AtOrAbove50Percent_ChipShows_NormalSeverity()
    {
        BudgetRule rule = Rule("r", 100);
        BudgetChipState? state = BurnRailBudgetChipModel.Compute(
            new[] { rule }, new Dictionary<string, double> { [rule.Id] = 60 });

        Assert.NotNull(state);
        Assert.Equal(BudgetChipSeverity.Normal, state!.Severity);
        Assert.Equal("$60/$100", state.AmountLabel);
    }

    [Fact]
    public void At80Percent_SeverityIsWarning()
    {
        BudgetRule rule = Rule("r", 100);
        BudgetChipState? state = BurnRailBudgetChipModel.Compute(
            new[] { rule }, new Dictionary<string, double> { [rule.Id] = 82 });

        Assert.Equal(BudgetChipSeverity.Warning, state!.Severity);
    }

    [Fact]
    public void At100Percent_SeverityIsBlocked_TooltipSaysBlocked()
    {
        BudgetRule rule = Rule("r", 100);
        BudgetChipState? state = BurnRailBudgetChipModel.Compute(
            new[] { rule }, new Dictionary<string, double> { [rule.Id] = 103 });

        Assert.Equal(BudgetChipSeverity.Blocked, state!.Severity);
        Assert.Contains("BLOCKED", state.Tooltip);
    }

    [Fact]
    public void PicksTheMostRestrictiveRule()
    {
        BudgetRule mild = Rule("mild", 100);   // 60%
        BudgetRule severe = Rule("severe", 100); // 95%
        var spend = new Dictionary<string, double> { [mild.Id] = 60, [severe.Id] = 95 };

        BudgetChipState? state = BurnRailBudgetChipModel.Compute(new[] { mild, severe }, spend);

        Assert.Equal("severe", state!.Rule.Id);
        Assert.Equal(BudgetChipSeverity.Warning, state.Severity);
    }

    [Fact]
    public void IgnoresDisabledAndZeroAmountRules()
    {
        BudgetRule disabled = Rule("disabled", 100, enabled: false);
        BudgetRule zero = Rule("zero", 0);
        var spend = new Dictionary<string, double> { [disabled.Id] = 200, [zero.Id] = 200 };

        BudgetChipState? state = BurnRailBudgetChipModel.Compute(new[] { disabled, zero }, spend);

        Assert.Null(state);
    }

    [Theory]
    [InlineData(0.49, BudgetChipSeverity.Normal)]
    [InlineData(0.80, BudgetChipSeverity.Warning)]
    [InlineData(1.00, BudgetChipSeverity.Blocked)]
    [InlineData(1.50, BudgetChipSeverity.Blocked)]
    public void SeverityFor_MatchesTheBands(double pct, BudgetChipSeverity expected)
    {
        Assert.Equal(expected, BurnRailBudgetChipModel.SeverityFor(pct));
    }
}

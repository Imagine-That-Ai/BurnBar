using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED from AgentLens/Views/Dashboard/Components/BurnRailBudgetChip.swift — the "most
// restrictive active rule" selection + the 50%/80%/100% severity banding + the compact
// $used/$limit label + tooltip/accessibility strings. Pure; the WinUI chip binds a brush to
// Severity via a converter, keeping this layer color-free.

/// <summary>Severity band for the budget rail chip. Drives tint in the WinUI converter.</summary>
public enum BudgetChipSeverity
{
    /// <summary>50–79% used — neutral tint.</summary>
    Normal,

    /// <summary>80–99% used — warning tint.</summary>
    Warning,

    /// <summary>100%+ used — error/blocked tint.</summary>
    Blocked,
}

/// <summary>Rendered chip state, or the sentinel that the chip should stay hidden.</summary>
public sealed record BudgetChipState
{
    public required BudgetRule Rule { get; init; }
    public required double Used { get; init; }
    public required double Percent { get; init; }
    public required BudgetChipSeverity Severity { get; init; }
    public required string AmountLabel { get; init; }
    public required string Tooltip { get; init; }
    public required string AccessibilityLabel { get; init; }
}

/// <summary>Selects and formats the top-rail budget chip. Mirrors the Swift view's computed body.</summary>
public static class BurnRailBudgetChipModel
{
    /// <summary>Below this fraction of any rule's limit the chip stays hidden (too noisy).</summary>
    public const double VisibilityThreshold = 0.5;

    /// <summary>Warning band lower bound.</summary>
    public const double WarningThreshold = 0.8;

    /// <summary>
    /// Returns the chip state for the rule closest to (or over) its limit, or <c>null</c> when
    /// no enabled rule with a positive limit is at least 50% spent.
    /// </summary>
    public static BudgetChipState? Compute(IReadOnlyList<BudgetRule> rules, IReadOnlyDictionary<string, double> spendByRule)
    {
        BudgetRule? worst = null;
        double worstPercent = double.NegativeInfinity;

        foreach (BudgetRule rule in rules)
        {
            if (!rule.IsEnabled || rule.AmountUsd <= 0)
            {
                continue;
            }

            double used = spendByRule.TryGetValue(rule.Id, out double s) ? s : 0;
            double pct = used / rule.AmountUsd;
            if (pct < VisibilityThreshold)
            {
                continue;
            }

            if (pct > worstPercent)
            {
                worstPercent = pct;
                worst = rule;
            }
        }

        if (worst is null)
        {
            return null;
        }

        double worstUsed = spendByRule.TryGetValue(worst.Id, out double u) ? u : 0;
        double percent = worst.AmountUsd > 0 ? worstUsed / worst.AmountUsd : 0;

        return new BudgetChipState
        {
            Rule = worst,
            Used = worstUsed,
            Percent = percent,
            Severity = SeverityFor(percent),
            AmountLabel = AmountLabelFor(worstUsed, worst.AmountUsd),
            Tooltip = TooltipFor(worst, worstUsed, percent),
            AccessibilityLabel = AccessibilityLabelFor(worst, worstUsed, percent),
        };
    }

    /// <summary>Severity band for a used fraction. Mirrors <c>tintFor</c>.</summary>
    public static BudgetChipSeverity SeverityFor(double percent)
    {
        if (percent >= 1.0)
        {
            return BudgetChipSeverity.Blocked;
        }

        if (percent >= WarningThreshold)
        {
            return BudgetChipSeverity.Warning;
        }

        return BudgetChipSeverity.Normal;
    }

    private static string AmountLabelFor(double used, double limit) =>
        string.Format(CultureInfo.InvariantCulture, "${0:F0}/${1:F0}", used, limit);

    private static string TooltipFor(BudgetRule rule, double used, double pct)
    {
        string period = PeriodLabel(rule.Period);
        if (pct >= 1.0)
        {
            return string.Format(
                CultureInfo.InvariantCulture,
                "{0}: BLOCKED — ${1:F2} of ${2:F2} {3}. Click to open Budgets.",
                rule.DisplayLabel, used, rule.AmountUsd, period);
        }

        return string.Format(
            CultureInfo.InvariantCulture,
            "{0}: ${1:F2} of ${2:F2} {3} ({4}%)",
            rule.DisplayLabel, used, rule.AmountUsd, period, (int)(pct * 100));
    }

    private static string AccessibilityLabelFor(BudgetRule rule, double used, double pct)
    {
        string status = pct >= 1.0
            ? "blocked"
            : string.Format(CultureInfo.InvariantCulture, "{0}% used", (int)(pct * 100));
        return string.Format(
            CultureInfo.InvariantCulture,
            "Budget {0}: {1}, ${2:F2} of ${3:F2}",
            rule.DisplayLabel, status, used, rule.AmountUsd);
    }

    /// <summary>"per day" / "per week" / "per month" / "all time". Mirrors the Swift helper.</summary>
    public static string PeriodLabel(BudgetPeriod period) => period switch
    {
        BudgetPeriod.Day => "per day",
        BudgetPeriod.Week => "per week",
        BudgetPeriod.Month => "per month",
        BudgetPeriod.AllTime => "all time",
        _ => "per month",
    };
}

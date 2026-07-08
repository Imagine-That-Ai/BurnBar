using System;
using System.Globalization;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED from AgentLens/Views/Chat/BudgetBlockedCard.swift (+ the BudgetBlockedError it
// renders). The card is the first-class chat error surfaced when a per-usage credential hits
// its cap: rule label, used/limit, period, reset time, and the three actions (raise +$25,
// allow this session, open Budget Settings). This view-model holds the presented strings +
// the raise amount; the WinUI BudgetBlockedCard binds to it and raises the action callbacks.

/// <summary>
/// The "budget limit reached" error a blocking gate decision produces. Mirrors the Swift
/// <c>BudgetBlockedError</c>. Build one from a <see cref="BudgetGateDecision.Block"/>.
/// </summary>
public sealed record BudgetBlockedError
{
    public required BudgetRule Rule { get; init; }
    public required double Used { get; init; }
    public required double Limit { get; init; }
    public BudgetCredentialIdentity? Fallback { get; init; }
    public DateTimeOffset? ResetAt { get; init; }

    /// <summary>Build the error from a gate block decision (+ the rule's next reset).</summary>
    public static BudgetBlockedError FromDecision(
        BudgetGateDecision.Block block,
        DateTimeOffset? resetAt = null) => new()
    {
        Rule = block.Rule,
        Used = block.Used,
        Limit = block.Limit,
        Fallback = block.Fallback,
        ResetAt = resetAt,
    };

    /// <summary>"Budget limit reached on {label}: $used of $limit." Mirrors <c>errorDescription</c>.</summary>
    public string ErrorDescription => string.Format(
        CultureInfo.InvariantCulture,
        "Budget limit reached on {0}: ${1:F2} of ${2:F2}.",
        Rule.DisplayLabel, Used, Limit);
}

/// <summary>Presented state for the WinUI blocked card. Pure formatting over the error.</summary>
public sealed class BudgetBlockedCardModel
{
    /// <summary>The default raise increment offered by the "+$25" button. Mirrors the Swift 25.</summary>
    public const double RaiseIncrementUsd = 25;

    public BudgetBlockedCardModel(BudgetBlockedError error)
    {
        Error = error ?? throw new ArgumentNullException(nameof(error));
    }

    public BudgetBlockedError Error { get; }

    public BudgetRule Rule => Error.Rule;

    public string Title => "Budget limit reached";

    public string RuleLabel => Error.Rule.DisplayLabel;

    public string UsedText => string.Format(CultureInfo.InvariantCulture, "${0:F2}", Error.Used);

    public string LimitText => string.Format(CultureInfo.InvariantCulture, "${0:F2}", Error.Limit);

    public string PeriodLabel => BurnRailBudgetChipModel.PeriodLabel(Error.Rule.Period);

    public bool HasReset => Error.ResetAt.HasValue;

    /// <summary>"Resets {abbreviated date + short time}." Empty when no reset (all-time rules).</summary>
    public string ResetText => Error.ResetAt is DateTimeOffset reset
        ? "Resets " + reset.ToLocalTime().ToString("MMM d, h:mm tt", CultureInfo.InvariantCulture)
        : string.Empty;

    /// <summary>The rule as it would look after the "+$25" raise, ready to hand to upsert.</summary>
    public BudgetRule RaisedRule() => Error.Rule with { AmountUsd = Error.Rule.AmountUsd + RaiseIncrementUsd };

    public string RaiseButtonLabel => string.Format(CultureInfo.InvariantCulture, "+${0:F0}", RaiseIncrementUsd);
}

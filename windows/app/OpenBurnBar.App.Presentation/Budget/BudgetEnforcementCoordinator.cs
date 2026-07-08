using System;
using System.Collections.Generic;
using System.Globalization;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED from AgentLens/Services/DataStore/BudgetNotificationCenter.swift — the "turn a gate
// decision into a user-facing notification" layer: debounce 80% warnings to one per
// (rule, period-window) so a chatty day doesn't spam, and ALWAYS fire the 100% block because
// the user must act. Pure/deterministic; the WinUI BudgetToastNotifier implements IBudgetNotifier
// with a real WinRT AppNotification (Windows-only, dev-host-deferred), while this coordinator
// (debounce + routing) is unit-tested on macOS.

/// <summary>The side-effect seam the coordinator drives. The WinUI toast implements this.</summary>
public interface IBudgetNotifier
{
    /// <summary>Surface an 80%-threshold warning for a rule.</summary>
    void EmitWarning(BudgetRule rule, double used, double limit, DateTimeOffset? periodStart);

    /// <summary>Surface a 100% block for a rule.</summary>
    void EmitBlock(BudgetRule rule, double used, double limit);
}

/// <summary>What a single <see cref="BudgetEnforcementCoordinator.Handle"/> call did.</summary>
public enum BudgetEnforcementOutcome
{
    /// <summary>Allow / paused — nothing surfaced.</summary>
    None,

    /// <summary>A warning was surfaced.</summary>
    WarningEmitted,

    /// <summary>A warning was suppressed by the per-(rule, period) debounce.</summary>
    WarningDebounced,

    /// <summary>A block was surfaced (always fires).</summary>
    BlockEmitted,
}

/// <summary>
/// Routes <see cref="BudgetGateDecision"/>s to an <see cref="IBudgetNotifier"/>, applying the
/// one-warning-per-(rule, period-window) debounce and the always-fire block. Mirrors the Swift
/// <c>BudgetNotificationCenter</c> debounce contract.
/// </summary>
public sealed class BudgetEnforcementCoordinator
{
    private readonly IBudgetNotifier _notifier;
    private readonly BudgetClock _clock;
    private readonly HashSet<string> _warningSeen = new(StringComparer.Ordinal);

    public BudgetEnforcementCoordinator(IBudgetNotifier notifier, BudgetClock? clock = null)
    {
        _notifier = notifier ?? throw new ArgumentNullException(nameof(notifier));
        _clock = clock ?? BudgetClock.Default;
    }

    /// <summary>
    /// Handle a gate decision at <paramref name="reference"/>. Warnings debounce to one per
    /// (rule, period-window); blocks always fire; allow/paused do nothing.
    /// </summary>
    public BudgetEnforcementOutcome Handle(BudgetGateDecision decision, DateTimeOffset reference)
    {
        switch (decision)
        {
            case BudgetGateDecision.Warn warn:
            {
                DateTimeOffset? periodStart = _clock.WindowStart(warn.Rule.Period, reference);
                string key = WarningKey(warn.Rule, periodStart);
                if (!_warningSeen.Add(key))
                {
                    return BudgetEnforcementOutcome.WarningDebounced;
                }

                _notifier.EmitWarning(warn.Rule, warn.Used, warn.Limit, periodStart);
                return BudgetEnforcementOutcome.WarningEmitted;
            }

            case BudgetGateDecision.Block block:
                _notifier.EmitBlock(block.Rule, block.Used, block.Limit);
                return BudgetEnforcementOutcome.BlockEmitted;

            case BudgetGateDecision.Allow:
            case BudgetGateDecision.Paused:
            default:
                return BudgetEnforcementOutcome.None;
        }
    }

    /// <summary>Clear the warning debounce when a period rolls over. Mirrors <c>resetWarningDebounce</c>.</summary>
    public void ResetWarningDebounce() => _warningSeen.Clear();

    private static string WarningKey(BudgetRule rule, DateTimeOffset? periodStart)
    {
        double stamp = periodStart is DateTimeOffset start
            ? start.ToUnixTimeMilliseconds() / 1000.0
            : 0;
        return string.Format(CultureInfo.InvariantCulture, "{0}#{1}", rule.Id, stamp);
    }
}

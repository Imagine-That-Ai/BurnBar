using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED (faithful) from AgentLens/Services/DataStore/BudgetGate.swift — the single decision
// this whole surface exists to make. The port preserves the hardened FAIL-CLOSED contract:
// a failed ledger read means current spend is UNKNOWN, so block-capable rules block and the
// contractually non-blocking .warnOnly rule surfaces a warning — an unreadable ledger can
// never silently let a possibly-over-budget request through (the old `(try? …) ?? 0`
// fail-OPEN bug). Pure + deterministic; unit-tested on macOS in windows/tests/presentation.

/// <summary>
/// The gate's outcome. Pure data — callers translate into HTTP 402 / a chat error card / a
/// header attachment. Mirrors the Swift <c>BudgetGateDecision</c> enum-with-payloads; modeled
/// as a sealed record hierarchy so tests get value equality.
/// </summary>
public abstract record BudgetGateDecision
{
    private BudgetGateDecision()
    {
    }

    /// <summary>Request flows through with no gate intervention.</summary>
    public sealed record Allow : BudgetGateDecision
    {
        public static Allow Instance { get; } = new();
    }

    /// <summary>Pass-through, but a chip/header should surface "you're at N% of {rule}".</summary>
    public sealed record Warn(BudgetRule Rule, double UsedPercent, double Used, double Limit) : BudgetGateDecision;

    /// <summary>Hard block. <see cref="Fallback"/> is the next credential for block+failover rules.</summary>
    public sealed record Block(BudgetRule Rule, double Used, double Limit, BudgetCredentialIdentity? Fallback)
        : BudgetGateDecision;

    /// <summary>Enforcement-eligible but currently paused — treated as allow but surfaced.</summary>
    public sealed record Paused(BudgetRule Rule, DateTimeOffset ResumeAt) : BudgetGateDecision;
}

/// <summary>
/// The slice of the budget-rule store the gate reads. Extracted so the gate runs against
/// in-memory fakes (and so any store — SQLite, cloud — can back it). Mirrors Swift
/// <c>BudgetRuleProviding</c>.
/// </summary>
public interface IBudgetRuleProvider
{
    IReadOnlyList<BudgetRule> Rules { get; }
    IReadOnlyList<BudgetRule> GlobalRules { get; }
    IReadOnlyList<BudgetRule> RulesForCredential(string providerId, string? accountId);
    IReadOnlyList<BudgetRule> RulesForProject(string projectName);
}

/// <summary>
/// The single ledger read the gate performs per rule. Extracted so tests can inject a ledger
/// that throws on demand — the failure path is the whole point of the gate. Mirrors Swift
/// <c>BudgetLedgerReading</c>.
/// </summary>
public interface IBudgetLedgerReading
{
    /// <summary>Accumulated USD spend attributed to the rule's scope within its current period.</summary>
    Task<double> CurrentSpendAsync(BudgetRule rule, DateTimeOffset reference, CancellationToken cancellationToken = default);
}

/// <summary>
/// Pure gate decisioning over an <see cref="IBudgetRuleProvider"/> + an
/// <see cref="IBudgetLedgerReading"/>. Stateless apart from its two collaborators. Faithful
/// port of the Swift <c>BudgetGate</c>.
/// </summary>
public sealed class BudgetGate
{
    private readonly IBudgetRuleProvider _rules;
    private readonly IBudgetLedgerReading _ledger;
    private readonly double _warningThreshold;

    public BudgetGate(IBudgetRuleProvider rules, IBudgetLedgerReading ledger, double warningThreshold = 0.8)
    {
        _rules = rules ?? throw new ArgumentNullException(nameof(rules));
        _ledger = ledger ?? throw new ArgumentNullException(nameof(ledger));
        _warningThreshold = warningThreshold;
    }

    /// <summary>
    /// Returns the most restrictive decision across every rule matching the credential
    /// (credential-scope + visible project-scope + global). Subscription credentials
    /// short-circuit to <see cref="BudgetGateDecision.Allow"/> BEFORE any query runs, so a
    /// Claude Pro OAuth key never gets gated.
    /// </summary>
    public async Task<BudgetGateDecision> EvaluateAsync(
        BudgetCredentialIdentity credential,
        double estimatedCost,
        string? projectName = null,
        DateTimeOffset? reference = null,
        CancellationToken cancellationToken = default)
    {
        if (credential.BillingMode == BudgetBillingMode.Subscription)
        {
            return BudgetGateDecision.Allow.Instance;
        }

        DateTimeOffset at = reference ?? DateTimeOffset.UtcNow;
        IReadOnlyList<BudgetRule> candidates = MatchingRules(credential, projectName);
        if (candidates.Count == 0)
        {
            return BudgetGateDecision.Allow.Instance;
        }

        BudgetGateDecision worst = BudgetGateDecision.Allow.Instance;
        foreach (BudgetRule rule in candidates)
        {
            if (rule.IsPaused(at))
            {
                if (rule.PausedUntil is DateTimeOffset until)
                {
                    worst = PickMoreRestrictive(worst, new BudgetGateDecision.Paused(rule, until));
                }

                continue;
            }

            BudgetGateDecision decision;
            try
            {
                double used = await _ledger.CurrentSpendAsync(rule, at, cancellationToken).ConfigureAwait(false);
                double projected = used + Math.Max(0, estimatedCost);
                decision = Classify(rule, used, projected);
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                // FAIL CLOSED. A failed ledger read means current spend is UNKNOWN. Reject
                // (or, for warn-only rules, warn) rather than coercing the unknown to $0 and
                // letting a possibly-over-budget request through.
                decision = FailClosedDecision(rule);
            }

            worst = PickMoreRestrictive(worst, decision);
        }

        return worst;
    }

    /// <summary>Active rules matching the credential/project, in descending strictness order.</summary>
    private IReadOnlyList<BudgetRule> MatchingRules(BudgetCredentialIdentity credential, string? projectName)
    {
        var rules = new List<BudgetRule>();
        rules.AddRange(_rules.RulesForCredential(credential.ProviderId, credential.SlotId));
        if (!string.IsNullOrEmpty(projectName))
        {
            rules.AddRange(_rules.RulesForProject(projectName!));
        }

        rules.AddRange(_rules.GlobalRules);

        var active = new List<BudgetRule>(rules.Count);
        foreach (BudgetRule rule in rules)
        {
            if (rule.IsEnabled && rule.AmountUsd > 0)
            {
                active.Add(rule);
            }
        }

        return active;
    }

    /// <summary>
    /// The decision to return when the ledger read fails and current spend is unknown.
    /// Block-capable behaviors fail closed to <see cref="BudgetGateDecision.Block"/>;
    /// <see cref="BudgetBehavior.WarnOnly"/> is contractually non-blocking so it fails to
    /// <see cref="BudgetGateDecision.Warn"/> (the read failure is still surfaced, never
    /// silently allowed).
    /// </summary>
    private static BudgetGateDecision FailClosedDecision(BudgetRule rule)
    {
        double limit = rule.AmountUsd;
        return rule.Behavior switch
        {
            BudgetBehavior.WarnOnly => new BudgetGateDecision.Warn(rule, 1.0, limit, limit),
            _ => new BudgetGateDecision.Block(rule, limit, limit, null),
        };
    }

    private BudgetGateDecision Classify(BudgetRule rule, double used, double projected)
    {
        double limit = rule.AmountUsd;
        double projectedPercent = limit > 0 ? projected / limit : 0;
        double usedPercent = limit > 0 ? used / limit : 0;

        switch (rule.Behavior)
        {
            case BudgetBehavior.WarnOnly:
                if (projectedPercent >= _warningThreshold)
                {
                    return new BudgetGateDecision.Warn(rule, usedPercent, used, limit);
                }

                return BudgetGateDecision.Allow.Instance;

            case BudgetBehavior.WarnThenBlock:
                if (projectedPercent >= 1.0)
                {
                    return new BudgetGateDecision.Block(rule, used, limit, null);
                }

                if (projectedPercent >= _warningThreshold)
                {
                    return new BudgetGateDecision.Warn(rule, usedPercent, used, limit);
                }

                return BudgetGateDecision.Allow.Instance;

            case BudgetBehavior.HardBlock:
                if (projectedPercent >= 1.0)
                {
                    return new BudgetGateDecision.Block(rule, used, limit, null);
                }

                return BudgetGateDecision.Allow.Instance;

            case BudgetBehavior.HardBlockWithFallback:
                if (projectedPercent >= 1.0)
                {
                    // Fallback resolution is a later wave — surface the intent, no candidate yet.
                    return new BudgetGateDecision.Block(rule, used, limit, null);
                }

                if (projectedPercent >= _warningThreshold)
                {
                    return new BudgetGateDecision.Warn(rule, usedPercent, used, limit);
                }

                return BudgetGateDecision.Allow.Instance;

            default:
                return BudgetGateDecision.Allow.Instance;
        }
    }

    /// <summary>All active rules (no ledger query) for a Hermes/context builder.</summary>
    public IReadOnlyList<BudgetRule> RulesForContext()
    {
        var active = new List<BudgetRule>();
        foreach (BudgetRule rule in _rules.Rules)
        {
            if (rule.IsEnabled && rule.AmountUsd > 0)
            {
                active.Add(rule);
            }
        }

        return active;
    }

    private static BudgetGateDecision PickMoreRestrictive(BudgetGateDecision lhs, BudgetGateDecision rhs) =>
        Priority(rhs) > Priority(lhs) ? rhs : lhs;

    /// <summary>Strictness order: allow &lt; paused &lt; warn &lt; block.</summary>
    private static int Priority(BudgetGateDecision decision) => decision switch
    {
        BudgetGateDecision.Allow => 0,
        BudgetGateDecision.Paused => 1,
        BudgetGateDecision.Warn => 2,
        BudgetGateDecision.Block => 3,
        _ => 0,
    };
}

// Composable scope predicate + pure matcher with deny-precedence.
//
// Port of ComputerUseScopeRule.swift. A rule is the conjunction of its three
// optional sub-predicates (URL prefix AND bundle/process id AND window-title
// regex). The rule set is a disjunction, with deny rules taking precedence over
// any allow, and — among rules of the same effect — the newest createdAt wins.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Scope;

/// <summary>Whether a rule grants or forbids the matched context.</summary>
public enum ScopeEffect
{
    Allow,
    Deny,
}

/// <summary>Provenance of a rule. Built-in denies cannot be edited or removed.</summary>
public enum ScopeOrigin
{
    BuiltIn,
    User,
    Imported,
}

/// <summary>Wire strings for the scope enums.</summary>
public static class ScopeEnumWire
{
    public static string ToWire(this ScopeEffect effect) => effect switch
    {
        ScopeEffect.Allow => "allow",
        ScopeEffect.Deny => "deny",
        _ => throw new ArgumentOutOfRangeException(nameof(effect), effect, null),
    };

    public static string ToWire(this ScopeOrigin origin) => origin switch
    {
        ScopeOrigin.BuiltIn => "built_in",
        ScopeOrigin.User => "user",
        ScopeOrigin.Imported => "imported",
        _ => throw new ArgumentOutOfRangeException(nameof(origin), origin, null),
    };
}

/// <summary>A single scope predicate + its optional Trusted-mode budget/expiry.</summary>
public sealed class ScopeRule
{
    public ScopeRule(
        string id,
        ScopeEffect effect,
        ScopeOrigin origin,
        string label,
        string? urlPrefix = null,
        string? bundleId = null,
        string? windowTitleRegex = null,
        int? actionBudget = null,
        DateTimeOffset? expiresAt = null,
        DateTimeOffset? createdAt = null)
    {
        Id = id ?? throw new ArgumentNullException(nameof(id));
        Effect = effect;
        Origin = origin;
        Label = label ?? throw new ArgumentNullException(nameof(label));
        UrlPrefix = urlPrefix;
        BundleId = bundleId;
        WindowTitleRegex = windowTitleRegex;
        ActionBudget = actionBudget;
        ExpiresAt = expiresAt;
        CreatedAt = createdAt ?? DateTimeOffset.UtcNow;
    }

    public string Id { get; }

    public ScopeEffect Effect { get; }

    public ScopeOrigin Origin { get; }

    public string Label { get; }

    /// <summary>Case-insensitive URL prefix; a trailing <c>*</c> on the bundle id is a prefix match.</summary>
    public string? UrlPrefix { get; }

    public string? BundleId { get; }

    public string? WindowTitleRegex { get; }

    public int? ActionBudget { get; }

    public DateTimeOffset? ExpiresAt { get; }

    public DateTimeOffset CreatedAt { get; }

    /// <summary>Canonical-JSON map (audit-hasher form: ms-int dates, omitted nulls).</summary>
    public CanonicalJsonObject ToCanonicalMap()
    {
        return new CanonicalJsonObject()
            .Set("id", Id)
            .Set("effect", Effect.ToWire())
            .Set("origin", Origin.ToWire())
            .Set("label", Label)
            .Set("urlPrefix", UrlPrefix)
            .Set("bundleId", BundleId)
            .Set("windowTitleRegex", WindowTitleRegex)
            .Set("actionBudget", ActionBudget.HasValue ? ActionBudget.Value : (object?)null)
            .Set("expiresAt", ExpiresAt.HasValue ? ToMillis(ExpiresAt.Value) : (object?)null)
            .Set("createdAt", ToMillis(CreatedAt));
    }

    internal static long ToMillis(DateTimeOffset value) => value.ToUnixTimeMilliseconds();
}

/// <summary>Live action context evaluated against the rule set.</summary>
public sealed class ScopeContext
{
    public ScopeContext(string? url = null, string? bundleId = null, string? windowTitle = null)
    {
        Url = url;
        BundleId = bundleId;
        WindowTitle = windowTitle;
    }

    public string? Url { get; }

    public string? BundleId { get; }

    public string? WindowTitle { get; }
}

/// <summary>Outcome of evaluating the rule set against a context.</summary>
public readonly struct ScopeOutcome : IEquatable<ScopeOutcome>
{
    public enum Kind
    {
        Allowed,
        Denied,
        NotMatched,
    }

    private ScopeOutcome(Kind result, string? ruleId)
    {
        Result = result;
        RuleId = ruleId;
    }

    public Kind Result { get; }

    public string? RuleId { get; }

    public static ScopeOutcome Allowed(string ruleId) => new(Kind.Allowed, ruleId);

    public static ScopeOutcome Denied(string ruleId) => new(Kind.Denied, ruleId);

    public static ScopeOutcome NotMatched { get; } = new(Kind.NotMatched, null);

    public bool Equals(ScopeOutcome other) => Result == other.Result && RuleId == other.RuleId;

    public override bool Equals(object? obj) => obj is ScopeOutcome other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(Result, RuleId);
}

/// <summary>Live budget counters attached to a Trusted-mode rule.</summary>
public sealed class ScopeBudgetState
{
    public ScopeBudgetState(string ruleId, int actionsConsumed = 0, DateTimeOffset? firstActionAt = null)
    {
        RuleId = ruleId;
        ActionsConsumed = actionsConsumed;
        FirstActionAt = firstActionAt;
    }

    public string RuleId { get; }

    public int ActionsConsumed { get; }

    public DateTimeOffset? FirstActionAt { get; }

    /// <summary>True once wall-clock expiry or the action budget is exhausted.</summary>
    public bool IsExhausted(ScopeRule rule, DateTimeOffset now)
    {
        if (rule.ExpiresAt is { } expiry && expiry <= now)
        {
            return true;
        }

        if (rule.ActionBudget is { } budget && ActionsConsumed >= budget)
        {
            return true;
        }

        return false;
    }
}

/// <summary>Pure rule-set matcher with deny-precedence and newest-wins tie-breaking.</summary>
public sealed class ScopeMatcher
{
    public ScopeOutcome Evaluate(
        IReadOnlyList<ScopeRule> rules,
        ScopeContext context,
        DateTimeOffset now,
        IReadOnlyDictionary<string, ScopeBudgetState>? budgetStates = null)
    {
        var active = new List<ScopeRule>();
        foreach (var rule in rules)
        {
            if (rule.ExpiresAt is { } expiry && expiry <= now)
            {
                continue;
            }

            if (budgetStates is not null
                && budgetStates.TryGetValue(rule.Id, out var state)
                && state.IsExhausted(rule, now))
            {
                continue;
            }

            if (Matches(rule, context))
            {
                active.Add(rule);
            }
        }

        if (active.Count == 0)
        {
            return ScopeOutcome.NotMatched;
        }

        ScopeRule? mostRecentDeny = null;
        ScopeRule? mostRecentAllow = null;
        foreach (var rule in active)
        {
            if (rule.Effect == ScopeEffect.Deny)
            {
                if (mostRecentDeny is null || rule.CreatedAt > mostRecentDeny.CreatedAt)
                {
                    mostRecentDeny = rule;
                }
            }
            else if (mostRecentAllow is null || rule.CreatedAt > mostRecentAllow.CreatedAt)
            {
                mostRecentAllow = rule;
            }
        }

        if (mostRecentDeny is not null)
        {
            return ScopeOutcome.Denied(mostRecentDeny.Id);
        }

        return mostRecentAllow is not null
            ? ScopeOutcome.Allowed(mostRecentAllow.Id)
            : ScopeOutcome.NotMatched;
    }

    /// <summary>
    /// True iff <paramref name="proposed"/> (an allow rule) would weaken a built-in
    /// deny for at least one sample context — used by the editor to warn before a save.
    /// </summary>
    public bool OverlapsBuiltInDeny(
        ScopeRule proposed,
        IReadOnlyList<ScopeRule> builtInDenies,
        IReadOnlyList<ScopeContext> sampleContexts)
    {
        if (proposed.Effect != ScopeEffect.Allow)
        {
            return false;
        }

        foreach (var context in sampleContexts)
        {
            if (!Matches(proposed, context))
            {
                continue;
            }

            foreach (var deny in builtInDenies)
            {
                if (deny.Effect == ScopeEffect.Deny && Matches(deny, context))
                {
                    return true;
                }
            }
        }

        return false;
    }

    internal bool Matches(ScopeRule rule, ScopeContext context)
    {
        if (rule.UrlPrefix is { } prefix)
        {
            if (context.Url is null
                || !context.Url.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
        }

        if (rule.BundleId is { } bundleId)
        {
            if (context.BundleId is null)
            {
                return false;
            }

            if (bundleId.EndsWith("*", StringComparison.Ordinal))
            {
                var bundlePrefix = bundleId[..^1];
                if (!context.BundleId.StartsWith(bundlePrefix, StringComparison.Ordinal))
                {
                    return false;
                }
            }
            else if (!string.Equals(context.BundleId, bundleId, StringComparison.Ordinal))
            {
                return false;
            }
        }

        if (rule.WindowTitleRegex is { } regex)
        {
            if (context.WindowTitle is null)
            {
                return false;
            }

            try
            {
                // Unanchored, case-insensitive — matches the pattern anywhere in the title.
                if (!Regex.IsMatch(
                        context.WindowTitle,
                        regex,
                        RegexOptions.IgnoreCase,
                        TimeSpan.FromSeconds(1)))
                {
                    return false;
                }
            }
            catch (ArgumentException)
            {
                return false;
            }
            catch (RegexMatchTimeoutException)
            {
                return false;
            }
        }

        return true;
    }
}

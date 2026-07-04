using System;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED (faithful, scoped) from OpenBurnBarCore/.../SharedModels/BudgetRule.swift.
// The enums, the BudgetRule record, and the period window/reset math are the pure,
// storage-agnostic half of the Budget surface. The SAME managed assembly is referenced
// by the WinUI app (whose XAML x:Binds to the view-models built on these types) AND is
// unit-tested on the macOS authoring host via `dotnet test` (windows/tests/presentation).
//
// The enum RAW-VALUE strings are kept byte-identical to the Swift `String`-backed enums
// so a future SQLCipher `budget_rules` table stays cross-platform readable (the storage
// seam lands in a later wave); BudgetEnumRaw round-trips them.

/// <summary>Where a budget rule applies. Mirrors Swift <c>BudgetRuleScope</c>.</summary>
public enum BudgetRuleScope
{
    /// <summary>Limit on a specific <c>(providerID, accountID)</c> credential.</summary>
    Credential,

    /// <summary>Limit on a specific free-text project name.</summary>
    Project,

    /// <summary>Single ceiling across every per-usage credential.</summary>
    Global,

    /// <summary>Org-wide rule synced via the cloud (enforced locally per seat).</summary>
    Organization,
}

/// <summary>Reset cadence for a rule's running spend. Mirrors Swift <c>BudgetPeriod</c>.</summary>
public enum BudgetPeriod
{
    Day,
    Week,
    Month,
    AllTime,
}

/// <summary>What the gate does when a rule's running spend meets/exceeds its limit.</summary>
public enum BudgetBehavior
{
    /// <summary>Warn at the threshold (default 80%), hard-block at 100%.</summary>
    WarnThenBlock,

    /// <summary>Block immediately at 100% with no warning grace period.</summary>
    HardBlock,

    /// <summary>Fire threshold/limit notifications but always let the request through.</summary>
    WarnOnly,

    /// <summary>Hard-block at 100% AND promote the configured fallback credential(s).</summary>
    HardBlockWithFallback,
}

/// <summary>Whether the charged credential costs marginal $ or runs on a flat-rate plan.</summary>
public enum BudgetBillingMode
{
    PerUsage,
    Subscription,
    Unknown,
}

/// <summary>
/// Byte-for-byte parity with the Swift <c>rawValue</c> strings so the persisted
/// <c>budget_rules</c> / <c>budget_audit</c> rows stay cross-platform readable.
/// </summary>
public static class BudgetEnumRaw
{
    public static string Raw(this BudgetRuleScope scope) => scope switch
    {
        BudgetRuleScope.Credential => "credential",
        BudgetRuleScope.Project => "project",
        BudgetRuleScope.Global => "global",
        BudgetRuleScope.Organization => "organization",
        _ => "global",
    };

    public static string Raw(this BudgetPeriod period) => period switch
    {
        BudgetPeriod.Day => "day",
        BudgetPeriod.Week => "week",
        BudgetPeriod.Month => "month",
        BudgetPeriod.AllTime => "allTime",
        _ => "month",
    };

    public static string Raw(this BudgetBehavior behavior) => behavior switch
    {
        BudgetBehavior.WarnThenBlock => "warnThenBlock",
        BudgetBehavior.HardBlock => "hardBlock",
        BudgetBehavior.WarnOnly => "warnOnly",
        BudgetBehavior.HardBlockWithFallback => "hardBlockWithFallback",
        _ => "warnThenBlock",
    };

    public static string Raw(this BudgetBillingMode mode) => mode switch
    {
        BudgetBillingMode.PerUsage => "perUsage",
        BudgetBillingMode.Subscription => "subscription",
        BudgetBillingMode.Unknown => "unknown",
        _ => "unknown",
    };

    public static BudgetRuleScope ParseScope(string raw) => raw switch
    {
        "credential" => BudgetRuleScope.Credential,
        "project" => BudgetRuleScope.Project,
        "global" => BudgetRuleScope.Global,
        "organization" => BudgetRuleScope.Organization,
        _ => BudgetRuleScope.Global,
    };

    public static BudgetPeriod ParsePeriod(string raw) => raw switch
    {
        "day" => BudgetPeriod.Day,
        "week" => BudgetPeriod.Week,
        "month" => BudgetPeriod.Month,
        "allTime" => BudgetPeriod.AllTime,
        _ => BudgetPeriod.Month,
    };

    public static BudgetBehavior ParseBehavior(string raw) => raw switch
    {
        "warnThenBlock" => BudgetBehavior.WarnThenBlock,
        "hardBlock" => BudgetBehavior.HardBlock,
        "warnOnly" => BudgetBehavior.WarnOnly,
        "hardBlockWithFallback" => BudgetBehavior.HardBlockWithFallback,
        _ => BudgetBehavior.WarnThenBlock,
    };
}

/// <summary>
/// Window/reset arithmetic for a <see cref="BudgetPeriod"/>. Mirrors the Swift
/// <c>BudgetPeriod.windowStart</c> / <c>nextReset</c> that <c>BudgetLedger</c> uses to slice
/// <c>token_usage</c>. Deterministic (no ambient <c>Calendar.current</c>): the reference's own
/// UTC offset is preserved and the week start day is explicit (default Sunday, matching the
/// US-locale Gregorian calendar the Swift path resolves to).
/// </summary>
public sealed class BudgetClock
{
    private readonly DayOfWeek _firstDayOfWeek;

    public BudgetClock(DayOfWeek firstDayOfWeek = DayOfWeek.Sunday)
    {
        _firstDayOfWeek = firstDayOfWeek;
    }

    public static BudgetClock Default { get; } = new();

    /// <summary>Inclusive lower bound (start of the current window). <c>null</c> for all-time.</summary>
    public DateTimeOffset? WindowStart(BudgetPeriod period, DateTimeOffset reference)
    {
        switch (period)
        {
            case BudgetPeriod.Day:
                return StartOfDay(reference);
            case BudgetPeriod.Week:
                return StartOfWeek(reference);
            case BudgetPeriod.Month:
                return StartOfMonth(reference);
            case BudgetPeriod.AllTime:
            default:
                return null;
        }
    }

    /// <summary>Next reset boundary (when the running total resets). <c>null</c> for all-time.</summary>
    public DateTimeOffset? NextReset(BudgetPeriod period, DateTimeOffset reference)
    {
        switch (period)
        {
            case BudgetPeriod.Day:
                return StartOfDay(reference).AddDays(1);
            case BudgetPeriod.Week:
                return StartOfWeek(reference).AddDays(7);
            case BudgetPeriod.Month:
                return StartOfMonth(reference).AddMonths(1);
            case BudgetPeriod.AllTime:
            default:
                return null;
        }
    }

    private static DateTimeOffset StartOfDay(DateTimeOffset reference) =>
        new(reference.Year, reference.Month, reference.Day, 0, 0, 0, reference.Offset);

    private DateTimeOffset StartOfWeek(DateTimeOffset reference)
    {
        DateTimeOffset day = StartOfDay(reference);
        int delta = ((int)day.DayOfWeek - (int)_firstDayOfWeek + 7) % 7;
        return day.AddDays(-delta);
    }

    private static DateTimeOffset StartOfMonth(DateTimeOffset reference) =>
        new(reference.Year, reference.Month, 1, 0, 0, 0, reference.Offset);
}

/// <summary>
/// User-configured spending limit. Faithful port of the Swift <c>BudgetRule</c> value type
/// (a <c>record</c> here so the WinUI editor mutates a copy with <c>with { }</c> and tests get
/// value equality). Persisted in <c>budget_rules</c> in a later storage wave.
/// </summary>
public sealed record BudgetRule
{
    public string Id { get; init; } = Guid.NewGuid().ToString();
    public BudgetRuleScope Scope { get; init; }
    public string? Identifier { get; init; }
    public string? ProviderId { get; init; }
    public string? AccountId { get; init; }
    public string? ProjectName { get; init; }
    public string? Label { get; init; }

    /// <summary>Spending ceiling in USD.</summary>
    public double AmountUsd { get; init; }

    public BudgetPeriod Period { get; init; } = BudgetPeriod.Month;
    public BudgetBehavior Behavior { get; init; } = BudgetBehavior.WarnThenBlock;

    /// <summary>Ordered credential rule IDs to promote when this rule blocks (fallback only).</summary>
    public System.Collections.Generic.IReadOnlyList<string> FallbackCredentialIds { get; init; } =
        Array.Empty<string>();

    /// <summary>When non-null and in the future, the gate short-circuits this rule to allow.</summary>
    public DateTimeOffset? PausedUntil { get; init; }

    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? SyncedAt { get; init; }
    public string? SourceDeviceId { get; init; }
    public bool IsEnabled { get; init; } = true;

    /// <summary>Human-facing label; synthesizes one when <see cref="Label"/> is empty.</summary>
    public string DisplayLabel
    {
        get
        {
            if (!string.IsNullOrEmpty(Label))
            {
                return Label!;
            }

            switch (Scope)
            {
                case BudgetRuleScope.Credential:
                    string providerName = string.IsNullOrEmpty(ProviderId) ? "credential" : ProviderId!;
                    if (!string.IsNullOrEmpty(AccountId))
                    {
                        string tail = AccountId!.Length <= 6 ? AccountId! : AccountId!.Substring(AccountId!.Length - 6);
                        return $"{providerName} · …{tail}";
                    }

                    return $"{providerName} · default";
                case BudgetRuleScope.Project:
                    return string.IsNullOrEmpty(ProjectName) ? "Unnamed project" : ProjectName!;
                case BudgetRuleScope.Global:
                    return "All per-usage credentials";
                case BudgetRuleScope.Organization:
                    return string.IsNullOrEmpty(Identifier) ? "Organization" : Identifier!;
                default:
                    return "Budget rule";
            }
        }
    }

    /// <summary>True when <see cref="PausedUntil"/> is set and still in the future.</summary>
    public bool IsPaused(DateTimeOffset reference) => PausedUntil is DateTimeOffset until && until > reference;
}

using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Quota;

// PORTED (faithful) from the macOS provider-quota domain model:
//   AgentLens/Services/ProviderQuota/ProviderQuotaTypes.swift
//     • enum ProviderQuotaSourceKind / ProviderQuotaConfidence / ProviderQuotaUnit
//       / ProviderQuotaWindowKind
//     • struct ProviderQuotaBucket  (usedValue / limitValue / remainingValue /
//       usedPercent / resetsAt / unit + the remainingPercent + progressFraction
//       derivations)
//     • struct ProviderQuotaSnapshot (provider token, source, confidence,
//       managementURL, statusMessage, buckets)
//
// This is the DEPENDENCY-FREE target shape every Windows quota adapter parses
// into. Only the pieces the four portable parse mechanisms produce and that the
// tests assert are ported; the reactive Firestore/Codable envelope, the
// per-provider primary-bucket ordering, and the reset-reconciliation clock are
// macOS-app concerns and stay on that side.
//
// `provider` is modelled as the Swift `AgentProvider.rawValue` token string
// ("claudeCode" / "cursor" / "codex") rather than re-porting the whole
// AgentProvider enum — the parse mechanisms only stamp a fixed token per adapter.

/// <summary>How a quota snapshot was obtained. Swift: <c>enum ProviderQuotaSourceKind</c>.</summary>
public enum ProviderQuotaSourceKind
{
    /// <summary>Swift raw value <c>officialAPI</c>.</summary>
    OfficialApi,

    /// <summary>Swift raw value <c>localCLI</c>.</summary>
    LocalCli,

    /// <summary>Swift raw value <c>localSession</c>.</summary>
    LocalSession,

    /// <summary>Swift raw value <c>manualEstimate</c>.</summary>
    ManualEstimate,

    /// <summary>Swift raw value <c>unavailable</c>.</summary>
    Unavailable,
}

/// <summary>Confidence in a snapshot. Swift: <c>enum ProviderQuotaConfidence</c>.</summary>
public enum ProviderQuotaConfidence
{
    Exact,
    Estimated,
    Unavailable,
}

/// <summary>The unit a bucket's numbers are expressed in. Swift: <c>enum ProviderQuotaUnit</c>.</summary>
public enum ProviderQuotaUnit
{
    Percent,
    Requests,
    Tokens,
    Sessions,
    Lines,
    Files,
    Count,

    /// <summary>USD dollars (Swift <c>currency</c> — Cursor cents ÷ 100).</summary>
    Currency,
}

/// <summary>The reset window a bucket tracks. Swift: <c>enum ProviderQuotaWindowKind</c>.</summary>
public enum ProviderQuotaWindowKind
{
    RollingHours,
    RollingDays,
    Daily,
    Weekly,
    Monthly,
    Lifetime,
    Custom,
}

/// <summary>
/// One quota window of a provider. Faithful port of the Swift
/// <c>struct ProviderQuotaBucket</c> — the field set the parsers populate plus
/// the <see cref="RemainingPercent"/> and <see cref="ProgressFraction"/>
/// derivations the views drive their gauges from.
/// </summary>
public sealed record ProviderQuotaBucket
{
    /// <summary>Stable identifier (Swift <c>key</c>; also the bucket's <c>id</c>).</summary>
    public required string Key { get; init; }

    /// <summary>Human window label (Swift <c>label</c>).</summary>
    public required string Label { get; init; }

    /// <summary>Reset cadence (Swift <c>windowKind</c>).</summary>
    public required ProviderQuotaWindowKind WindowKind { get; init; }

    /// <summary>Consumed amount in <see cref="Unit"/> (Swift <c>usedValue</c>).</summary>
    public double? UsedValue { get; init; }

    /// <summary>Cap in <see cref="Unit"/> (Swift <c>limitValue</c>).</summary>
    public double? LimitValue { get; init; }

    /// <summary>Headroom in <see cref="Unit"/> (Swift <c>remainingValue</c>).</summary>
    public double? RemainingValue { get; init; }

    /// <summary>Percent consumed, when the provider reports it (Swift <c>usedPercent</c>).</summary>
    public double? UsedPercent { get; init; }

    /// <summary>Absolute reset instant (Swift <c>resetsAt</c>).</summary>
    public DateTimeOffset? ResetsAt { get; init; }

    /// <summary>Unit the numbers are in (Swift <c>unit</c>).</summary>
    public required ProviderQuotaUnit Unit { get; init; }

    /// <summary>Whether the numbers are inferred rather than provider-reported (Swift <c>isEstimated</c>).</summary>
    public bool IsEstimated { get; init; }

    /// <summary>Swift <c>ProviderQuotaBucket.id</c> — the key.</summary>
    public string Id => Key;

    /// <summary>
    /// Percent of the window still available, prioritising <c>usedPercent</c> exactly like
    /// the Swift <c>remainingPercent</c> computed property.
    /// </summary>
    public double? RemainingPercent
    {
        get
        {
            if (UsedPercent is double usedPercent)
            {
                return Math.Max(0, Math.Min(100 - usedPercent, 100));
            }

            if (RemainingValue is double remainingValue && Unit == ProviderQuotaUnit.Percent)
            {
                return Math.Min(Math.Max(remainingValue, 0), 100);
            }

            if (RemainingValue is double remaining && LimitValue is double limit && limit > 0)
            {
                return Math.Min(Math.Max((remaining / limit) * 100, 0), 100);
            }

            return null;
        }
    }

    /// <summary>
    /// Fraction of the window consumed in <c>[0, 1]</c>. Mirrors the Swift
    /// <c>progressFraction</c> computed property (used → used/limit → 1 - remainingPercent).
    /// </summary>
    public double ProgressFraction
    {
        get
        {
            if (UsedPercent is double usedPercent)
            {
                return Math.Min(Math.Max(usedPercent / 100, 0), 1);
            }

            if (UsedValue is double usedValue && LimitValue is double limit && limit > 0)
            {
                return Math.Min(Math.Max(usedValue / limit, 0), 1);
            }

            if (RemainingPercent is double remainingPercent)
            {
                return Math.Min(Math.Max((100 - remainingPercent) / 100, 0), 1);
            }

            return 0;
        }
    }
}

/// <summary>
/// A provider's quota reading. Faithful port of the fields the four portable
/// parse mechanisms stamp on the Swift <c>struct ProviderQuotaSnapshot</c>.
/// </summary>
public sealed record ProviderQuotaSnapshot
{
    /// <summary>The <c>AgentProvider.rawValue</c> token the adapter stamps.</summary>
    public required string Provider { get; init; }

    /// <summary>When the reading was captured (Swift <c>fetchedAt</c>).</summary>
    public required DateTimeOffset FetchedAt { get; init; }

    /// <summary>How the reading was obtained (Swift <c>source</c>).</summary>
    public required ProviderQuotaSourceKind Source { get; init; }

    /// <summary>Confidence in the reading (Swift <c>confidence</c>).</summary>
    public required ProviderQuotaConfidence Confidence { get; init; }

    /// <summary>Deep-link to the provider's dashboard (Swift <c>managementURL</c>).</summary>
    public string? ManagementUrl { get; init; }

    /// <summary>Operator-facing status line (Swift <c>statusMessage</c>).</summary>
    public required string StatusMessage { get; init; }

    /// <summary>The parsed windows (Swift <c>buckets</c>).</summary>
    public required IReadOnlyList<ProviderQuotaBucket> Buckets { get; init; }

    /// <summary>Convenience empty bucket list used by the "unavailable" snapshots.</summary>
    public static IReadOnlyList<ProviderQuotaBucket> NoBuckets { get; } =
        Array.Empty<ProviderQuotaBucket>();

    /// <summary>Whether any bucket was parsed (Swift adapters gate the exact snapshot on this).</summary>
    public bool HasBuckets => Buckets.Count > 0;
}

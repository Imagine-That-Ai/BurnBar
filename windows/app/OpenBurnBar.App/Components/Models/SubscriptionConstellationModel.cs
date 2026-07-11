// PORTED (faithful, parity-with-Swift) from the Subscription Vault constellation + its filter flow:
//   AgentLens/Views/Dashboard/Quota/SubscriptionConstellationHero.swift
//     — providerChipEntries (one orb per provider = worst-pressured account), SubscriptionOrb
//       .remainingFraction / .ringColor bands, headlineText / eyebrowText
//   AgentLens/Views/Dashboard/Quota/QuotaWorkspaceView.swift
//     — displayedEntries (orb-tap provider focus) + the onOrbTap toggle
//   AgentLens/Views/Dashboard/Quota/QuotaWorkspaceViewModel.swift
//     — SubscriptionEntry.remainingPercentRounded/Text + AggregateSummary + aggregate(_:)
//
// This is the pure, platform-agnostic model for the WinUI Quota/SubscriptionConstellationHero +
// Quota/SubscriptionOrb: it derives one orb per provider, resolves the orb ring band (dashed-muted
// when a provider has no displayable signal), toggles + propagates the selected-provider filter to
// every downstream surface, and rolls the visible entries into the aggregate summary + hero copy.
// It targets `System` only (no WinUI), so it compiles + runs on macOS and is asserted by
// windows/tests/components/SubscriptionConstellationModelTests.cs against Swift golden values.

using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Components;

/// <summary>
/// One tracked subscription account. Lightweight port of the fields the constellation + workspace
/// filter read from the macOS <c>SubscriptionEntry</c>. <see cref="Pressure"/> is 0…1 (0 = wide open,
/// 1 = exhausted); <see cref="HasDisplayableBucket"/> mirrors <c>primaryDisplayableBucket != nil</c>.
/// </summary>
public sealed class SubscriptionEntry
{
    public SubscriptionEntry(
        string id,
        AgentProviderBrand provider,
        string accountLabel,
        double pressure,
        bool hasDisplayableBucket = true,
        DateTimeOffset? nextResetDate = null,
        DateTimeOffset? fetchedAt = null,
        bool isRefreshing = false)
    {
        Id = id ?? string.Empty;
        Provider = provider;
        AccountLabel = accountLabel ?? string.Empty;
        Pressure = Math.Clamp(pressure, 0, 1);
        HasDisplayableBucket = hasDisplayableBucket;
        NextResetDate = nextResetDate;
        FetchedAt = fetchedAt;
        IsRefreshing = isRefreshing;
    }

    public string Id { get; }
    public AgentProviderBrand Provider { get; }
    public string AccountLabel { get; }
    public double Pressure { get; }
    public bool HasDisplayableBucket { get; }
    public DateTimeOffset? NextResetDate { get; }
    public DateTimeOffset? FetchedAt { get; }
    public bool IsRefreshing { get; }

    /// <summary>Provider label. Swift: <c>provider.displayName</c>.</summary>
    public string DisplayName => ProviderMetadata.DisplayName(Provider);

    /// <summary>Remaining reserve fraction. Swift: <c>SubscriptionOrb.remainingFraction</c>
    /// (<c>max(0, min(1, 1 - pressure))</c>, or 0 when no displayable bucket).</summary>
    public double RemainingFraction => HasDisplayableBucket ? Math.Clamp(1 - Pressure, 0, 1) : 0;

    /// <summary>Swift: <c>SubscriptionEntry.remainingPercentRounded</c>.</summary>
    public int RemainingPercentRounded =>
        HasDisplayableBucket
            ? (int)Math.Round(Math.Clamp(1 - Pressure, 0, 1) * 100, MidpointRounding.AwayFromZero)
            : 0;

    /// <summary>Swift: <c>SubscriptionEntry.remainingPercentText</c> (em-dash when no bucket).</summary>
    public string RemainingPercentText => HasDisplayableBucket ? $"{RemainingPercentRounded}%" : "—";
}

/// <summary>Resolved orb ring appearance. Swift: <c>SubscriptionOrb.ringColor</c> — a missing
/// bucket paints the ring muted; otherwise the remaining fraction picks a pressure band.</summary>
public readonly record struct SubscriptionOrbRing(bool IsMuted, QuotaFillBand Band, double RemainingFraction)
{
    public static SubscriptionOrbRing From(SubscriptionEntry entry) =>
        entry.HasDisplayableBucket
            ? new SubscriptionOrbRing(false, QuotaFill.Band(entry.RemainingFraction), entry.RemainingFraction)
            : new SubscriptionOrbRing(true, QuotaFillBand.Edge, 0);
}

/// <summary>Aggregate readout over a set of entries. Swift: <c>QuotaWorkspaceViewModel.AggregateSummary</c>.</summary>
public sealed class AggregateSummary
{
    public AggregateSummary(
        int activeCount,
        int wideOpenCount,
        int narrowingCount,
        int nearEdgeCount,
        SubscriptionEntry? nextResetEntry,
        DateTimeOffset? lastSync)
    {
        ActiveCount = activeCount;
        WideOpenCount = wideOpenCount;
        NarrowingCount = narrowingCount;
        NearEdgeCount = nearEdgeCount;
        NextResetEntry = nextResetEntry;
        LastSync = lastSync;
    }

    public int ActiveCount { get; }
    public int WideOpenCount { get; }
    public int NarrowingCount { get; }
    public int NearEdgeCount { get; }
    public SubscriptionEntry? NextResetEntry { get; }
    public DateTimeOffset? LastSync { get; }
}

/// <summary>Pure derivations for the constellation hero + the workspace provider filter.</summary>
public static class SubscriptionConstellation
{
    /// <summary>
    /// One orb per provider, each representing that provider's WORST-pressured account so the
    /// constellation telegraphs true footprint health. Sorted pressure-desc, then display-name-asc.
    /// Swift: <c>SubscriptionConstellationHero.providerChipEntries</c>.
    /// </summary>
    public static IReadOnlyList<SubscriptionEntry> ProviderChipEntries(IReadOnlyList<SubscriptionEntry> entries)
    {
        var byProvider = new Dictionary<AgentProviderBrand, SubscriptionEntry>();
        foreach (SubscriptionEntry entry in entries)
        {
            if (byProvider.TryGetValue(entry.Provider, out SubscriptionEntry? existing))
            {
                if (entry.Pressure > existing.Pressure)
                {
                    byProvider[entry.Provider] = entry;
                }
            }
            else
            {
                byProvider[entry.Provider] = entry;
            }
        }

        return byProvider.Values
            .OrderByDescending(e => e.Pressure)
            .ThenBy(e => e.DisplayName, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>Toggle the orb-driven provider focus: tapping the focused provider clears it,
    /// tapping another selects it. Swift: <c>QuotaWorkspaceView.onOrbTap</c>.</summary>
    public static AgentProviderBrand? ToggleSelection(AgentProviderBrand? current, AgentProviderBrand tapped) =>
        current == tapped ? null : tapped;

    /// <summary>The entries shown in the grid/atlas/summary, honoring the provider focus.
    /// Swift: <c>QuotaWorkspaceView.displayedEntries</c>.</summary>
    public static IReadOnlyList<SubscriptionEntry> DisplayedEntries(
        IReadOnlyList<SubscriptionEntry> entries,
        AgentProviderBrand? selected) =>
        selected is { } provider
            ? entries.Where(e => e.Provider == provider).ToList()
            : entries.ToList();

    /// <summary>Distinct provider count over the unfiltered set. Swift:
    /// <c>QuotaWorkspaceView.totalProviderCount</c>.</summary>
    public static int TotalProviderCount(IReadOnlyList<SubscriptionEntry> entries) =>
        entries.Select(e => e.Provider).Distinct().Count();

    /// <summary>
    /// Roll a set of entries into the aggregate summary. Swift: <c>QuotaWorkspaceViewModel.aggregate(_:)</c>.
    /// Pressure bands mirror the Swift <c>switch</c>: <c>&lt; 0.46</c> = wide, <c>&lt; 0.74</c> = narrowing,
    /// else near-edge.
    /// </summary>
    public static AggregateSummary Aggregate(IReadOnlyList<SubscriptionEntry> entries)
    {
        int wide = 0, narrow = 0, edge = 0;
        foreach (SubscriptionEntry entry in entries)
        {
            if (entry.Pressure < 0.46)
            {
                wide++;
            }
            else if (entry.Pressure < 0.74)
            {
                narrow++;
            }
            else
            {
                edge++;
            }
        }

        SubscriptionEntry? nextReset = entries
            .Where(e => e.NextResetDate is not null)
            .OrderBy(e => e.NextResetDate!.Value)
            .FirstOrDefault();

        DateTimeOffset? lastSync = entries
            .Where(e => e.FetchedAt is not null)
            .Select(e => e.FetchedAt!.Value)
            .DefaultIfEmpty()
            .Max();
        if (lastSync == default(DateTimeOffset))
        {
            lastSync = null;
        }

        return new AggregateSummary(entries.Count, wide, narrow, edge, nextReset, lastSync);
    }

    /// <summary>Eyebrow caption above the hero headline. Swift:
    /// <c>SubscriptionConstellationHero.eyebrowText</c>.</summary>
    public static string EyebrowText(AggregateSummary summary, AgentProviderBrand? selected)
    {
        int active = summary.ActiveCount;
        if (selected is { } provider)
        {
            string accounts = active == 1 ? "ACCOUNT" : "ACCOUNTS";
            return $"FOCUSED · {ProviderMetadata.DisplayName(provider).ToUpperInvariant()} · {active} ACTIVE {accounts}";
        }

        string plans = active == 1 ? "PLAN" : "PLANS";
        return $"SUBSCRIPTION VAULT · {active} ACTIVE {plans}";
    }

    /// <summary>The hero headline. Swift: <c>SubscriptionConstellationHero.headlineText</c>.</summary>
    public static string HeadlineText(AggregateSummary summary, AgentProviderBrand? selected)
    {
        int active = summary.ActiveCount;
        if (active <= 0)
        {
            return "Connect a plan to start tracking quota";
        }

        if (selected is { } provider)
        {
            string name = ProviderMetadata.DisplayName(provider);
            string accountWord = active == 1 ? "account" : "accounts";
            return summary.NearEdgeCount > 0
                ? $"{name} · {active} {accountWord} · {summary.NearEdgeCount} near the edge"
                : $"{name} · {active} {accountWord} tracked";
        }

        if (summary.NearEdgeCount > 0)
        {
            return $"{active} plan{(active == 1 ? "" : "s")} tracked · {summary.NearEdgeCount} near the edge";
        }

        if (summary.NarrowingCount > 0)
        {
            return $"{summary.WideOpenCount} of {active} plans wide open · {summary.NarrowingCount} narrowing";
        }

        return $"All {active} plan{(active == 1 ? "" : "s")} have headroom";
    }
}

using System;
using System.Collections.Generic;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Theme;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts the constellation + filter-propagation model against
/// SubscriptionConstellationHero.swift / QuotaWorkspaceView.swift / QuotaWorkspaceViewModel.swift.</summary>
public sealed class SubscriptionConstellationModelTests
{
    private static SubscriptionEntry Entry(
        AgentProviderBrand provider,
        double pressure,
        bool hasBucket = true,
        DateTimeOffset? nextReset = null,
        DateTimeOffset? fetchedAt = null,
        string? id = null) =>
        new(id ?? $"{provider}:{pressure}", provider, "account", pressure, hasBucket, nextReset, fetchedAt);

    // ── SubscriptionEntry readouts ─────────────────────────────────────────────────────────

    [Fact]
    public void Entry_remaining_from_pressure()
    {
        SubscriptionEntry e = Entry(AgentProviderBrand.Cursor, 0.2);
        Assert.Equal(0.8, e.RemainingFraction, 6);
        Assert.Equal(80, e.RemainingPercentRounded);
        Assert.Equal("80%", e.RemainingPercentText);
    }

    [Fact]
    public void Entry_without_bucket_reads_dash()
    {
        SubscriptionEntry e = Entry(AgentProviderBrand.Cursor, 0.4, hasBucket: false);
        Assert.Equal(0, e.RemainingFraction, 6);
        Assert.Equal(0, e.RemainingPercentRounded);
        Assert.Equal("—", e.RemainingPercentText);
    }

    // ── Orb ring (dashed-muted when no signal) ─────────────────────────────────────────────

    [Fact]
    public void OrbRing_bands_by_remaining()
    {
        Assert.Equal(QuotaFillBand.Wide, SubscriptionOrbRing.From(Entry(AgentProviderBrand.Cursor, 0.10)).Band);
        Assert.Equal(QuotaFillBand.Comfortable, SubscriptionOrbRing.From(Entry(AgentProviderBrand.Cursor, 0.40)).Band);
        Assert.Equal(QuotaFillBand.Narrowing, SubscriptionOrbRing.From(Entry(AgentProviderBrand.Cursor, 0.65)).Band);
        Assert.Equal(QuotaFillBand.Edge, SubscriptionOrbRing.From(Entry(AgentProviderBrand.Cursor, 0.90)).Band);
    }

    [Fact]
    public void OrbRing_muted_without_bucket()
    {
        SubscriptionOrbRing ring = SubscriptionOrbRing.From(Entry(AgentProviderBrand.Cursor, 0.3, hasBucket: false));
        Assert.True(ring.IsMuted);
        Assert.Equal(0, ring.RemainingFraction, 6);
    }

    // ── providerChipEntries: worst-pressure per provider, sorted ───────────────────────────

    [Fact]
    public void ProviderChipEntries_keeps_worst_pressure_per_provider_sorted()
    {
        var entries = new List<SubscriptionEntry>
        {
            Entry(AgentProviderBrand.ClaudeCode, 0.30, id: "claude-a"),
            Entry(AgentProviderBrand.ClaudeCode, 0.70, id: "claude-b"), // worse — wins
            Entry(AgentProviderBrand.Cursor, 0.50, id: "cursor-a"),
        };

        IReadOnlyList<SubscriptionEntry> chips = SubscriptionConstellation.ProviderChipEntries(entries);

        Assert.Equal(2, chips.Count);
        Assert.Equal("claude-b", chips[0].Id);           // 0.70 first (pressure desc)
        Assert.Equal(AgentProviderBrand.Cursor, chips[1].Provider);
    }

    [Fact]
    public void ProviderChipEntries_ties_break_by_display_name()
    {
        var entries = new List<SubscriptionEntry>
        {
            Entry(AgentProviderBrand.Cursor, 0.50),
            Entry(AgentProviderBrand.Aider, 0.50),
        };

        IReadOnlyList<SubscriptionEntry> chips = SubscriptionConstellation.ProviderChipEntries(entries);
        Assert.Equal(AgentProviderBrand.Aider, chips[0].Provider); // "Aider" < "Cursor"
        Assert.Equal(AgentProviderBrand.Cursor, chips[1].Provider);
    }

    // ── selection toggle + downstream filter ───────────────────────────────────────────────

    [Fact]
    public void ToggleSelection_sets_clears_and_switches()
    {
        Assert.Equal(AgentProviderBrand.Cursor, SubscriptionConstellation.ToggleSelection(null, AgentProviderBrand.Cursor));
        Assert.Null(SubscriptionConstellation.ToggleSelection(AgentProviderBrand.Cursor, AgentProviderBrand.Cursor));
        Assert.Equal(AgentProviderBrand.Aider, SubscriptionConstellation.ToggleSelection(AgentProviderBrand.Cursor, AgentProviderBrand.Aider));
    }

    [Fact]
    public void DisplayedEntries_filters_to_selected_provider()
    {
        var entries = new List<SubscriptionEntry>
        {
            Entry(AgentProviderBrand.Cursor, 0.2, id: "c1"),
            Entry(AgentProviderBrand.Cursor, 0.6, id: "c2"),
            Entry(AgentProviderBrand.ClaudeCode, 0.4, id: "cc1"),
        };

        Assert.Equal(3, SubscriptionConstellation.DisplayedEntries(entries, null).Count);

        IReadOnlyList<SubscriptionEntry> focused = SubscriptionConstellation.DisplayedEntries(entries, AgentProviderBrand.Cursor);
        Assert.Equal(2, focused.Count);
        Assert.All(focused, e => Assert.Equal(AgentProviderBrand.Cursor, e.Provider));
    }

    [Fact]
    public void TotalProviderCount_is_distinct_providers()
    {
        var entries = new List<SubscriptionEntry>
        {
            Entry(AgentProviderBrand.Cursor, 0.2, id: "c1"),
            Entry(AgentProviderBrand.Cursor, 0.6, id: "c2"),
            Entry(AgentProviderBrand.ClaudeCode, 0.4, id: "cc1"),
        };
        Assert.Equal(2, SubscriptionConstellation.TotalProviderCount(entries));
    }

    // ── aggregate summary ──────────────────────────────────────────────────────────────────

    [Fact]
    public void Aggregate_pressure_bands_and_boundaries()
    {
        var entries = new List<SubscriptionEntry>
        {
            Entry(AgentProviderBrand.Cursor, 0.10),      // wide
            Entry(AgentProviderBrand.Aider, 0.45),       // wide (< 0.46)
            Entry(AgentProviderBrand.Codex, 0.46),       // narrowing (boundary → not wide)
            Entry(AgentProviderBrand.Cline, 0.73),       // narrowing
            Entry(AgentProviderBrand.Goose, 0.74),       // near edge (boundary → not narrowing)
            Entry(AgentProviderBrand.Warp, 0.90),        // near edge
        };

        AggregateSummary summary = SubscriptionConstellation.Aggregate(entries);
        Assert.Equal(6, summary.ActiveCount);
        Assert.Equal(2, summary.WideOpenCount);
        Assert.Equal(2, summary.NarrowingCount);
        Assert.Equal(2, summary.NearEdgeCount);
    }

    [Fact]
    public void Aggregate_next_reset_and_last_sync()
    {
        var soon = new DateTimeOffset(2026, 7, 4, 0, 0, 0, TimeSpan.Zero);
        var later = new DateTimeOffset(2026, 7, 10, 0, 0, 0, TimeSpan.Zero);
        var earlySync = new DateTimeOffset(2026, 7, 3, 8, 0, 0, TimeSpan.Zero);
        var lateSync = new DateTimeOffset(2026, 7, 3, 11, 0, 0, TimeSpan.Zero);

        var entries = new List<SubscriptionEntry>
        {
            Entry(AgentProviderBrand.Cursor, 0.2, nextReset: later, fetchedAt: earlySync, id: "c"),
            Entry(AgentProviderBrand.Aider, 0.3, nextReset: soon, fetchedAt: lateSync, id: "a"),
        };

        AggregateSummary summary = SubscriptionConstellation.Aggregate(entries);
        Assert.Equal("a", summary.NextResetEntry!.Id); // soonest reset
        Assert.Equal(lateSync, summary.LastSync);       // most recent fetch
    }

    [Fact]
    public void Aggregate_empty_is_zeroed()
    {
        AggregateSummary summary = SubscriptionConstellation.Aggregate(new List<SubscriptionEntry>());
        Assert.Equal(0, summary.ActiveCount);
        Assert.Null(summary.NextResetEntry);
        Assert.Null(summary.LastSync);
    }

    // ── hero copy ──────────────────────────────────────────────────────────────────────────

    private static AggregateSummary Summary(int active, int wide = 0, int narrowing = 0, int nearEdge = 0) =>
        new(active, wide, narrowing, nearEdge, null, null);

    [Fact]
    public void EyebrowText_vault_and_focused()
    {
        Assert.Equal("SUBSCRIPTION VAULT · 3 ACTIVE PLANS", SubscriptionConstellation.EyebrowText(Summary(3), null));
        Assert.Equal("SUBSCRIPTION VAULT · 1 ACTIVE PLAN", SubscriptionConstellation.EyebrowText(Summary(1), null));
        Assert.Equal("FOCUSED · CURSOR · 2 ACTIVE ACCOUNTS", SubscriptionConstellation.EyebrowText(Summary(2), AgentProviderBrand.Cursor));
        Assert.Equal("FOCUSED · CURSOR · 1 ACTIVE ACCOUNT", SubscriptionConstellation.EyebrowText(Summary(1), AgentProviderBrand.Cursor));
    }

    [Fact]
    public void HeadlineText_empty_prompts_connect()
    {
        Assert.Equal("Connect a plan to start tracking quota", SubscriptionConstellation.HeadlineText(Summary(0), null));
    }

    [Fact]
    public void HeadlineText_focused_variants()
    {
        Assert.Equal("Cursor · 2 accounts tracked",
            SubscriptionConstellation.HeadlineText(Summary(2), AgentProviderBrand.Cursor));
        Assert.Equal("Cursor · 1 account · 1 near the edge",
            SubscriptionConstellation.HeadlineText(Summary(1, nearEdge: 1), AgentProviderBrand.Cursor));
    }

    [Fact]
    public void HeadlineText_unfocused_variants()
    {
        Assert.Equal("3 plans tracked · 2 near the edge",
            SubscriptionConstellation.HeadlineText(Summary(3, nearEdge: 2), null));
        Assert.Equal("2 of 3 plans wide open · 1 narrowing",
            SubscriptionConstellation.HeadlineText(Summary(3, wide: 2, narrowing: 1), null));
        Assert.Equal("All 3 plans have headroom",
            SubscriptionConstellation.HeadlineText(Summary(3), null));
        Assert.Equal("All 1 plan have headroom",
            SubscriptionConstellation.HeadlineText(Summary(1), null));
    }
}

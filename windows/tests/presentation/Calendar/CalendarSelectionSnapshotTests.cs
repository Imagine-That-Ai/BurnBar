using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.Calendar;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Calendar;

/// <summary>
/// Pins the selection-driven analytics snapshot (parity: macOS
/// <c>CalendarSelectionSnapshot.build</c>): KPI math (distinct sessions, active
/// days, average over silent days), gap-filled daily burn, provider/model/project
/// mixes, the hour×weekday peak, and the cache/reasoning tile formulas.
/// </summary>
public sealed class CalendarSelectionSnapshotTests
{
    private static readonly TimeZoneInfo Tz = TimeZoneInfo.Utc;

    [Fact]
    public void Kpis_count_distinct_sessions_active_days_and_average_over_silent_days()
    {
        var rows = new List<CalendarUsageRow>
        {
            Row("2026-07-06T10:00:00Z", cost: 2.0, provider: "Codex", sessionId: "sess-a", totalTokens: 100),
            Row("2026-07-06T11:00:00Z", cost: 1.0, provider: "Codex", sessionId: "sess-a", totalTokens: 50),
            Row("2026-07-08T09:00:00Z", cost: 3.0, provider: "Claude Code", sessionId: "sess-b", totalTokens: 150),
        };
        var selected = Days(6, 7, 8, 9); // Jul 7 + 9 are silent

        CalendarSelectionSnapshot snapshot = CalendarSelectionSnapshot.Build(rows, selected, Tz);

        Assert.False(snapshot.IsEmpty);
        Assert.Equal(6.0, snapshot.TotalCost, 10);
        Assert.Equal(300, snapshot.TotalTokens);
        Assert.Equal(2, snapshot.SessionCount); // sess-a counted once across two rows
        Assert.Equal(2, snapshot.ActiveDays);   // Jul 6 + 8 only
        Assert.Equal(1.5, snapshot.AverageCostPerDay, 10); // 6.0 / 4 selected days (silent included)
        Assert.Equal(new[] { new DateOnly(2026, 7, 6), new DateOnly(2026, 7, 7), new DateOnly(2026, 7, 8), new DateOnly(2026, 7, 9) }, snapshot.SelectedDays);
    }

    [Fact]
    public void Empty_selection_means_empty_cards_but_honest_buckets()
    {
        var snapshot = CalendarSelectionSnapshot.Build(
            new List<CalendarUsageRow>(),
            Days(6),
            Tz);

        Assert.True(snapshot.IsEmpty);
        Assert.Equal(0, snapshot.TotalCost);
        Assert.Single(snapshot.DailyBurn);
        Assert.Equal(0, snapshot.DailyBurn[0].Value);
        Assert.Null(snapshot.PeakWeekdayIndex);
        Assert.Null(snapshot.PeakHour);
    }

    [Fact]
    public void Daily_burn_is_gap_filled_across_the_selection_span()
    {
        var rows = new List<CalendarUsageRow>
        {
            Row("2026-07-06T10:00:00Z", cost: 2.0, provider: "Codex"),
            Row("2026-07-09T10:00:00Z", cost: 4.0, provider: "Codex"),
        };
        // Non-contiguous Ctrl selection: span still covers the gap days.
        var selected = Days(6, 9);

        CalendarSelectionSnapshot snapshot = CalendarSelectionSnapshot.Build(rows, selected, Tz);

        Assert.Equal(4, snapshot.DailyBurn.Count);
        Assert.Equal(2.0, snapshot.DailyBurn[0].Value);
        Assert.Equal(0, snapshot.DailyBurn[1].Value);
        Assert.Equal(0, snapshot.DailyBurn[2].Value);
        Assert.Equal(4.0, snapshot.DailyBurn[3].Value);
    }

    [Fact]
    public void Provider_shares_sort_by_cost_desc_then_ordinal()
    {
        var rows = new List<CalendarUsageRow>
        {
            Row("2026-07-06T10:00:00Z", cost: 2.0, provider: "Cursor"),
            Row("2026-07-06T11:00:00Z", cost: 2.0, provider: "Codex"),
            Row("2026-07-06T12:00:00Z", cost: 5.0, provider: "Claude Code"),
        };

        CalendarSelectionSnapshot snapshot = CalendarSelectionSnapshot.Build(rows, Days(6), Tz);

        Assert.Equal(
            new[] { "Claude Code", "Codex", "Cursor" },
            snapshot.ProviderShares.Select(share => share.Provider).ToArray());
        Assert.Equal(5.0, snapshot.ProviderShares[0].Cost);
    }

    [Fact]
    public void Model_mix_groups_by_normalized_key_and_caps_at_six()
    {
        var rows = new List<CalendarUsageRow>();
        for (int i = 0; i < 8; i++)
        {
            rows.Add(Row("2026-07-06T10:00:00Z", cost: 8 - i, provider: "Codex", model: $"model-{i}"));
        }

        // "custom:Model-0" and "model-0" share the normalized key "model-0".
        rows.Add(Row("2026-07-06T11:00:00Z", cost: 1.0, provider: "Codex", model: "custom:Model-0"));

        CalendarSelectionSnapshot snapshot = CalendarSelectionSnapshot.Build(rows, Days(6), Tz);

        Assert.Equal(6, snapshot.TopModels.Count);
        Assert.Equal("model-0", snapshot.TopModels[0].Model);
        Assert.Equal("Model 0", snapshot.TopModels[0].DisplayName);
        Assert.Equal(9.0, snapshot.TopModels[0].Cost); // 8 + 1 merged
    }

    [Fact]
    public void Project_focus_buckets_blank_names_as_unattributed_and_caps_at_five()
    {
        var rows = new List<CalendarUsageRow>();
        for (int i = 0; i < 6; i++)
        {
            rows.Add(Row("2026-07-06T10:00:00Z", cost: 6 - i, provider: "Codex", project: $"proj-{i}"));
        }

        rows.Add(Row("2026-07-06T12:00:00Z", cost: 100.0, provider: "Codex", project: ""));

        CalendarSelectionSnapshot snapshot = CalendarSelectionSnapshot.Build(rows, Days(6), Tz);

        Assert.Equal(5, snapshot.ProjectShares.Count);
        Assert.Equal("Unattributed", snapshot.ProjectShares[0].Name);
        Assert.Equal(100.0, snapshot.ProjectShares[0].Cost);
    }

    [Fact]
    public void Hour_heatmap_reports_the_first_peak_cell_in_scan_order()
    {
        var rows = new List<CalendarUsageRow>
        {
            Row("2026-07-06T14:00:00Z", cost: 3.0, provider: "Codex"), // Monday 14:00 UTC
            Row("2026-07-07T03:00:00Z", cost: 3.0, provider: "Codex"), // Tuesday 03:00 UTC (tie — Monday stays peak)
        };

        CalendarSelectionSnapshot snapshot = CalendarSelectionSnapshot.Build(rows, Days(6, 7), Tz);

        Assert.Equal(1, snapshot.PeakWeekdayIndex); // Monday
        Assert.Equal(14, snapshot.PeakHour);
        Assert.Equal(3.0, snapshot.HourWeekdayCost[1][14]);
        Assert.Equal(3.0, snapshot.HourWeekdayCost[2][3]);
    }

    [Fact]
    public void Cache_and_reasoning_tiles_follow_the_macos_formulas()
    {
        var rows = new List<CalendarUsageRow>
        {
            new CalendarUsageRow(
                "u-1",
                "Codex",
                "sess-a",
                "proj",
                "model",
                InputTokens: 1_000,
                OutputTokens: 500,
                CacheCreationTokens: 500,
                CacheReadTokens: 3_000,
                ReasoningTokens: 900,
                TotalTokens: 5_900,
                CostUsd: 1.18,
                DateTimeOffset.Parse("2026-07-06T10:00:00Z", System.Globalization.CultureInfo.InvariantCulture)),
        };

        CalendarSelectionSnapshot snapshot = CalendarSelectionSnapshot.Build(rows, Days(6), Tz);

        // hitRate = cacheRead / (input + cacheCreation + cacheRead) = 3000 / 4500
        Assert.Equal(3_000.0 / 4_500.0, snapshot.CacheHitRate, 10);
        Assert.Equal(3_000, snapshot.CacheReadTokens);
        // savings = 0.9 × cacheRead × (cost / tokens) = 0.9 × 3000 × (1.18 / 5900)
        Assert.Equal(0.9 * 3_000 * (1.18 / 5_900), snapshot.CacheSavingsEstimate, 10);
        Assert.Equal(900.0 / 5_900, snapshot.ReasoningShare, 10);
        Assert.Equal(900, snapshot.ReasoningTokens);
    }

    [Fact]
    public void Zero_token_selection_never_divides_by_zero()
    {
        var rows = new List<CalendarUsageRow>
        {
            Row("2026-07-06T10:00:00Z", cost: 0, provider: "Codex", totalTokens: 0),
        };

        CalendarSelectionSnapshot snapshot = CalendarSelectionSnapshot.Build(rows, Days(6), Tz);

        Assert.Equal(0, snapshot.CacheHitRate);
        Assert.Equal(0, snapshot.CacheSavingsEstimate);
        Assert.Equal(0, snapshot.ReasoningShare);
    }

    private static HashSet<DateOnly> Days(params int[] julyDays) =>
        julyDays.Select(day => new DateOnly(2026, 7, day)).ToHashSet();

    private static CalendarUsageRow Row(
        string startIso,
        double cost,
        string provider,
        string sessionId = "sess-1",
        string model = "model",
        string project = "project",
        long totalTokens = 150)
    {
        DateTimeOffset start = DateTimeOffset.Parse(
            startIso,
            System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.RoundtripKind);
        return new CalendarUsageRow(
            $"u-{startIso}-{provider}-{model}-{project}",
            provider,
            sessionId,
            project,
            model,
            InputTokens: 100,
            OutputTokens: 50,
            CacheCreationTokens: 0,
            CacheReadTokens: 0,
            ReasoningTokens: 0,
            totalTokens,
            cost,
            start);
    }
}

using System.Linq;
using OpenBurnBar.App.Presentation.Calendar;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Calendar;

/// <summary>
/// Pins the analytics-card layout contract (parity: macOS <c>CalendarPageLayout</c>):
/// the default arrangement, forward-compatible JSON (unknown kinds dropped,
/// missing kinds appended, duplicates collapsed), move/hide/resize mutations
/// with span clamping, and the greedy 3-column row packing.
/// </summary>
public sealed class CalendarPageLayoutTests
{
    [Fact]
    public void Default_has_all_eight_cards_in_registry_order_with_default_spans()
    {
        CalendarPageLayout layout = CalendarPageLayout.Default;

        Assert.Equal(8, layout.Configs.Count);
        Assert.Equal(CalendarCardKindMetadata.All, layout.Configs.Select(c => c.Kind).ToArray());
        Assert.All(layout.Configs, config => Assert.True(config.IsVisible));
        Assert.Equal(3, layout.Configs.Single(c => c.Kind == CalendarCardKind.Kpis).Span);
        Assert.Equal(3, layout.Configs.Single(c => c.Kind == CalendarCardKind.BurnOverSelection).Span);
        Assert.Equal(3, layout.Configs.Single(c => c.Kind == CalendarCardKind.HourOfDayHeatmap).Span);
        Assert.Equal(1, layout.Configs.Single(c => c.Kind == CalendarCardKind.ProviderMix).Span);
    }

    [Fact]
    public void Encode_decode_round_trips_the_macos_wire_shape()
    {
        CalendarPageLayout layout = CalendarPageLayout.Default;
        layout.SetVisible(CalendarCardKind.ModelMix, false);
        layout.SetSpan(CalendarCardKind.ProviderMix, 2);
        layout.Move(CalendarCardKind.CacheRoi, CalendarCardKind.Kpis);

        string json = layout.Encode();
        CalendarPageLayout decoded = CalendarPageLayout.Decode(json);

        Assert.Equal(layout, decoded);
        Assert.Contains("\"kind\":\"kpis\"", json, System.StringComparison.Ordinal);
        Assert.Contains("\"isVisible\":false", json, System.StringComparison.Ordinal);
        Assert.Contains("\"span\":2", json, System.StringComparison.Ordinal);
        // The macOS rawValues are the persisted ids.
        Assert.Contains("\"kind\":\"cacheROI\"", json, System.StringComparison.Ordinal);
        Assert.Contains("\"kind\":\"burnOverSelection\"", json, System.StringComparison.Ordinal);
    }

    [Fact]
    public void Decode_drops_unknown_kinds_and_appends_missing_ones()
    {
        const string json = "[" +
            "{\"kind\":\"providerMix\",\"isVisible\":false,\"span\":2}," +
            "{\"kind\":\"futureCard\",\"isVisible\":true,\"span\":3}," +
            "{\"kind\":\"providerMix\",\"isVisible\":true,\"span\":1}" + // duplicate → first wins
            "]";

        CalendarPageLayout layout = CalendarPageLayout.Decode(json);

        Assert.Equal(8, layout.Configs.Count);
        CalendarCardConfig providerMix = layout.Configs.Single(c => c.Kind == CalendarCardKind.ProviderMix);
        Assert.False(providerMix.IsVisible);
        Assert.Equal(2, providerMix.Span);
        Assert.Equal(CalendarCardKind.ProviderMix, layout.Configs[0].Kind);
        // The seven kinds missing from the payload were appended with defaults.
        Assert.Equal(7, layout.Configs.Count(c => c.Kind != CalendarCardKind.ProviderMix));
        Assert.Contains(layout.Configs, c => c.Kind == CalendarCardKind.Kpis);
    }

    [Fact]
    public void Decode_corrupt_or_missing_json_falls_back_to_default()
    {
        Assert.Equal(CalendarPageLayout.Default, CalendarPageLayout.Decode("not json"));
        Assert.Equal(CalendarPageLayout.Default, CalendarPageLayout.Decode(""));
        Assert.Equal(CalendarPageLayout.Default, CalendarPageLayout.Decode(null));
        Assert.Equal(CalendarPageLayout.Default, CalendarPageLayout.Decode("{}"));
    }

    [Fact]
    public void Span_is_clamped_to_one_to_three()
    {
        CalendarPageLayout layout = CalendarPageLayout.Default;
        layout.SetSpan(CalendarCardKind.ProviderMix, 0);
        Assert.Equal(1, layout.Configs.Single(c => c.Kind == CalendarCardKind.ProviderMix).Span);
        layout.SetSpan(CalendarCardKind.ProviderMix, 9);
        Assert.Equal(3, layout.Configs.Single(c => c.Kind == CalendarCardKind.ProviderMix).Span);
    }

    [Fact]
    public void Move_lands_the_card_on_the_targets_position()
    {
        CalendarPageLayout layout = CalendarPageLayout.Default;
        layout.Move(CalendarCardKind.ReasoningShare, CalendarCardKind.Kpis);

        Assert.Equal(CalendarCardKind.ReasoningShare, layout.Configs[0].Kind);
        Assert.Equal(CalendarCardKind.Kpis, layout.Configs[1].Kind);

        // Moving to itself or an unknown pairing is a no-op.
        layout.Move(CalendarCardKind.Kpis, CalendarCardKind.Kpis);
        Assert.Equal(CalendarCardKind.Kpis, layout.Configs[1].Kind);
    }

    [Fact]
    public void Hidden_configs_feed_the_restore_menu_and_reset_restores_default()
    {
        CalendarPageLayout layout = CalendarPageLayout.Default;
        layout.SetVisible(CalendarCardKind.CacheRoi, false);
        layout.SetSpan(CalendarCardKind.ModelMix, 3);

        Assert.Equal(new[] { CalendarCardKind.CacheRoi }, layout.HiddenConfigs.Select(c => c.Kind).ToArray());
        Assert.DoesNotContain(layout.VisibleConfigs, c => c.Kind == CalendarCardKind.CacheRoi);

        layout.Reset();
        Assert.Equal(CalendarPageLayout.Default, layout);
    }

    [Fact]
    public void PackRows_packs_greedily_up_to_three_columns()
    {
        CalendarCardConfig[] configs =
        {
            new(CalendarCardKind.ProviderMix, span: 1),
            new(CalendarCardKind.ModelMix, span: 2),
            new(CalendarCardKind.ProjectFocus, span: 1),
            new(CalendarCardKind.CacheRoi, span: 1),
            new(CalendarCardKind.Kpis, span: 3),
            new(CalendarCardKind.ReasoningShare, span: 2),
        };

        var rows = CalendarPageLayout.PackRows(configs);

        Assert.Equal(4, rows.Count);
        Assert.Equal(new[] { "providerMix", "modelMix" }, rows[0].Configs.Select(c => c.Id).ToArray());   // 1+2
        Assert.Equal(new[] { "projectFocus", "cacheROI" }, rows[1].Configs.Select(c => c.Id).ToArray());  // 1+1
        Assert.Equal(new[] { "kpis" }, rows[2].Configs.Select(c => c.Id).ToArray());                      // 3
        Assert.Equal(new[] { "reasoningShare" }, rows[3].Configs.Select(c => c.Id).ToArray());            // 2
        Assert.All(rows, row => Assert.True(row.SpanSum <= 3));
    }
}

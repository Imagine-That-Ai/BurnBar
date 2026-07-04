using System.Collections.Generic;
using OpenBurnBar.App.Components;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts the quota model math against ProviderQuotaTypes.swift +
/// UnifiedQuotaSignalView.swift golden values.</summary>
public sealed class QuotaModelTests
{
    private static QuotaBucket Bucket(
        double used, double limit, double remaining,
        string? window = null, Dictionary<string, string>? meta = null) =>
        new("bucket", used, limit, remaining, window, meta);

    [Fact]
    public void DisplayRemainingFraction_from_limit_and_remaining()
    {
        QuotaBucket b = Bucket(used: 25, limit: 100, remaining: 75);
        Assert.Equal(0.75, b.DisplayRemainingFraction!.Value, 6);
        Assert.Equal(75, b.DisplayRemainingPercent!.Value, 6);
    }

    [Fact]
    public void DisplayRemainingFraction_prefers_usedPercent_meta()
    {
        QuotaBucket b = Bucket(0, 0, 0, meta: new() { ["usedPercent"] = "30" });
        Assert.Equal(0.70, b.DisplayRemainingFraction!.Value, 6);
    }

    [Fact]
    public void DisplayRemainingFraction_reads_remainingPercent_meta_alias()
    {
        QuotaBucket b = Bucket(0, 0, 0, meta: new() { ["percent_remaining"] = "42%" });
        Assert.Equal(0.42, b.DisplayRemainingFraction!.Value, 6);
    }

    [Fact]
    public void DisplayRemainingFraction_unlimited_is_full()
    {
        QuotaBucket b = Bucket(10, 0, 0, meta: new() { ["unit"] = "unlimited" });
        Assert.Equal(1.0, b.DisplayRemainingFraction!.Value, 6);
    }

    [Fact]
    public void DisplayRemainingFraction_synthetic_limit_for_balance_only_signal()
    {
        // limit < 0 (no cap), remaining > 0 -> remaining / (remaining + used)
        QuotaBucket b = Bucket(used: 30, limit: -1, remaining: 70);
        Assert.Equal(0.70, b.DisplayRemainingFraction!.Value, 6);
    }

    [Fact]
    public void DisplayRemainingFraction_null_when_uncomputable()
    {
        QuotaBucket b = Bucket(used: 0, limit: 0, remaining: 0);
        Assert.Null(b.DisplayRemainingFraction);
    }

    [Theory]
    [InlineData("rollingHours", "5h", QuotaWindowKind.RollingHours)]
    [InlineData("daily", "24h", QuotaWindowKind.Daily)]
    [InlineData("weekly", "7d", QuotaWindowKind.Weekly)]
    [InlineData("monthly", "30d", QuotaWindowKind.Monthly)]
    [InlineData("lifetime", "All", QuotaWindowKind.Lifetime)]
    public void WindowLabel_and_kind_map(string window, string label, QuotaWindowKind kind)
    {
        QuotaBucket b = Bucket(1, 1, 1, window: window);
        Assert.Equal(label, b.WindowLabel);
        Assert.Equal(kind, b.WindowKind);
    }

    [Fact]
    public void WindowLabel_null_for_empty_window()
    {
        Assert.Null(Bucket(1, 1, 1, window: null).WindowLabel);
        Assert.Null(Bucket(1, 1, 1, window: "").WindowLabel);
    }

    [Theory]
    [InlineData("currency", 3.61, "$3.61")]
    [InlineData("percent", 42, "42%")]
    [InlineData("count", 1250, "1,250")]
    public void FormatValue_respects_unit(string unit, double value, string expected)
    {
        QuotaBucket b = Bucket(0, 0, 0, meta: new() { ["unit"] = unit });
        Assert.Equal(expected, b.FormatValue(value));
    }

    [Theory]
    [InlineData(1_500, "1.5K")]
    [InlineData(2_400_000, "2.4M")]
    [InlineData(3_000_000_000, "3.00B")]
    [InlineData(950, "950")]
    public void FormatValue_tokens_scales(double value, string expected)
    {
        QuotaBucket b = Bucket(0, 0, 0, meta: new() { ["unit"] = "tokens" });
        Assert.Equal(expected, b.FormatValue(value));
    }

    [Fact]
    public void RemainingText_and_full_text_default_to_percent()
    {
        QuotaBucket b = Bucket(used: 40, limit: 100, remaining: 60);
        Assert.Equal("60% left", b.RemainingText());
        Assert.Equal("60% remaining", b.FullRemainingText());
    }

    [Fact]
    public void RemainingText_unlimited()
    {
        QuotaBucket b = Bucket(0, 0, 0, meta: new() { ["unit"] = "unlimited" });
        Assert.Equal("Unlimited", b.RemainingText());
        Assert.Equal("No fixed cap", b.UsageText);
    }

    [Fact]
    public void RemainingPercentText_handles_sub_one_and_missing()
    {
        Assert.Equal("0.5%", Bucket(99.5, 100, 0.5).RemainingPercentText);
        Assert.Equal("—", Bucket(0, 0, 0).RemainingPercentText);
    }

    [Theory]
    [InlineData("hourly_tokens", "Hourly Tokens")]
    [InlineData("Sonnet 5h", "Sonnet 5h")]
    [InlineData("", "Quota")]
    public void DisplayName_humanizes(string name, string expected)
    {
        QuotaBucket b = new(name, 1, 1, 1);
        Assert.Equal(expected, b.DisplayName);
    }

    [Theory]
    [InlineData(0.90, QuotaFillBand.Wide)]
    [InlineData(0.60, QuotaFillBand.Comfortable)]
    [InlineData(0.30, QuotaFillBand.Narrowing)]
    [InlineData(0.10, QuotaFillBand.Edge)]
    public void FillBand_thresholds(double fraction, QuotaFillBand band) =>
        Assert.Equal(band, QuotaFill.Band(fraction));

    [Theory]
    [InlineData(0.05, "Near Edge", QuotaTintRole.Warning)]
    [InlineData(0.20, "Narrowing", QuotaTintRole.Amber)]
    [InlineData(0.40, "Comfortable", QuotaTintRole.ThemeAccent)]
    [InlineData(0.90, "Wide Open", QuotaTintRole.ThemePrimary)]
    public void SignalStatus_resolve(double fraction, string label, QuotaTintRole tint)
    {
        QuotaSignalStatus status = QuotaSignalStatus.Resolve(fraction);
        Assert.Equal(label, status.Label);
        Assert.Equal(tint, status.Tint);
    }

    [Theory]
    [InlineData(QuotaSourceKind.OfficialApi, "Official API")]
    [InlineData(QuotaSourceKind.LocalCli, "Local CLI")]
    [InlineData(QuotaSourceKind.ManualEstimate, "Estimated")]
    [InlineData(QuotaSourceKind.Unavailable, "Unavailable")]
    public void SourceLabel_matches_swift(QuotaSourceKind source, string label) =>
        Assert.Equal(label, QuotaFill.SourceLabel(source));
}

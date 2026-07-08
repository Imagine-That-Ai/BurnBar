using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the pure formatting + color math ported from the macOS
/// <c>InsightFormatting</c>. Pins numeric string output (culture-invariant) and the
/// hex/HSB color conversions against hand-computed values.
/// </summary>
public sealed class InsightFormattingTests
{
    [Theory]
    [InlineData(1500.0, "$1500")]
    [InlineData(150.0, "$150.0")]
    [InlineData(15.5, "$15.50")]
    [InlineData(0.0, "$0.00")]
    public void Format_Currency_MatchesSwiftRamp(double value, string expected)
        => Assert.Equal(expected, InsightFormatting.Format(value, ValueFormat.Currency));

    [Theory]
    [InlineData(500.0, "500")]
    [InlineData(1500.0, "1.5k")]
    [InlineData(2_000_000.0, "2.0M")]
    [InlineData(3_000_000_000.0, "3.0B")]
    public void Format_Tokens_Abbreviates(double value, string expected)
        => Assert.Equal(expected, InsightFormatting.Format(value, ValueFormat.Tokens));

    [Fact]
    public void Format_Percent_MultipliesBy100()
        => Assert.Equal("25%", InsightFormatting.Format(0.25, ValueFormat.Percent));

    [Theory]
    [InlineData(30.0, "30.0s")]
    [InlineData(600.0, "10m")]
    [InlineData(3600.0, "1.0h")]
    [InlineData(7200.0, "2.0h")]
    public void Format_Duration_PicksUnit(double value, string expected)
        => Assert.Equal(expected, InsightFormatting.Format(value, ValueFormat.Duration));

    [Fact]
    public void Format_Count_Rounds()
        => Assert.Equal("43", InsightFormatting.Format(42.7, ValueFormat.Count));

    [Theory]
    [InlineData(0.12, true, "+12%")]
    [InlineData(-0.05, true, "-5%")]
    [InlineData(3.5, false, "+3.50")]
    [InlineData(-3.5, false, "-3.50")]
    public void FormatDelta_SignsAndFormats(double delta, bool percent, string expected)
        => Assert.Equal(expected, InsightFormatting.FormatDelta(delta, percent));

    [Fact]
    public void ColorFromHex_ParsesSixDigit()
    {
        InsightRgb? c = InsightFormatting.ColorFromHex("#FF8800");
        Assert.NotNull(c);
        Assert.Equal(new InsightRgb(255, 136, 0), c!.Value);
    }

    [Fact]
    public void ColorFromHex_ParsesWithoutHash()
        => Assert.Equal(new InsightRgb(51, 102, 153), InsightFormatting.ColorFromHex("336699"));

    [Fact]
    public void ColorFromHex_EightDigit_DropsLeadingAlphaByte()
        // Parity with Swift: an 8-digit value is treated as AARRGGBB, so the leading alpha
        // byte is masked out and the RGB is the trailing six hex digits ("345678").
        => Assert.Equal(new InsightRgb(0x34, 0x56, 0x78), InsightFormatting.ColorFromHex("#12345678"));

    [Theory]
    [InlineData("xyz")]
    [InlineData("12345")]
    [InlineData(null)]
    public void ColorFromHex_RejectsMalformed(string? hex)
        => Assert.Null(InsightFormatting.ColorFromHex(hex));

    [Fact]
    public void HsbToRgb_PrimaryHues()
    {
        Assert.Equal(new InsightRgb(255, 0, 0), InsightFormatting.HsbToRgb(0.0, 1, 1));
        Assert.Equal(new InsightRgb(0, 255, 0), InsightFormatting.HsbToRgb(1.0 / 3.0, 1, 1));
        Assert.Equal(new InsightRgb(0, 0, 255), InsightFormatting.HsbToRgb(2.0 / 3.0, 1, 1));
    }

    [Fact]
    public void HsbToRgb_ZeroSaturation_IsGray()
        => Assert.Equal(new InsightRgb(128, 128, 128), InsightFormatting.HsbToRgb(0.4, 0, 0.5));

    [Fact]
    public void SeriesColor_IsDeterministic()
        => Assert.Equal(InsightFormatting.SeriesColor("claude-opus"), InsightFormatting.SeriesColor("claude-opus"));

    [Fact]
    public void SeriesColor_DiffersByInput()
        => Assert.NotEqual(InsightFormatting.SeriesColor("alpha"), InsightFormatting.SeriesColor("beta"));

    [Fact]
    public void ResolveColor_PrefersHexOverSeries()
        => Assert.Equal(new InsightRgb(255, 0, 0), InsightFormatting.ResolveColor("#FF0000", "any-id"));

    [Fact]
    public void ResolveColor_FallsBackToSeries()
        => Assert.Equal(InsightFormatting.SeriesColor("id-1"), InsightFormatting.ResolveColor(null, "id-1"));

    [Fact]
    public void ToArgb_PacksChannels()
        => Assert.Equal(0xFFFF8800u, new InsightRgb(255, 136, 0).ToArgb());
}

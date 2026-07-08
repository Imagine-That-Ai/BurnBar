using OpenBurnBar.Updater.Core.Versioning;
using Xunit;

namespace OpenBurnBar.Updater.Tests;

public sealed class UpdateVersionTests
{
    [Theory]
    [InlineData("1")]
    [InlineData("1.4")]
    [InlineData("1.4.2")]
    [InlineData("1.4.2.0")]
    [InlineData("10.0.19041.1")]
    public void ParsesDottedNumeric(string value)
    {
        Assert.True(UpdateVersion.TryParse(value, out var version));
        Assert.Equal(value, version.ToString());
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("1.4.beta")]
    [InlineData("v1.4.2")]
    [InlineData("1..2")]
    [InlineData("-1.0")]
    [InlineData("1.-0.2")]
    [InlineData("1,4,2")]
    [InlineData("0x10")]
    public void RejectsMalformed(string? value)
    {
        Assert.False(UpdateVersion.TryParse(value, out _));
    }

    [Fact]
    public void TrailingZeroComponentsAreEquivalent()
    {
        Assert.Equal(UpdateVersion.Parse("1.4"), UpdateVersion.Parse("1.4.0.0"));
        Assert.Equal(UpdateVersion.Parse("1"), UpdateVersion.Parse("1.0.0"));
    }

    [Theory]
    [InlineData("1.4.3", "1.4.2")]
    [InlineData("1.5.0", "1.4.9")]
    [InlineData("2.0.0", "1.9.9")]
    [InlineData("10.0.19042", "10.0.19041")]
    [InlineData("1.4.2.1", "1.4.2.0")]
    public void OrdersNewerAboveOlder(string newer, string older)
    {
        Assert.True(UpdateVersion.Parse(newer) > UpdateVersion.Parse(older));
        Assert.True(UpdateVersion.Parse(older) < UpdateVersion.Parse(newer));
    }

    [Fact]
    public void EqualVersionsCompareEqual()
    {
        Assert.Equal(0, UpdateVersion.Parse("1.4.2").CompareTo(UpdateVersion.Parse("1.4.2")));
        Assert.True(UpdateVersion.Parse("1.4.2") <= UpdateVersion.Parse("1.4.2"));
        Assert.True(UpdateVersion.Parse("1.4.2") >= UpdateVersion.Parse("1.4.2"));
    }

    [Fact]
    public void DoubleDigitComponentsSortNumericallyNotLexically()
    {
        // "1.10" must be newer than "1.9" (lexical string compare would get this wrong).
        Assert.True(UpdateVersion.Parse("1.10") > UpdateVersion.Parse("1.9"));
    }
}

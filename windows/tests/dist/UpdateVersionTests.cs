// Strict version parsing + ordering (Phase 5 · signed distribution).

using OpenBurnBar.Dist.UpdateFeed;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class UpdateVersionTests
{
    [Theory]
    [InlineData("1")]
    [InlineData("1.0")]
    [InlineData("1.0.28")]
    [InlineData("1.0.28.0")]
    [InlineData("10.20.30.40")]
    [InlineData("1.1.0-beta.2")]
    [InlineData("2.0.0-rc.1")]
    public void ValidVersions_Parse(string value)
    {
        Assert.True(UpdateVersion.TryParse(value, out var version));
        Assert.NotNull(version);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("v1.0.0")]
    [InlineData("1.0.0.0.0")]
    [InlineData("1..0")]
    [InlineData("1.0.x")]
    [InlineData("1.0-")]
    [InlineData("1.0-beta..1")]
    [InlineData("-1.0")]
    [InlineData("1.0.0-bad space")]
    public void MalformedVersions_FailClosed(string value)
    {
        Assert.False(UpdateVersion.TryParse(value, out var version));
        Assert.Null(version);
    }

    [Fact]
    public void MissingTrailingComponents_AreZeroFilled()
    {
        var a = UpdateVersion.Parse("1.0");
        var b = UpdateVersion.Parse("1.0.0.0");
        Assert.Equal(0, a.CompareTo(b));
        Assert.True(a.Equals(b));
    }

    [Theory]
    [InlineData("1.0.29", "1.0.28", true)]
    [InlineData("1.0.28", "1.0.28", false)]
    [InlineData("1.0.27", "1.0.28", false)]
    [InlineData("2.0.0", "1.9.9", true)]
    [InlineData("1.0.28.1", "1.0.28.0", true)]
    public void IsNewer_ComparesCorrectly(string candidate, string installed, bool expected)
    {
        Assert.Equal(expected, UpdateVersion.IsNewer(UpdateVersion.Parse(candidate), UpdateVersion.Parse(installed)));
    }

    [Fact]
    public void PreRelease_SortsBeforeItsFinalRelease()
    {
        var beta = UpdateVersion.Parse("1.1.0-beta.1");
        var final = UpdateVersion.Parse("1.1.0");

        Assert.True(beta.CompareTo(final) < 0);
        Assert.False(UpdateVersion.IsNewer(beta, final));
        Assert.True(UpdateVersion.IsNewer(final, beta));
    }

    [Fact]
    public void PreReleaseIdentifiers_OrderNumericBelowAlphanumeric()
    {
        // semver §11: numeric identifiers have lower precedence than alphanumeric.
        var numeric = UpdateVersion.Parse("1.0.0-1");
        var alpha = UpdateVersion.Parse("1.0.0-alpha");
        Assert.True(numeric.CompareTo(alpha) < 0);
    }

    [Fact]
    public void PreRelease_MoreFieldsOutrankFewer()
    {
        var fewer = UpdateVersion.Parse("1.0.0-alpha");
        var more = UpdateVersion.Parse("1.0.0-alpha.1");
        Assert.True(more.CompareTo(fewer) > 0);
    }

    [Fact]
    public void NumericPreReleaseIdentifiers_CompareNumericallyNotLexically()
    {
        var lower = UpdateVersion.Parse("1.0.0-beta.2");
        var higher = UpdateVersion.Parse("1.0.0-beta.10");
        Assert.True(higher.CompareTo(lower) > 0); // 10 > 2, not "10" < "2"
    }

    [Fact]
    public void NormalizedString_IsFourComponentCore()
    {
        Assert.Equal("1.0.28.0", UpdateVersion.Parse("1.0.28").ToNormalizedString());
        Assert.Equal("1.1.0.0-beta.2", UpdateVersion.Parse("1.1.0-beta.2").ToNormalizedString());
    }
}

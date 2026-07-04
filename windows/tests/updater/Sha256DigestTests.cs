using System.Text;
using OpenBurnBar.Updater.Core.Crypto;
using Xunit;

namespace OpenBurnBar.Updater.Tests;

public sealed class Sha256DigestTests
{
    private static readonly byte[] Data = Encoding.UTF8.GetBytes("hello world");

    // Known-answer: SHA-256("hello world").
    private const string Expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";

    [Fact]
    public void HexOfMatchesKnownAnswerLowercase()
    {
        Assert.Equal(Expected, Sha256Digest.HexOf(Data));
    }

    [Fact]
    public void MatchesAcceptsCorrectHashCaseInsensitively()
    {
        Assert.True(Sha256Digest.Matches(Data, Expected));
        Assert.True(Sha256Digest.Matches(Data, Expected.ToUpperInvariant()));
    }

    [Fact]
    public void MatchesRejectsWrongHash()
    {
        var wrong = Expected.Replace('b', 'c');
        Assert.False(Sha256Digest.Matches(Data, wrong));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("deadbeef")] // too short
    [InlineData("zz4d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")] // non-hex
    public void MatchesFailsClosedOnMalformedExpectedHex(string? expected)
    {
        Assert.False(Sha256Digest.Matches(Data, expected));
    }
}

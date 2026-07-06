using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Canonical try-cloudflare URL extraction parity.</summary>
public sealed class TryCloudflareUrlExtractorTests
{
    [Fact]
    public void RecordedFixture_ExtractsQuickTunnelUrl()
    {
        var log = TestSupport.ReadFixture("cloudflared-stdout.txt");

        Assert.Equal(
            "https://calm-silver-otter-1234.trycloudflare.com",
            TryCloudflareUrlExtractor.Extract(log));
    }

    [Theory]
    [InlineData("https://abc.trycloudflare.com", "https://abc.trycloudflare.com")]
    [InlineData("(https://abc.trycloudflare.com)", "https://abc.trycloudflare.com")]
    [InlineData("HTTPS://ABC.trycloudflare.com/", "https://abc.trycloudflare.com")]
    public void Extract_AcceptsCanonicalHosts(string token, string expected)
    {
        Assert.Equal(expected, TryCloudflareUrlExtractor.Extract(token));
    }

    [Theory]
    [InlineData("http://abc.trycloudflare.com")]                 // not https
    [InlineData("https://abc.trycloudflare.com:8080")]           // explicit port
    [InlineData("https://user@abc.trycloudflare.com")]           // userinfo
    [InlineData("https://abc.trycloudflare.com/path")]           // non-root path
    [InlineData("https://abc.trycloudflare.com?q=1")]            // query
    [InlineData("https://abc.trycloudflare.com.evil.com")]       // look-alike suffix
    [InlineData("https://evil.com")]                             // wrong domain
    [InlineData("https://-abc.trycloudflare.com")]               // label starts with hyphen
    [InlineData("no url here at all")]
    public void Extract_RejectsNonCanonical(string token)
    {
        Assert.Null(TryCloudflareUrlExtractor.Extract(token));
    }

    [Fact]
    public void IsCanonicalHost_EnforcesThreeLabelAsciiRule()
    {
        Assert.True(TryCloudflareUrlExtractor.IsCanonicalTryCloudflareHost("a1.trycloudflare.com"));
        Assert.False(TryCloudflareUrlExtractor.IsCanonicalTryCloudflareHost("a_b.trycloudflare.com"));
        Assert.False(TryCloudflareUrlExtractor.IsCanonicalTryCloudflareHost("trycloudflare.com"));
    }
}

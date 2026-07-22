using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Quota;
using Xunit;

namespace OpenBurnBar.App.Quota.Tests;

/// <summary>
/// Mechanism 4 — Anthropic anthropic-ratelimit-* response headers. Parity against
/// the Swift RateLimitHeaders.parse + ClaudeQuotaAdapter.headerProbeSnapshot.
/// </summary>
public sealed class AnthropicRateLimitHeaderParserTests
{
    [Theory]
    [InlineData((int)DomainCoreQuotaMigrationMode.Shadow)]
    [InlineData((int)DomainCoreQuotaMigrationMode.Rust)]
    public void Parse_RecordedHeaders_DomainCoreModesMatchCanonicalFixture(
        int rawMode)
    {
        var mode = (DomainCoreQuotaMigrationMode)rawMode;
        var headers = QuotaFixtures.ReadHeaderInput("anthropic-ratelimit-headers-input.json");
        var expected = QuotaFixtures.ReadExpected("anthropic-ratelimit-headers-expected.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(expected.NowUnix!.Value);

        var snapshot = AnthropicRateLimitHeaderParser.Parse(
            headers,
            now,
            AnthropicRateLimitHeaderParser.CredentialShape.OauthBearer,
            mode);

        Assert.NotNull(snapshot);
        QuotaFixtures.AssertMatches(snapshot!, expected);
    }

    [Fact]
    public void Parse_RecordedHeaders_MatchesExpectedValueForValue()
    {
        var headers = QuotaFixtures.ReadHeaderInput("anthropic-ratelimit-headers-input.json");
        var expected = QuotaFixtures.ReadExpected("anthropic-ratelimit-headers-expected.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(expected.NowUnix!.Value);

        var snapshot = AnthropicRateLimitHeaderParser.Parse(headers, now);

        Assert.NotNull(snapshot);
        QuotaFixtures.AssertMatches(snapshot!, expected);
    }

    [Fact]
    public void ParseHeaders_IsCaseInsensitive()
    {
        var headers = new Dictionary<string, string>
        {
            ["ANTHROPIC-RATELIMIT-UNIFIED-TOKENS-LIMIT"] = "220000",
            ["Anthropic-RateLimit-Unified-Tokens-Remaining"] = "110000",
        };

        var parsed = AnthropicRateLimitHeaderParser.ParseHeaders(headers);

        Assert.Equal(220000, parsed.UnifiedTokensLimit);
        Assert.Equal(110000, parsed.UnifiedTokensRemaining);
    }

    [Fact]
    public void BuildSnapshot_ConsoleApiKeyShape_LabelsCredentialKind()
    {
        var headers = QuotaFixtures.ReadHeaderInput("anthropic-ratelimit-headers-input.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);

        var snapshot = AnthropicRateLimitHeaderParser.Parse(
            headers, now, AnthropicRateLimitHeaderParser.CredentialShape.ConsoleApiKey);

        Assert.NotNull(snapshot);
        Assert.Contains("Console API key", snapshot!.StatusMessage);
    }

    [Fact]
    public void BuildSnapshot_UnifiedOnly_ProducesSingleTokenBucket()
    {
        var headers = new Dictionary<string, string>
        {
            ["anthropic-ratelimit-unified-tokens-limit"] = "1000",
            ["anthropic-ratelimit-unified-tokens-remaining"] = "250",
            ["anthropic-ratelimit-unified-tokens-reset"] = "300",
        };
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);

        var snapshot = AnthropicRateLimitHeaderParser.Parse(headers, now);

        Assert.NotNull(snapshot);
        var bucket = Assert.Single(snapshot!.Buckets);
        Assert.Equal("claude-unified-header-probe", bucket.Key);
        Assert.Equal(ProviderQuotaUnit.Tokens, bucket.Unit);
        Assert.Equal(750, bucket.UsedValue!.Value, 6);
        Assert.Equal(75, bucket.UsedPercent!.Value, 6);
        Assert.Equal(now.AddSeconds(300), bucket.ResetsAt);
    }

    [Fact]
    public void BuildSnapshot_NoRateLimitHeaders_ReturnsNull()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);
        var snapshot = AnthropicRateLimitHeaderParser.Parse(
            new Dictionary<string, string> { ["content-type"] = "application/json" }, now);

        Assert.Null(snapshot);
        Assert.Null(AnthropicRateLimitHeaderParser.Parse(
            new Dictionary<string, string> { ["content-type"] = "application/json" },
            now,
            AnthropicRateLimitHeaderParser.CredentialShape.OauthBearer,
            DomainCoreQuotaMigrationMode.Rust));
    }
}

using System;
using OpenBurnBar.App.Presentation.Quota;
using Xunit;

namespace OpenBurnBar.App.Quota.Tests;

/// <summary>
/// Mechanism 3 — Codex wham/usage API response. Parity against the Swift
/// CodexOAuthQuotaFetcher bucket build (primary/secondary + additional lanes).
/// </summary>
public sealed class CodexUsageQuotaParserTests
{
    [Fact]
    public void Parse_RecordedUsagePayload_MatchesExpectedValueForValue()
    {
        var input = QuotaFixtures.ReadInput("codex-usage-input.json");
        var expected = QuotaFixtures.ReadExpected("codex-usage-expected.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(expected.NowUnix!.Value);

        var snapshot = CodexUsageQuotaParser.Parse(input, now);

        Assert.NotNull(snapshot);
        QuotaFixtures.AssertMatches(snapshot!, expected);
    }

    [Fact]
    public void Parse_UsesResetAtUnixWhenPresentElseNowPlusResetAfter()
    {
        var input = QuotaFixtures.ReadInput("codex-usage-input.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);

        var snapshot = CodexUsageQuotaParser.Parse(input, now);

        Assert.NotNull(snapshot);
        // primary_window: reset_after_seconds=3600 → now + 3600.
        var primary = Assert.Single(snapshot!.Buckets, b => b.Key == "codex-5h");
        Assert.Equal(now.AddSeconds(3600), primary.ResetsAt);
        // secondary_window: reset_at=1751500000 (absolute) wins over any reset_after.
        var secondary = Assert.Single(snapshot.Buckets, b => b.Key == "codex-7d");
        Assert.Equal(1751500000, secondary.ResetsAt!.Value.ToUnixTimeSeconds());
    }

    [Fact]
    public void Parse_SkipsAdditionalLaneWithEmptyLimitName()
    {
        var input = QuotaFixtures.ReadInput("codex-usage-input.json");
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);

        var snapshot = CodexUsageQuotaParser.Parse(input, now);

        Assert.NotNull(snapshot);
        // The second additional lane has limit_name "" → no bucket for used_percent 99.
        Assert.DoesNotContain(snapshot!.Buckets, b => b.UsedPercent is 99);
    }

    [Fact]
    public void Parse_ClampsUsedPercentIntoZeroToHundred()
    {
        const string input =
            "{ \"rate_limit\": { \"primary_window\": { \"used_percent\": 137.5 } } }";
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);

        var snapshot = CodexUsageQuotaParser.Parse(input, now);

        Assert.NotNull(snapshot);
        var bucket = Assert.Single(snapshot!.Buckets);
        Assert.Equal(100, bucket.UsedValue!.Value, 6);
        Assert.Equal(0, bucket.RemainingValue!.Value, 6);
    }

    [Fact]
    public void Parse_NoRateLimitData_ReturnsNull()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1783036800);

        Assert.Null(CodexUsageQuotaParser.Parse("{ \"plan_type\": \"pro\" }", now));
        Assert.Null(CodexUsageQuotaParser.Parse("not json", now));
    }
}

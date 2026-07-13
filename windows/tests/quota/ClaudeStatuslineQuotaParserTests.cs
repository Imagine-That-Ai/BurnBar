using System;
using OpenBurnBar.App.Presentation.Quota;
using DomainCore = uniffi.openburnbar_domain_ffi.OpenburnbarDomainFfiMethods;
using Xunit;

namespace OpenBurnBar.App.Quota.Tests;

/// <summary>
/// Mechanism 1 — Claude Code statusline hook. Parity against the Swift
/// ClaudeRateLimits.init(from:) + ClaudeQuotaAdapter.claudeQuotaBuckets(from:).
/// </summary>
public sealed class ClaudeStatuslineQuotaParserTests
{
    private static readonly DateTimeOffset FetchedAt = DateTimeOffset.FromUnixTimeSeconds(1783036800);

    [Fact]
    public void Parse_RecordedStatuslineSnapshot_MatchesExpectedValueForValue()
    {
        var input = QuotaFixtures.ReadInput("claude-statusline-input.json");
        var expected = QuotaFixtures.ReadExpected("claude-statusline-expected.json");

        var snapshot = ClaudeStatuslineQuotaParser.Parse(input, FetchedAt);

        QuotaFixtures.AssertMatches(snapshot, expected);
    }

    [Fact]
    public void RustMode_RecordedStatuslineSnapshot_MatchesExpectedValueForValue()
    {
        Assert.Equal(1u, DomainCore.DomainCoreAbiVersion());
        var input = QuotaFixtures.ReadInput("claude-statusline-input.json");
        var expected = QuotaFixtures.ReadExpected("claude-statusline-expected.json");
        var legacy = ClaudeStatuslineQuotaParser.ParseLegacy(input, FetchedAt);

        var snapshot = ClaudeStatuslineQuotaDomainCore.Apply(
            input,
            legacy,
            DomainCoreQuotaMigrationMode.Rust);

        QuotaFixtures.AssertMatches(snapshot, expected);
    }

    [Fact]
    public void Parse_DropsNonCandidateWindows()
    {
        var input = QuotaFixtures.ReadInput("claude-statusline-input.json");

        var snapshot = ClaudeStatuslineQuotaParser.Parse(input, FetchedAt);

        // "marketing_window" is not an Anthropic candidate key → no bucket.
        Assert.DoesNotContain(snapshot.Buckets, b => b.Key.Contains("marketing"));
    }

    [Fact]
    public void Parse_SkipsWindowsWithoutUsedOrRemainingSignal()
    {
        var input = QuotaFixtures.ReadInput("claude-statusline-input.json");

        var snapshot = ClaudeStatuslineQuotaParser.Parse(input, FetchedAt);

        // seven_day_oauth_apps carries only resets_at (no used/remaining) → no bucket,
        // even though it IS a candidate key (matches the Swift bucket guard).
        Assert.DoesNotContain(snapshot.Buckets, b => b.Key == "claude-seven_day_oauth_apps");
    }

    [Fact]
    public void Parse_DefaultsRemainingFromUsedWhenAbsent()
    {
        var input = QuotaFixtures.ReadInput("claude-statusline-input.json");

        var snapshot = ClaudeStatuslineQuotaParser.Parse(input, FetchedAt);

        // five_hour has no remaining_percentage → remaining = max(0, 100 - used).
        var fiveHour = Assert.Single(snapshot.Buckets, b => b.Key == "claude-five_hour");
        Assert.Equal(57.5, fiveHour.RemainingValue!.Value, 6);
        Assert.Equal(57.5, fiveHour.RemainingPercent!.Value, 6);
    }

    [Fact]
    public void Parse_AcceptsBareWindowMapWithoutRateLimitsWrapper()
    {
        // ClaudeRateLimits.init(from data:) accepts the bare {...} map too.
        const string bare = "{ \"five_hour\": { \"used_percentage\": 10 } }";

        var snapshot = ClaudeStatuslineQuotaParser.Parse(bare, FetchedAt);

        var bucket = Assert.Single(snapshot.Buckets);
        Assert.Equal("claude-five_hour", bucket.Key);
        Assert.Equal(10, bucket.UsedPercent!.Value, 6);
    }

    [Fact]
    public void Parse_InvalidJson_YieldsEmptyBuckets()
    {
        var snapshot = ClaudeStatuslineQuotaParser.Parse("not json", FetchedAt);

        Assert.False(snapshot.HasBuckets);
        Assert.Equal(ProviderQuotaSourceKind.LocalCli, snapshot.Source);
    }
}

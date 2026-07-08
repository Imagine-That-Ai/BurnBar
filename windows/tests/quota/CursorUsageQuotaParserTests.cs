using OpenBurnBar.App.Presentation.Quota;
using Xunit;

namespace OpenBurnBar.App.Quota.Tests;

/// <summary>
/// Mechanism 2 — Cursor state.vscdb-sourced usage-summary. Parity against the
/// Swift CursorQuotaAdapter.buildExactSnapshot (cents→dollars, plan/auto/api/on-demand).
/// </summary>
public sealed class CursorUsageQuotaParserTests
{
    [Fact]
    public void Parse_RecordedUsageSummary_MatchesExpectedValueForValue()
    {
        var input = QuotaFixtures.ReadInput("cursor-usage-summary-input.json");
        var expected = QuotaFixtures.ReadExpected("cursor-usage-summary-expected.json");

        var snapshot = CursorUsageQuotaParser.Parse(input);

        QuotaFixtures.AssertMatches(snapshot, expected);
    }

    [Fact]
    public void Parse_ConvertsCentsToDollarsForCurrencyBuckets()
    {
        var input = QuotaFixtures.ReadInput("cursor-usage-summary-input.json");

        var snapshot = CursorUsageQuotaParser.Parse(input);

        // plan.used = 1234 cents → $12.34; plan.limit = 2000 cents → $20.00.
        var plan = Assert.Single(snapshot.Buckets, b => b.Key == "cursor-plan");
        Assert.Equal(ProviderQuotaUnit.Currency, plan.Unit);
        Assert.Equal(12.34, plan.UsedValue!.Value, 6);
        Assert.Equal(20.00, plan.LimitValue!.Value, 6);
    }

    [Fact]
    public void Parse_AppendsEmailToStatusMessageWhenProvided()
    {
        var input = QuotaFixtures.ReadInput("cursor-usage-summary-input.json");

        var snapshot = CursorUsageQuotaParser.Parse(input, userEmail: "dev@example.com");

        Assert.Equal("Pro (dev@example.com) — Capped plan.", snapshot.StatusMessage);
    }

    [Fact]
    public void Parse_NoPlanNoOnDemand_YieldsUnlimitedStatusAndNoBuckets()
    {
        const string input =
            "{ \"membership_type\": \"ultra\", \"is_unlimited\": true, \"individual_usage\": { } }";

        var snapshot = CursorUsageQuotaParser.Parse(input);

        Assert.False(snapshot.HasBuckets);
        Assert.Equal("Ultra — Unlimited plan.", snapshot.StatusMessage);
        Assert.Equal(ProviderQuotaSourceKind.OfficialApi, snapshot.Source);
    }

    [Fact]
    public void Parse_InvalidJson_YieldsUnavailableSnapshot()
    {
        var snapshot = CursorUsageQuotaParser.Parse("}{ broken");

        Assert.Equal(ProviderQuotaConfidence.Unavailable, snapshot.Confidence);
        Assert.Equal(ProviderQuotaSourceKind.Unavailable, snapshot.Source);
        Assert.False(snapshot.HasBuckets);
    }
}

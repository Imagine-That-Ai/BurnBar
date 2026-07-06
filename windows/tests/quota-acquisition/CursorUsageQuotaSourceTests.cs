using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;
using OpenBurnBar.App.Quota.Acquisition;
using Xunit;

namespace OpenBurnBar.App.Quota.Acquisition.Tests;

/// <summary>
/// Mechanism 2 usage fetch — the state.vscdb cookie authenticates
/// GET cursor.sh/api/usage-summary and the recorded fixture round-trips
/// value-for-value through the landed parser.
/// </summary>
public sealed class CursorUsageQuotaSourceTests
{
    private static CursorStateCredentials Credentials(string? email = null) => new(
        AccessToken: CursorStateDbReaderTests.MakeJwt("auth0|user_2abc123"),
        UserId: "user_2abc123",
        CachedEmail: email,
        MembershipType: "pro");

    [Fact]
    public async Task RecordedUsageSummary_RoundTripsValueForValue()
    {
        var transport = new RecordingQuotaTransport(_ =>
            RecordingQuotaTransport.Json(200, AcquisitionTestSupport.ReadFixture("cursor-usage-summary-input.json")));
        var source = new CursorUsageQuotaSource(transport, () => Credentials());

        ProviderQuotaSnapshot? snapshot = await source.TryAcquireAsync(CancellationToken.None);

        Assert.NotNull(snapshot);
        AcquisitionTestSupport.AssertMatches(
            snapshot!,
            AcquisitionTestSupport.ReadExpected("cursor-usage-summary-expected.json"));
    }

    [Fact]
    public async Task Request_CarriesCookieAndAcceptHeaders()
    {
        var credentials = Credentials();
        var transport = new RecordingQuotaTransport(_ =>
            RecordingQuotaTransport.Json(200, AcquisitionTestSupport.ReadFixture("cursor-usage-summary-input.json")));
        var source = new CursorUsageQuotaSource(transport, () => credentials);

        _ = await source.TryAcquireAsync(CancellationToken.None);

        QuotaHttpRequest request = transport.LastRequest;
        Assert.Equal(QuotaHttpVerb.Get, request.Method);
        Assert.Equal(CursorUsageQuotaSource.UsageSummaryUrl, request.Url);
        Assert.Equal("application/json", request.Headers["Accept"]);
        Assert.Equal(credentials.CookieHeader, request.Headers["Cookie"]);
        Assert.StartsWith("WorkosCursorSessionToken=user_2abc123::", request.Headers["Cookie"], StringComparison.Ordinal);
    }

    [Fact]
    public async Task CachedEmail_EnrichesTheStatusMessage()
    {
        var transport = new RecordingQuotaTransport(_ =>
            RecordingQuotaTransport.Json(200, AcquisitionTestSupport.ReadFixture("cursor-usage-summary-input.json")));
        var source = new CursorUsageQuotaSource(transport, () => Credentials(email: "alberto@example.com"));

        ProviderQuotaSnapshot? snapshot = await source.TryAcquireAsync(CancellationToken.None);

        Assert.Contains("(alberto@example.com)", snapshot!.StatusMessage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task MissingCredentials_YieldsNoSignalAndNoRequest()
    {
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Empty(200));
        var source = new CursorUsageQuotaSource(transport, () => null);

        Assert.Null(await source.TryAcquireAsync(CancellationToken.None));
        Assert.Empty(transport.Requests);
    }

    [Theory]
    [InlineData(401)]
    [InlineData(403)]
    [InlineData(500)]
    public async Task RejectedOrFailedResponse_YieldsNoSignal(int status)
    {
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Empty(status));
        var source = new CursorUsageQuotaSource(transport, () => Credentials());

        Assert.Null(await source.TryAcquireAsync(CancellationToken.None));
    }
}

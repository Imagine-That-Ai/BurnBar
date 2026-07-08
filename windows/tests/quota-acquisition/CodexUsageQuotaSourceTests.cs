using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;
using OpenBurnBar.App.Quota.Acquisition;
using Xunit;

namespace OpenBurnBar.App.Quota.Acquisition.Tests;

/// <summary>
/// Mechanism 3 — auth.json bearer + GET chatgpt.com/backend-api/wham/usage,
/// parity with CodexOAuthQuotaFetcher (auth_mode gate, 8-day refresh grace,
/// exactly one retry after a refresh nudge).
/// </summary>
public sealed class CodexUsageQuotaSourceTests : IDisposable
{
    private readonly string _codexHome = AcquisitionTestSupport.CreateTempDirectory();

    public void Dispose() => Directory.Delete(_codexHome, recursive: true);

    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1783036800);

    private void WriteAuth(string accessToken, string? authMode = "chatgpt", DateTimeOffset? lastRefresh = null)
    {
        var refresh = (lastRefresh ?? Now.AddDays(-1)).ToUnixTimeSeconds();
        var mode = authMode is null ? string.Empty : $"\"auth_mode\":\"{authMode}\",";
        File.WriteAllText(
            Path.Combine(_codexHome, "auth.json"),
            $"{{{mode}\"tokens\":{{\"access_token\":\"{accessToken}\"}},\"last_refresh\":{refresh}}}");
    }

    private sealed class CountingRefresher : ICodexAuthRefresher
    {
        private readonly Func<bool> _onRefresh;

        public CountingRefresher(Func<bool> onRefresh) => _onRefresh = onRefresh;

        public int Calls { get; private set; }

        public Task<bool> TryRefreshAsync(CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(_onRefresh());
        }
    }

    [Fact]
    public async Task RecordedUsagePayload_RoundTripsValueForValue()
    {
        WriteAuth("tok-live");
        ExpectedSnapshot expected = AcquisitionTestSupport.ReadExpected("codex-usage-expected.json");
        var clock = new ManualQuotaClock { UtcNow = DateTimeOffset.FromUnixTimeSeconds(expected.NowUnix!.Value) };
        var transport = new RecordingQuotaTransport(_ =>
            RecordingQuotaTransport.Json(200, AcquisitionTestSupport.ReadFixture("codex-usage-input.json")));
        var source = new CodexUsageQuotaSource(transport, _codexHome, clock: clock);

        ProviderQuotaSnapshot? snapshot = await source.TryAcquireAsync(CancellationToken.None);

        Assert.NotNull(snapshot);
        AcquisitionTestSupport.AssertMatches(snapshot!, expected);

        QuotaHttpRequest request = transport.LastRequest;
        Assert.Equal(CodexUsageQuotaSource.UsageUrl, request.Url);
        Assert.Equal(QuotaHttpVerb.Get, request.Method);
        Assert.Equal("Bearer tok-live", request.Headers["Authorization"]);
        Assert.Equal("application/json", request.Headers["Accept"]);
    }

    [Fact]
    public async Task UnsupportedAuthMode_YieldsNoSignalAndNoRequest()
    {
        WriteAuth("tok", authMode: "apikey");
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Empty(200));
        var source = new CodexUsageQuotaSource(transport, _codexHome, clock: new ManualQuotaClock { UtcNow = Now });

        Assert.Null(await source.TryAcquireAsync(CancellationToken.None));
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task MissingAuthJson_YieldsNoSignal()
    {
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Empty(200));
        var source = new CodexUsageQuotaSource(transport, _codexHome, clock: new ManualQuotaClock { UtcNow = Now });

        Assert.Null(await source.TryAcquireAsync(CancellationToken.None));
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task Unauthorized_RefreshNudge_RetriesExactlyOnceWithTheNewToken()
    {
        WriteAuth("tok-stale");
        var refresher = new CountingRefresher(() =>
        {
            WriteAuth("tok-fresh");
            return true;
        });
        var transport = new RecordingQuotaTransport(request =>
            request.Headers["Authorization"] == "Bearer tok-fresh"
                ? RecordingQuotaTransport.Json(200, AcquisitionTestSupport.ReadFixture("codex-usage-input.json"))
                : RecordingQuotaTransport.Empty(401));
        var source = new CodexUsageQuotaSource(
            transport, _codexHome, refresher, new ManualQuotaClock { UtcNow = Now });

        ProviderQuotaSnapshot? snapshot = await source.TryAcquireAsync(CancellationToken.None);

        Assert.NotNull(snapshot);
        Assert.Equal(1, refresher.Calls);
        Assert.Equal(2, transport.Requests.Count);
        Assert.Equal("Bearer tok-stale", transport.Requests[0].Headers["Authorization"]);
        Assert.Equal("Bearer tok-fresh", transport.Requests[1].Headers["Authorization"]);
    }

    [Fact]
    public async Task Unauthorized_NoopRefresher_YieldsNoSignalAfterSingleRequest()
    {
        WriteAuth("tok");
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Empty(401));
        var source = new CodexUsageQuotaSource(transport, _codexHome, clock: new ManualQuotaClock { UtcNow = Now });

        Assert.Null(await source.TryAcquireAsync(CancellationToken.None));
        Assert.Single(transport.Requests);
    }

    [Fact]
    public async Task StaleLastRefresh_NudgesBeforeTheFirstRequest()
    {
        // 9 days old — beyond the Swift 8-day authRefreshGrace.
        WriteAuth("tok-old", lastRefresh: Now.AddDays(-9));
        var refresher = new CountingRefresher(() =>
        {
            WriteAuth("tok-renewed");
            return true;
        });
        var transport = new RecordingQuotaTransport(_ =>
            RecordingQuotaTransport.Json(200, AcquisitionTestSupport.ReadFixture("codex-usage-input.json")));
        var source = new CodexUsageQuotaSource(
            transport, _codexHome, refresher, new ManualQuotaClock { UtcNow = Now });

        _ = await source.TryAcquireAsync(CancellationToken.None);

        Assert.Equal(1, refresher.Calls);
        Assert.Equal("Bearer tok-renewed", transport.LastRequest.Headers["Authorization"]);
    }
}

using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;
using OpenBurnBar.App.Quota.Acquisition;
using Xunit;

namespace OpenBurnBar.App.Quota.Acquisition.Tests;

/// <summary>
/// Mechanism 4 — the 1-token /v1/messages probe + the DelegatingHandler capture,
/// parity with AnthropicCredentialProbe (headers, body, shape detection).
/// </summary>
public sealed class AnthropicRateLimitSourceTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1783036800);

    [Fact]
    public async Task Probe_RecordedHeaders_RoundTripValueForValue()
    {
        ExpectedSnapshot expected = AcquisitionTestSupport.ReadExpected("anthropic-ratelimit-headers-expected.json");
        var clock = new ManualQuotaClock { UtcNow = DateTimeOffset.FromUnixTimeSeconds(expected.NowUnix!.Value) };
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Json(
            200, "{}", AcquisitionTestSupport.ReadHeaderFixture("anthropic-ratelimit-headers-input.json")));
        var probe = new AnthropicCredentialProbe(transport, "oauth-bearer-token", clock);

        ProviderQuotaSnapshot? snapshot = await probe.ProbeAsync(store: null, CancellationToken.None);

        Assert.NotNull(snapshot);
        AcquisitionTestSupport.AssertMatches(snapshot!, expected);
    }

    [Fact]
    public async Task Probe_OauthShape_SendsTheExactSwiftRequest()
    {
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Json(
            200, "{}", new Dictionary<string, string> { ["anthropic-ratelimit-unified-tokens-limit"] = "220000" }));
        var probe = new AnthropicCredentialProbe(transport, "oauth-bearer-token", new ManualQuotaClock { UtcNow = Now });

        _ = await probe.ProbeAsync(store: null, CancellationToken.None);

        QuotaHttpRequest request = transport.LastRequest;
        Assert.Equal(QuotaHttpVerb.Post, request.Method);
        Assert.Equal(AnthropicCredentialProbe.MessagesUrl, request.Url);
        Assert.Equal("2023-06-01", request.Headers["anthropic-version"]);
        Assert.Equal("application/json", request.Headers["Content-Type"]);
        Assert.Equal("Bearer oauth-bearer-token", request.Headers["Authorization"]);
        Assert.False(request.Headers.ContainsKey("x-api-key"));
        // The .sortedKeys 1-token probe body, byte-for-byte.
        Assert.Equal(
            "{\"max_tokens\":1,\"messages\":[{\"content\":\"ping\",\"role\":\"user\"}],\"model\":\"claude-haiku-4-5\"}",
            Encoding.UTF8.GetString(request.Body!));
    }

    [Fact]
    public async Task Probe_ConsoleKeyShape_UsesXApiKey()
    {
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Json(
            200, "{}", new Dictionary<string, string> { ["anthropic-ratelimit-requests-limit"] = "50" }));
        var probe = new AnthropicCredentialProbe(transport, "sk-ant-api03-abc", new ManualQuotaClock { UtcNow = Now });

        ProviderQuotaSnapshot? snapshot = await probe.ProbeAsync(store: null, CancellationToken.None);

        Assert.Equal("sk-ant-api03-abc", transport.LastRequest.Headers["x-api-key"]);
        Assert.False(transport.LastRequest.Headers.ContainsKey("Authorization"));
        Assert.Contains("Console API key", snapshot!.StatusMessage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Probe_RateLimited429_StillYieldsTheHeadersSnapshot()
    {
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Json(
            429, "{\"error\":{\"type\":\"rate_limit_error\"}}",
            new Dictionary<string, string>
            {
                ["anthropic-ratelimit-unified-tokens-limit"] = "220000",
                ["anthropic-ratelimit-unified-tokens-remaining"] = "0",
            }));
        var probe = new AnthropicCredentialProbe(transport, "oauth-token", new ManualQuotaClock { UtcNow = Now });

        ProviderQuotaSnapshot? snapshot = await probe.ProbeAsync(store: null, CancellationToken.None);

        Assert.NotNull(snapshot);
        Assert.Equal(100, snapshot!.Buckets[0].UsedPercent);
    }

    [Fact]
    public async Task Probe_NoRateLimitHeaders_YieldsNoSignal()
    {
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Json(
            200, "{}", new Dictionary<string, string> { ["request-id"] = "req_1" }));
        var probe = new AnthropicCredentialProbe(transport, "tok", new ManualQuotaClock { UtcNow = Now });

        Assert.Null(await probe.ProbeAsync(store: null, CancellationToken.None));
    }

    [Fact]
    public async Task Source_FreshPassiveCapture_WinsOverTheProbe()
    {
        var store = new AnthropicRateLimitHeaderStore();
        store.Record(
            new Dictionary<string, string>
            {
                ["anthropic-ratelimit-unified-tokens-limit"] = "220000",
                ["anthropic-ratelimit-unified-tokens-remaining"] = "110000",
            },
            capturedAt: Now.AddMinutes(-1),
            AnthropicRateLimitHeaderParser.CredentialShape.OauthBearer);
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Empty(200));
        var probe = new AnthropicCredentialProbe(transport, "tok", new ManualQuotaClock { UtcNow = Now });
        var source = new AnthropicRateLimitQuotaSource(store, probe, new ManualQuotaClock { UtcNow = Now });

        ProviderQuotaSnapshot? snapshot = await source.TryAcquireAsync(CancellationToken.None);

        Assert.NotNull(snapshot);
        Assert.Empty(transport.Requests);
        Assert.Equal(50, snapshot!.Buckets[0].UsedPercent);
    }

    [Fact]
    public async Task Source_StaleCapture_FallsThroughToTheProbe()
    {
        var store = new AnthropicRateLimitHeaderStore();
        store.Record(
            new Dictionary<string, string> { ["anthropic-ratelimit-unified-tokens-limit"] = "1" },
            capturedAt: Now.AddMinutes(-16),
            AnthropicRateLimitHeaderParser.CredentialShape.OauthBearer);
        var transport = new RecordingQuotaTransport(_ => RecordingQuotaTransport.Json(
            200, "{}", new Dictionary<string, string> { ["anthropic-ratelimit-unified-tokens-limit"] = "220000" }));
        var probe = new AnthropicCredentialProbe(transport, "tok", new ManualQuotaClock { UtcNow = Now });
        var source = new AnthropicRateLimitQuotaSource(store, probe, new ManualQuotaClock { UtcNow = Now });

        ProviderQuotaSnapshot? snapshot = await source.TryAcquireAsync(CancellationToken.None);

        Assert.Single(transport.Requests);
        Assert.Equal(220000, snapshot!.Buckets[0].LimitValue);
    }

    [Fact]
    public async Task Source_PassiveOnlyWithEmptyStore_YieldsNoSignal()
    {
        var source = new AnthropicRateLimitQuotaSource(
            new AnthropicRateLimitHeaderStore(), probe: null, new ManualQuotaClock { UtcNow = Now });

        Assert.Null(await source.TryAcquireAsync(CancellationToken.None));
    }

    [Fact]
    public async Task CapturingHandler_HarvestsRateLimitHeadersFromAnyResponse()
    {
        var store = new AnthropicRateLimitHeaderStore();
        var handler = new AnthropicRateLimitCapturingHandler(store, now: () => Now)
        {
            InnerHandler = new StubHttpHandler(response =>
            {
                response.Headers.TryAddWithoutValidation("anthropic-ratelimit-unified-tokens-limit", "220000");
                response.Headers.TryAddWithoutValidation("anthropic-ratelimit-unified-tokens-remaining", "55000");
                response.Headers.TryAddWithoutValidation("request-id", "req_9");
            }),
        };
        using var client = new HttpClient(handler);

        _ = await client.GetAsync(new Uri("https://api.anthropic.com/v1/messages"));

        Assert.True(store.TryGetLatest(out var headers, out var capturedAt, out _));
        Assert.Equal(Now, capturedAt);
        Assert.Equal("220000", headers["anthropic-ratelimit-unified-tokens-limit"]);
        // Non-ratelimit headers are filtered out.
        Assert.False(headers.ContainsKey("request-id"));
    }

    [Fact]
    public async Task CapturingHandler_ResponseWithoutRateLimitHeaders_LeavesStoreEmpty()
    {
        var store = new AnthropicRateLimitHeaderStore();
        var handler = new AnthropicRateLimitCapturingHandler(store, now: () => Now)
        {
            InnerHandler = new StubHttpHandler(static _ => { }),
        };
        using var client = new HttpClient(handler);

        _ = await client.GetAsync(new Uri("https://api.anthropic.com/v1/models"));

        Assert.False(store.TryGetLatest(out _, out _, out _));
    }

    private sealed class StubHttpHandler : HttpMessageHandler
    {
        private readonly Action<HttpResponseMessage> _decorate;

        public StubHttpHandler(Action<HttpResponseMessage> decorate) => _decorate = decorate;

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{}"),
            };
            _decorate(response);
            return Task.FromResult(response);
        }
    }
}

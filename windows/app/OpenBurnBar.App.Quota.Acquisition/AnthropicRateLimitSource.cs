using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;

namespace OpenBurnBar.App.Quota.Acquisition;

// ── MECHANISM 4 · header acquisition ─────────────────────────────────────────
//
// Windows peer of OpenBurnBarCore/.../ProviderQuota/AnthropicCredentialProbe.swift:
//   • the 1-token `POST /v1/messages` probe that elicits the
//     `anthropic-ratelimit-*` response headers (model claude-haiku-4-5,
//     max_tokens 1, anthropic-version 2023-06-01; `x-api-key` for sk-ant-api…
//     console keys, `Authorization: Bearer` for OAuth — no beta header), and
//   • a DelegatingHandler that harvests the same headers from ANY Anthropic
//     response an app HttpClient pipeline sees, so passive traffic feeds quota
//     without spending probe tokens.
// Both paths land in AnthropicRateLimitHeaderStore; the landed portable
// AnthropicRateLimitHeaderParser builds the snapshot.

/// <summary>Latest captured rate-limit headers (thread-safe, newest wins).</summary>
public sealed class AnthropicRateLimitHeaderStore
{
    /// <summary>Header-name prefix that identifies a rate-limit header.</summary>
    public const string HeaderPrefix = "anthropic-ratelimit-";

    private readonly object _gate = new();
    private IReadOnlyDictionary<string, string>? _headers;
    private DateTimeOffset _capturedAt;
    private AnthropicRateLimitHeaderParser.CredentialShape _shape;

    /// <summary>Record a capture. Non-ratelimit headers are filtered out; empty captures are ignored.</summary>
    public void Record(
        IReadOnlyDictionary<string, string> headers,
        DateTimeOffset capturedAt,
        AnthropicRateLimitHeaderParser.CredentialShape shape)
    {
        var filtered = Filter(headers);
        if (filtered.Count == 0)
        {
            return;
        }

        lock (_gate)
        {
            _headers = filtered;
            _capturedAt = capturedAt;
            _shape = shape;
        }
    }

    /// <summary>Get the latest capture, if any.</summary>
    public bool TryGetLatest(
        out IReadOnlyDictionary<string, string> headers,
        out DateTimeOffset capturedAt,
        out AnthropicRateLimitHeaderParser.CredentialShape shape)
    {
        lock (_gate)
        {
            if (_headers is null)
            {
                headers = new Dictionary<string, string>();
                capturedAt = default;
                shape = default;
                return false;
            }

            headers = _headers;
            capturedAt = _capturedAt;
            shape = _shape;
            return true;
        }
    }

    /// <summary>Keep only <c>anthropic-ratelimit-*</c> headers (case-insensitive).</summary>
    public static IReadOnlyDictionary<string, string> Filter(IReadOnlyDictionary<string, string> headers)
    {
        var filtered = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in headers)
        {
            if (pair.Key.StartsWith(HeaderPrefix, StringComparison.OrdinalIgnoreCase))
            {
                filtered[pair.Key] = pair.Value;
            }
        }

        return filtered;
    }
}

/// <summary>
/// DelegatingHandler that harvests <c>anthropic-ratelimit-*</c> headers from every
/// response flowing through an <see cref="HttpClient"/> pipeline.
/// </summary>
public sealed class AnthropicRateLimitCapturingHandler : DelegatingHandler
{
    private readonly AnthropicRateLimitHeaderStore _store;
    private readonly AnthropicRateLimitHeaderParser.CredentialShape _shape;
    private readonly Func<DateTimeOffset> _now;

    /// <summary>Create a capturing handler feeding <paramref name="store"/>.</summary>
    public AnthropicRateLimitCapturingHandler(
        AnthropicRateLimitHeaderStore store,
        AnthropicRateLimitHeaderParser.CredentialShape shape = AnthropicRateLimitHeaderParser.CredentialShape.OauthBearer,
        Func<DateTimeOffset>? now = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _shape = shape;
        _now = now ?? (static () => DateTimeOffset.UtcNow);
    }

    /// <inheritdoc />
    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        HttpResponseMessage response = await base.SendAsync(request, cancellationToken).ConfigureAwait(false);

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in response.Headers)
        {
            headers[pair.Key] = string.Join(",", pair.Value);
        }

        _store.Record(headers, _now(), _shape);
        return response;
    }
}

/// <summary>The 1-token probe (Swift <c>AnthropicCredentialProbe</c>).</summary>
public sealed class AnthropicCredentialProbe
{
    /// <summary>Swift <c>defaultBaseURL</c> + <c>appending(path: "messages")</c>.</summary>
    public const string MessagesUrl = "https://api.anthropic.com/v1/messages";

    /// <summary>Swift <c>defaultAnthropicVersion</c>.</summary>
    public const string AnthropicVersion = "2023-06-01";

    /// <summary>Swift <c>defaultProbeModel</c>.</summary>
    public const string ProbeModel = "claude-haiku-4-5";

    /// <summary>Swift probe body, <c>.sortedKeys</c>-serialized.</summary>
    public const string ProbeBody =
        "{\"max_tokens\":1,\"messages\":[{\"content\":\"ping\",\"role\":\"user\"}],\"model\":\"" + ProbeModel + "\"}";

    private readonly IQuotaHttpTransport _transport;
    private readonly string _credential;
    private readonly IQuotaAcquisitionClock _clock;

    /// <summary>Create a probe for one credential.</summary>
    public AnthropicCredentialProbe(
        IQuotaHttpTransport transport,
        string credential,
        IQuotaAcquisitionClock? clock = null)
    {
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _credential = credential ?? throw new ArgumentNullException(nameof(credential));
        _clock = clock ?? SystemQuotaAcquisitionClock.Instance;
    }

    /// <summary>Which credential shape this probe reports (Swift <c>detectShape</c>).</summary>
    public AnthropicRateLimitHeaderParser.CredentialShape Shape => DetectShape(_credential);

    /// <summary>Swift <c>detectShape</c>: <c>sk-ant-api…</c> (case-insensitive) → console key.</summary>
    public static AnthropicRateLimitHeaderParser.CredentialShape DetectShape(string credential) =>
        credential.TrimStart().StartsWith("sk-ant-api", StringComparison.OrdinalIgnoreCase)
            ? AnthropicRateLimitHeaderParser.CredentialShape.ConsoleApiKey
            : AnthropicRateLimitHeaderParser.CredentialShape.OauthBearer;

    /// <summary>
    /// Probe once and build a snapshot from the response's rate-limit headers.
    /// Non-2xx responses (429 included) still carry the headers — mirrored: any
    /// response with <c>anthropic-ratelimit-*</c> headers yields a snapshot.
    /// Records into <paramref name="store"/> when given.
    /// </summary>
    public async Task<ProviderQuotaSnapshot?> ProbeAsync(
        AnthropicRateLimitHeaderStore? store,
        CancellationToken cancellationToken)
    {
        var shape = Shape;
        var headers = new Dictionary<string, string>
        {
            ["Content-Type"] = "application/json",
            ["anthropic-version"] = AnthropicVersion,
        };

        if (shape == AnthropicRateLimitHeaderParser.CredentialShape.ConsoleApiKey)
        {
            headers["x-api-key"] = _credential;
        }
        else
        {
            headers["Authorization"] = $"Bearer {_credential}";
        }

        var request = new QuotaHttpRequest(
            QuotaHttpVerb.Post,
            MessagesUrl,
            Encoding.UTF8.GetBytes(ProbeBody),
            headers);

        QuotaHttpResponse response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        var captured = AnthropicRateLimitHeaderStore.Filter(response.Headers);
        if (captured.Count == 0)
        {
            return null;
        }

        DateTimeOffset now = _clock.UtcNow;
        store?.Record(captured, now, shape);
        return AnthropicRateLimitHeaderParser.Parse(captured, now, shape);
    }
}

/// <summary>
/// Header-based quota source: fresh passive captures first, then (optionally)
/// an active probe when the store is empty or stale.
/// </summary>
public sealed class AnthropicRateLimitQuotaSource : IQuotaPayloadSource
{
    /// <summary>The coordinator source id.</summary>
    public const string DefaultSourceId = "anthropic-ratelimit-headers";

    private readonly AnthropicRateLimitHeaderStore _store;
    private readonly AnthropicCredentialProbe? _probe;
    private readonly IQuotaAcquisitionClock _clock;
    private readonly TimeSpan _maxCaptureAge;

    /// <summary>Create the source. Omit <paramref name="probe"/> for a passive-only source.</summary>
    public AnthropicRateLimitQuotaSource(
        AnthropicRateLimitHeaderStore store,
        AnthropicCredentialProbe? probe = null,
        IQuotaAcquisitionClock? clock = null,
        TimeSpan? maxCaptureAge = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _probe = probe;
        _clock = clock ?? SystemQuotaAcquisitionClock.Instance;
        _maxCaptureAge = maxCaptureAge ?? QuotaAcquisitionPolicy.StatuslineMaxSnapshotAge;
    }

    /// <inheritdoc />
    public string SourceId => DefaultSourceId;

    /// <inheritdoc />
    public async Task<ProviderQuotaSnapshot?> TryAcquireAsync(CancellationToken cancellationToken)
    {
        if (_store.TryGetLatest(out var headers, out var capturedAt, out var shape)
            && _clock.UtcNow - capturedAt <= _maxCaptureAge)
        {
            // The -reset headers are seconds-until-reset relative to CAPTURE time,
            // so the capture instant anchors the conversion.
            return AnthropicRateLimitHeaderParser.Parse(headers, capturedAt, shape);
        }

        if (_probe is not null)
        {
            return await _probe.ProbeAsync(_store, cancellationToken).ConfigureAwait(false);
        }

        return null;
    }
}

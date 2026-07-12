using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;

namespace OpenBurnBar.App.Quota.Acquisition;

// ── MECHANISM 3 · Codex wham/usage fetch ─────────────────────────────────────
//
// Windows peer of CodexOAuthQuotaFetcher in
// OpenBurnBarCore/.../ProviderQuota/CodexQuotaAdapter.swift:
//   • bearer from `auth.json` under the Codex home (`CODEX_HOME` /
//     `CODEX_CONFIG_PATH` env override, else ~/.codex) — `auth_mode` must be
//     "chatgpt" (or absent), token at `tokens.access_token`;
//   • `GET https://chatgpt.com/backend-api/wham/usage` with
//     `Authorization: Bearer …` + `Accept: application/json`;
//   • when `last_refresh` is older than 8 days, or on a 401/403, nudge a refresh
//     and retry EXACTLY once (Swift shells `codex login status`; that shell-out is
//     the ICodexAuthRefresher seam — the Windows runner pass wires the real CLI).
// The body feeds the landed portable CodexUsageQuotaParser.

/// <summary>
/// Refresh nudge seam. The Mac implementation shells out to the pinned
/// <c>codex</c> CLI (<c>login status</c>) and re-reads auth.json; the default here
/// is a no-op so acquisition degrades to "no signal" instead of guessing.
/// </summary>
public interface ICodexAuthRefresher
{
    /// <summary>Attempt a refresh; <c>true</c> when auth.json may have new tokens.</summary>
    Task<bool> TryRefreshAsync(CancellationToken cancellationToken);
}

/// <summary>Default no-op refresher.</summary>
public sealed class NoopCodexAuthRefresher : ICodexAuthRefresher
{
    /// <summary>Shared instance.</summary>
    public static readonly NoopCodexAuthRefresher Instance = new();

    /// <inheritdoc />
    public Task<bool> TryRefreshAsync(CancellationToken cancellationToken) => Task.FromResult(false);
}

/// <summary>Parsed subset of <c>auth.json</c> (Swift <c>CodexAuthPayload</c>).</summary>
public sealed record CodexAuthCredentials(string AccessToken, DateTimeOffset? LastRefresh);

/// <summary>Reads the Codex CLI's <c>auth.json</c>.</summary>
public static class CodexAuthReader
{
    /// <summary>
    /// Read + validate. Returns <c>null</c> when the file is missing/invalid, the
    /// token is empty, or <c>auth_mode</c> is present and not <c>"chatgpt"</c>
    /// (Swift <c>unsupportedAuthMode</c>).
    /// </summary>
    public static CodexAuthCredentials? TryRead(string codexHomeDirectory)
    {
        var path = Path.Combine(codexHomeDirectory, "auth.json");
        if (!File.Exists(path))
        {
            return null;
        }

        JsonElement? root = QuotaJson.TryParse(File.ReadAllText(path));
        if (root is not JsonElement payload || payload.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        if (payload.TryGetProperty("auth_mode", out var mode)
            && mode.ValueKind == JsonValueKind.String
            && !string.Equals(mode.GetString(), "chatgpt", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        if (!payload.TryGetProperty("tokens", out var tokens)
            || tokens.ValueKind != JsonValueKind.Object
            || !tokens.TryGetProperty("access_token", out var token)
            || token.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(token.GetString()))
        {
            return null;
        }

        // last_refresh: ISO-8601 or epoch seconds (Swift accepts both).
        DateTimeOffset? lastRefresh = QuotaJson.FirstDate(payload, "last_refresh");
        return new CodexAuthCredentials(token.GetString()!, lastRefresh);
    }
}

/// <summary>Codex usage source (auth.json bearer + wham/usage fetch).</summary>
public sealed class CodexUsageQuotaSource : IQuotaPayloadSource
{
    /// <summary>The coordinator source id.</summary>
    public const string DefaultSourceId = "codex-usage";

    /// <summary>Swift <c>CodexOAuthQuotaFetcher</c> usage endpoint.</summary>
    public const string UsageUrl = "https://chatgpt.com/backend-api/wham/usage";

    private readonly IQuotaHttpTransport _transport;
    private readonly string _codexHomeDirectory;
    private readonly ICodexAuthRefresher _refresher;
    private readonly IQuotaAcquisitionClock _clock;

    /// <summary>Create the source over a Codex home directory.</summary>
    public CodexUsageQuotaSource(
        IQuotaHttpTransport transport,
        string codexHomeDirectory,
        ICodexAuthRefresher? refresher = null,
        IQuotaAcquisitionClock? clock = null)
    {
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _codexHomeDirectory = codexHomeDirectory ?? throw new ArgumentNullException(nameof(codexHomeDirectory));
        _refresher = refresher ?? NoopCodexAuthRefresher.Instance;
        _clock = clock ?? SystemQuotaAcquisitionClock.Instance;
    }

    /// <inheritdoc />
    public string SourceId => DefaultSourceId;

    /// <inheritdoc />
    public async Task<ProviderQuotaSnapshot?> TryAcquireAsync(CancellationToken cancellationToken)
    {
        CodexAuthCredentials? auth = CodexAuthReader.TryRead(_codexHomeDirectory);
        if (auth is null)
        {
            return null;
        }

        // Swift authRefreshGrace: stale credentials get a nudge BEFORE the call.
        if (auth.LastRefresh is DateTimeOffset lastRefresh
            && _clock.UtcNow - lastRefresh > QuotaAcquisitionPolicy.CodexAuthRefreshGrace
            && await _refresher.TryRefreshAsync(cancellationToken).ConfigureAwait(false))
        {
            auth = CodexAuthReader.TryRead(_codexHomeDirectory);
            if (auth is null)
            {
                return null;
            }
        }

        QuotaHttpResponse response = await FetchAsync(auth.AccessToken, cancellationToken).ConfigureAwait(false);

        if (response.IsAuthRejected)
        {
            // Swift: exactly one retry after a refresh nudge.
            if (!await _refresher.TryRefreshAsync(cancellationToken).ConfigureAwait(false))
            {
                return null;
            }

            auth = CodexAuthReader.TryRead(_codexHomeDirectory);
            if (auth is null)
            {
                return null;
            }

            response = await FetchAsync(auth.AccessToken, cancellationToken).ConfigureAwait(false);
        }

        if (!response.IsSuccess)
        {
            return null;
        }

        return CodexUsageQuotaParser.Parse(Encoding.UTF8.GetString(response.Body), _clock.UtcNow);
    }

    private Task<QuotaHttpResponse> FetchAsync(string accessToken, CancellationToken cancellationToken)
    {
        var request = new QuotaHttpRequest(
            QuotaHttpVerb.Get,
            UsageUrl,
            Body: null,
            Headers: new Dictionary<string, string>
            {
                ["Authorization"] = $"Bearer {accessToken}",
                ["Accept"] = "application/json",
            });
        return _transport.SendAsync(request, cancellationToken);
    }
}

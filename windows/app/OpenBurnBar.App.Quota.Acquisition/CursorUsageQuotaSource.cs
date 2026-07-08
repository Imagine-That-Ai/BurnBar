using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;

namespace OpenBurnBar.App.Quota.Acquisition;

// ── MECHANISM 2 · usage-summary fetch ────────────────────────────────────────
//
// Windows peer of the exact-usage branch of
// AgentLens/Services/ProviderQuota/CursorQuotaAdapter.swift: the session cookie
// (auto-extracted from state.vscdb by CursorStateDbReader) authenticates
// `GET https://cursor.sh/api/usage-summary`; the body feeds the landed portable
// CursorUsageQuotaParser. NOTE the Mac code calls host `cursor.sh` (its doc
// comment says cursor.com) — mirrored verbatim here.

/// <summary>Cursor usage-summary source (state.vscdb cookie + HTTP fetch).</summary>
public sealed class CursorUsageQuotaSource : IQuotaPayloadSource
{
    /// <summary>The coordinator source id.</summary>
    public const string DefaultSourceId = "cursor-usage";

    /// <summary>Swift <c>CursorQuotaAdapter</c> usage endpoint (host mirrored from code, not docs).</summary>
    public const string UsageSummaryUrl = "https://cursor.sh/api/usage-summary";

    private readonly IQuotaHttpTransport _transport;
    private readonly Func<CursorStateCredentials?> _credentials;

    /// <summary>
    /// Create the source. <paramref name="credentials"/> is a provider (not a value)
    /// so every acquisition re-reads state.vscdb — the token rotates under Cursor's
    /// control (Swift re-extracts per refresh too).
    /// </summary>
    public CursorUsageQuotaSource(IQuotaHttpTransport transport, Func<CursorStateCredentials?> credentials)
    {
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _credentials = credentials ?? throw new ArgumentNullException(nameof(credentials));
    }

    /// <inheritdoc />
    public string SourceId => DefaultSourceId;

    /// <inheritdoc />
    public async Task<ProviderQuotaSnapshot?> TryAcquireAsync(CancellationToken cancellationToken)
    {
        CursorStateCredentials? credentials = _credentials();
        if (credentials is null)
        {
            return null;
        }

        var request = new QuotaHttpRequest(
            QuotaHttpVerb.Get,
            UsageSummaryUrl,
            Body: null,
            Headers: new Dictionary<string, string>
            {
                ["Accept"] = "application/json",
                ["Cookie"] = credentials.CookieHeader,
            });

        QuotaHttpResponse response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (response.IsAuthRejected || !response.IsSuccess)
        {
            // Swift: 401/403 → cookie rejected → the adapter falls through; other
            // failures likewise yield no exact snapshot.
            return null;
        }

        string json = Encoding.UTF8.GetString(response.Body);
        ProviderQuotaSnapshot snapshot = CursorUsageQuotaParser.Parse(json, credentials.CachedEmail);
        return snapshot.HasBuckets ? snapshot : null;
    }
}

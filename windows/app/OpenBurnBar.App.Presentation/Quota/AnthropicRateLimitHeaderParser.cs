using System;
using System.Collections.Generic;
using System.Globalization;

namespace OpenBurnBar.App.Presentation.Quota;

// ── MECHANISM 4 · Header / response rate-limit quota ─────────────────────────
//
// Portable parse of the `anthropic-ratelimit-*` response headers Anthropic
// returns on every Messages API call. The 1-token `/v1/messages` probe that
// elicits the headers is the adapter-deferred half (AnthropicCredentialProbe);
// THIS is the pure header-dictionary → ProviderQuotaSnapshot transform,
// portable and unit-tested on macOS.
//
// Parity sources (macOS):
//   • AgentLens/Services/ProviderQuota/AnthropicCredentialProbe.swift
//       RateLimitHeaders (the 12 unified + standard fields) + parse(from:) — the
//       header-name → Double coercion.
//   • AgentLens/Services/ProviderQuota/ClaudeQuotaAdapter.swift
//       headerProbeSnapshot(...) — the unified (5-hour token) + standard
//       (requests / input-tokens / output-tokens per-minute) bucket build.

/// <summary>Parses Anthropic <c>anthropic-ratelimit-*</c> response headers into a quota snapshot.</summary>
public static class AnthropicRateLimitHeaderParser
{
    /// <summary>The Swift <c>AgentProvider.claudeCode.rawValue</c> token.</summary>
    public const string ProviderToken = "claudeCode";

    /// <summary>Swift <c>managementURL</c> for the header-probe branch.</summary>
    public const string ManagementUrl = "https://claude.ai/settings/usage";

    /// <summary>Which credential elicited the headers (Swift <c>AnthropicCredentialProbe.Shape</c>).</summary>
    public enum CredentialShape
    {
        /// <summary>Pro/Team OAuth bearer — reports the unified 5h/7d token budget headers.</summary>
        OauthBearer,

        /// <summary>Console <c>sk-ant-api…</c> key — reports the per-minute RPM/ITPM/OTPM headers.</summary>
        ConsoleApiKey,
    }

    /// <summary>The 12 rate-limit values, faithful to Swift <c>RateLimitHeaders</c>.</summary>
    public sealed record RateLimitHeaders
    {
        public double? UnifiedTokensLimit { get; init; }

        public double? UnifiedTokensRemaining { get; init; }

        public double? UnifiedTokensResetSeconds { get; init; }

        public double? RequestsLimit { get; init; }

        public double? RequestsRemaining { get; init; }

        public double? RequestsResetSeconds { get; init; }

        public double? InputTokensLimit { get; init; }

        public double? InputTokensRemaining { get; init; }

        public double? InputTokensResetSeconds { get; init; }

        public double? OutputTokensLimit { get; init; }

        public double? OutputTokensRemaining { get; init; }

        public double? OutputTokensResetSeconds { get; init; }

        public bool HasUnifiedData => UnifiedTokensLimit is not null || UnifiedTokensRemaining is not null;

        public bool HasStandardData =>
            RequestsLimit is not null || RequestsRemaining is not null
            || InputTokensLimit is not null || InputTokensRemaining is not null
            || OutputTokensLimit is not null || OutputTokensRemaining is not null;

        public bool IsEmpty => !HasUnifiedData && !HasStandardData;
    }

    /// <summary>
    /// Parse the raw response headers (case-insensitive lookup, matching Swift
    /// <c>HTTPURLResponse.value(forHTTPHeaderField:)</c>). Blank/absent values become <c>null</c>.
    /// </summary>
    public static RateLimitHeaders ParseHeaders(IReadOnlyDictionary<string, string> headers)
    {
        var lookup = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in headers)
        {
            lookup[pair.Key] = pair.Value;
        }

        double? DoubleValue(string name)
        {
            if (!lookup.TryGetValue(name, out var raw))
            {
                return null;
            }

            var trimmed = raw.Trim();
            if (trimmed.Length == 0)
            {
                return null;
            }

            return double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
                ? value
                : (double?)null;
        }

        return new RateLimitHeaders
        {
            UnifiedTokensLimit = DoubleValue("anthropic-ratelimit-unified-tokens-limit"),
            UnifiedTokensRemaining = DoubleValue("anthropic-ratelimit-unified-tokens-remaining"),
            UnifiedTokensResetSeconds = DoubleValue("anthropic-ratelimit-unified-tokens-reset"),
            RequestsLimit = DoubleValue("anthropic-ratelimit-requests-limit"),
            RequestsRemaining = DoubleValue("anthropic-ratelimit-requests-remaining"),
            RequestsResetSeconds = DoubleValue("anthropic-ratelimit-requests-reset"),
            InputTokensLimit = DoubleValue("anthropic-ratelimit-input-tokens-limit"),
            InputTokensRemaining = DoubleValue("anthropic-ratelimit-input-tokens-remaining"),
            InputTokensResetSeconds = DoubleValue("anthropic-ratelimit-input-tokens-reset"),
            OutputTokensLimit = DoubleValue("anthropic-ratelimit-output-tokens-limit"),
            OutputTokensRemaining = DoubleValue("anthropic-ratelimit-output-tokens-remaining"),
            OutputTokensResetSeconds = DoubleValue("anthropic-ratelimit-output-tokens-reset"),
        };
    }

    /// <summary>Convenience: parse a raw header dictionary straight into a snapshot.</summary>
    public static ProviderQuotaSnapshot? Parse(
        IReadOnlyDictionary<string, string> headers,
        DateTimeOffset now,
        CredentialShape shape = CredentialShape.OauthBearer)
    {
        return BuildSnapshot(ParseHeaders(headers), now, shape);
    }

    /// <summary>
    /// Build the snapshot from parsed headers. Faithful to
    /// <c>ClaudeQuotaAdapter.headerProbeSnapshot</c>. Returns <c>null</c> when no
    /// bucket can be built (Swift falls through to the next cascade step).
    /// </summary>
    public static ProviderQuotaSnapshot? BuildSnapshot(
        RateLimitHeaders headers,
        DateTimeOffset now,
        CredentialShape shape = CredentialShape.OauthBearer)
    {
        var buckets = new List<ProviderQuotaBucket>();

        if (headers.HasUnifiedData)
        {
            var limit = headers.UnifiedTokensLimit;
            var remaining = headers.UnifiedTokensRemaining;
            buckets.Add(new ProviderQuotaBucket
            {
                Key = "claude-unified-header-probe",
                Label = "5-hour unified window",
                WindowKind = ProviderQuotaWindowKind.RollingHours,
                UsedValue = limit is double l && remaining is double r ? l - r : (double?)null,
                LimitValue = limit,
                RemainingValue = remaining,
                UsedPercent = UsedPercent(limit, remaining),
                ResetsAt = ResetInstant(headers.UnifiedTokensResetSeconds, now),
                Unit = ProviderQuotaUnit.Tokens,
                IsEstimated = false,
            });
        }

        if (headers.HasStandardData)
        {
            AddStandardBucket(buckets, "requests", "Requests / minute",
                headers.RequestsLimit, headers.RequestsRemaining, headers.RequestsResetSeconds, now);
            AddStandardBucket(buckets, "input-tokens", "Input tokens / minute",
                headers.InputTokensLimit, headers.InputTokensRemaining, headers.InputTokensResetSeconds, now);
            AddStandardBucket(buckets, "output-tokens", "Output tokens / minute",
                headers.OutputTokensLimit, headers.OutputTokensRemaining, headers.OutputTokensResetSeconds, now);
        }

        if (buckets.Count == 0)
        {
            return null;
        }

        var credentialKind = shape == CredentialShape.ConsoleApiKey ? "Console API key" : "Claude plan";
        return new ProviderQuotaSnapshot
        {
            Provider = ProviderToken,
            FetchedAt = now,
            Source = ProviderQuotaSourceKind.OfficialApi,
            Confidence = ProviderQuotaConfidence.Exact,
            ManagementUrl = ManagementUrl,
            StatusMessage =
                $"Claude quota from Anthropic rate-limit headers ({credentialKind}). {buckets.Count} window(s) active.",
            Buckets = buckets,
        };
    }

    private static void AddStandardBucket(
        List<ProviderQuotaBucket> buckets,
        string prefix,
        string label,
        double? limit,
        double? remaining,
        double? resetSeconds,
        DateTimeOffset now)
    {
        if (limit is null && remaining is null)
        {
            return;
        }

        buckets.Add(new ProviderQuotaBucket
        {
            Key = $"claude-rate-limit-{prefix}",
            Label = label,
            WindowKind = ProviderQuotaWindowKind.Custom,
            UsedValue = limit is double l && remaining is double r ? l - r : (double?)null,
            LimitValue = limit,
            RemainingValue = remaining,
            UsedPercent = UsedPercent(limit, remaining),
            ResetsAt = ResetInstant(resetSeconds, now),
            Unit = prefix.Contains("tokens", StringComparison.Ordinal)
                ? ProviderQuotaUnit.Tokens
                : ProviderQuotaUnit.Requests,
            IsEstimated = false,
        });
    }

    private static double? UsedPercent(double? limit, double? remaining)
    {
        if (limit is double l && l > 0 && remaining is double r)
        {
            return Math.Max(0, Math.Min(((l - r) / l) * 100, 100));
        }

        return null;
    }

    private static DateTimeOffset? ResetInstant(double? resetSeconds, DateTimeOffset now)
    {
        return resetSeconds is double seconds ? now.AddSeconds(seconds) : (DateTimeOffset?)null;
    }
}

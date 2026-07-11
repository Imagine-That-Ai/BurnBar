using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;

namespace OpenBurnBar.App.Presentation.Quota;

// ── MECHANISM 3 · API-quota response parse (Codex) ───────────────────────────
//
// Portable parse of the Codex usage API body (`GET
// chatgpt.com/backend-api/wham/usage`). The auth/refresh + HTTP round-trip and
// the local rollout-JSONL fallback scan live in the acquisition adapter; THIS is
// the pure API-response JSON → ProviderQuotaSnapshot transform, portable and
// unit-tested on macOS.
//
// Parity source (macOS):
//   • AgentLens/Services/ProviderQuota/CodexQuotaAdapter.swift
//       CodexOAuthQuotaFetcher.fetchUsageSnapshot / rateLimitBuckets / bucket /
//       resetDate / windowKind(seconds:) / slug — the percent-window build over
//       primary/secondary windows + the additional-rate-limit lanes.
//   • CodexUsagePayload — the wire shape (snake_case keys).

/// <summary>Parses a Codex <c>wham/usage</c> payload into a quota snapshot.</summary>
public static class CodexUsageQuotaParser
{
    /// <summary>The Swift <c>AgentProvider.codex.rawValue</c> token.</summary>
    public const string ProviderToken = "codex";

    /// <summary>Swift <c>managementURL</c> for the OAuth usage branch.</summary>
    public const string ManagementUrl = "https://chatgpt.com/codex/settings/usage";

    /// <summary>Swift caps <c>additional_rate_limits</c> to the first 8 lanes.</summary>
    private const int MaxAdditionalLanes = 8;

    /// <summary>
    /// Parse the usage payload. <paramref name="now"/> anchors the relative
    /// <c>reset_after_seconds</c> conversion (Swift uses <c>Date()</c>).
    /// Returns <c>null</c> when no bucket can be built (Swift throws
    /// <c>invalidResponse</c> and the adapter falls through).
    /// </summary>
    public static ProviderQuotaSnapshot? Parse(string json, DateTimeOffset now)
    {
        var root = QuotaJson.TryParse(json);
        if (root is not JsonElement payload || payload.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var buckets = new List<ProviderQuotaBucket>();

        if (payload.TryGetProperty("rate_limit", out var rateLimit))
        {
            buckets.AddRange(RateLimitBuckets(rateLimit, prefix: "codex", labelPrefix: null, now));
        }

        if (payload.TryGetProperty("additional_rate_limits", out var additional)
            && additional.ValueKind == JsonValueKind.Array)
        {
            var count = 0;
            foreach (var entry in additional.EnumerateArray())
            {
                if (count >= MaxAdditionalLanes)
                {
                    break;
                }

                count++;

                if (entry.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                var label = (entry.TryGetProperty("limit_name", out var name) && name.ValueKind == JsonValueKind.String
                    ? name.GetString()
                    : null)?.Trim();
                if (string.IsNullOrEmpty(label))
                {
                    continue;
                }

                if (entry.TryGetProperty("rate_limit", out var laneRateLimit))
                {
                    buckets.AddRange(RateLimitBuckets(
                        laneRateLimit,
                        prefix: $"codex-{Slug(label!)}",
                        labelPrefix: label,
                        now));
                }
            }
        }

        if (buckets.Count == 0)
        {
            return null;
        }

        var plan = payload.TryGetProperty("plan_type", out var planType) && planType.ValueKind == JsonValueKind.String
            ? Capitalized(planType.GetString())
            : "Codex";

        return new ProviderQuotaSnapshot
        {
            Provider = ProviderToken,
            FetchedAt = now,
            Source = ProviderQuotaSourceKind.OfficialApi,
            Confidence = ProviderQuotaConfidence.Exact,
            ManagementUrl = ManagementUrl,
            StatusMessage = $"{plan} quota snapshot from the local Codex login session.",
            Buckets = buckets,
        };
    }

    private static IEnumerable<ProviderQuotaBucket> RateLimitBuckets(
        JsonElement rateLimit,
        string prefix,
        string? labelPrefix,
        DateTimeOffset now)
    {
        var buckets = new List<ProviderQuotaBucket>();
        if (rateLimit.ValueKind != JsonValueKind.Object)
        {
            return buckets;
        }

        if (TryReadWindow(rateLimit, "primary_window", out var primary))
        {
            buckets.Add(Bucket(
                primary,
                key: $"{prefix}-5h",
                label: labelPrefix is null ? "5-hour window" : $"{labelPrefix} 5-hour window",
                fallbackKind: ProviderQuotaWindowKind.RollingHours,
                now));
        }

        if (TryReadWindow(rateLimit, "secondary_window", out var secondary))
        {
            buckets.Add(Bucket(
                secondary,
                key: $"{prefix}-7d",
                label: labelPrefix is null ? "7-day window" : $"{labelPrefix} 7-day window",
                fallbackKind: ProviderQuotaWindowKind.RollingDays,
                now));
        }

        return buckets;
    }

    private readonly record struct Window(
        double UsedPercent,
        int? LimitWindowSeconds,
        int? ResetAfterSeconds,
        long? ResetAt);

    /// <summary>
    /// Read a window object. A window is only present when it carries a numeric
    /// <c>used_percent</c> — mirroring the non-optional Swift <c>Window.usedPercent</c>
    /// (a window object without it fails to decode and behaves as absent).
    /// </summary>
    private static bool TryReadWindow(JsonElement rateLimit, string key, out Window window)
    {
        window = default;
        if (!rateLimit.TryGetProperty(key, out var element) || element.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        if (QuotaJson.FirstNumber(element, "used_percent") is not double used)
        {
            return false;
        }

        window = new Window(
            used,
            ReadInt(element, "limit_window_seconds"),
            ReadInt(element, "reset_after_seconds"),
            ReadLong(element, "reset_at"));
        return true;
    }

    private static ProviderQuotaBucket Bucket(
        Window window,
        string key,
        string label,
        ProviderQuotaWindowKind fallbackKind,
        DateTimeOffset now)
    {
        var used = Math.Min(Math.Max(window.UsedPercent, 0), 100);
        return new ProviderQuotaBucket
        {
            Key = key,
            Label = label,
            WindowKind = WindowKind(window.LimitWindowSeconds) ?? fallbackKind,
            UsedValue = used,
            LimitValue = 100,
            RemainingValue = Math.Max(0, 100 - used),
            UsedPercent = used,
            ResetsAt = ResetDate(window, now),
            Unit = ProviderQuotaUnit.Percent,
            IsEstimated = false,
        };
    }

    private static DateTimeOffset? ResetDate(Window window, DateTimeOffset now)
    {
        if (window.ResetAt is long resetAt && resetAt > 0)
        {
            return QuotaJson.UnixSecondsToDate(resetAt);
        }

        if (window.ResetAfterSeconds is int resetAfter && resetAfter >= 0)
        {
            return now.AddSeconds(resetAfter);
        }

        return null;
    }

    private static ProviderQuotaWindowKind? WindowKind(int? seconds)
    {
        if (seconds is not int value || value <= 0)
        {
            return null;
        }

        return value switch
        {
            18_000 => ProviderQuotaWindowKind.RollingHours,
            604_800 => ProviderQuotaWindowKind.RollingDays,
            _ => value >= 86_400 ? ProviderQuotaWindowKind.RollingDays : ProviderQuotaWindowKind.RollingHours,
        };
    }

    private static int? ReadInt(JsonElement obj, string key)
    {
        if (obj.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var i))
        {
            return i;
        }

        return null;
    }

    private static long? ReadLong(JsonElement obj, string key)
    {
        if (obj.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var l))
        {
            return l;
        }

        return null;
    }

    /// <summary>
    /// Slugify a lane label, faithful to the Swift <c>slug(_:)</c>:
    /// lower-cased, non-alphanumerics → '-', collapsed runs, empty → "additional".
    /// </summary>
    private static string Slug(string value)
    {
        var lower = value.ToLowerInvariant();
        var builder = new StringBuilder(lower.Length);
        foreach (var ch in lower)
        {
            builder.Append(char.IsLetterOrDigit(ch) ? ch : '-');
        }

        var parts = builder.ToString().Split('-', StringSplitOptions.RemoveEmptyEntries);
        var collapsed = string.Join("-", parts);
        return collapsed.Length == 0 ? "additional" : collapsed;
    }

    private static string Capitalized(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "Codex";
        }

        return System.Globalization.CultureInfo.InvariantCulture.TextInfo.ToTitleCase(value.ToLowerInvariant());
    }
}

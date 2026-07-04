using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;

namespace OpenBurnBar.App.Presentation.Quota;

// ── MECHANISM 2 · Cursor state.vscdb scraping ────────────────────────────────
//
// Portable parse half of the macOS Cursor adapter. On both platforms the
// session cookie is auto-extracted from Cursor's own SQLite database
// (`state.vscdb`, an editor `ItemTable` blob) — that read is the
// net8.0-windows/adapter-deferred half (CursorCookieExtractor). THIS file is
// the pure usage-summary JSON → ProviderQuotaSnapshot transform, portable and
// unit-tested on macOS.
//
// Parity source (macOS):
//   • AgentLens/Services/ProviderQuota/CursorQuotaAdapter.swift
//       buildExactSnapshot(usageSummary:userEmail:) — the four-bucket build
//       (plan / auto / api / on-demand), cents→dollars, billing-cycle reset.
//   • AgentLens/Services/ProviderQuota/ProviderQuotaModels.swift
//       CursorUsageSummary — the wire shape (decoded with convertFromSnakeCase,
//       so the on-disk keys are snake_case; camelCase is also accepted here).

/// <summary>Parses a Cursor <c>usage-summary</c> payload into a quota snapshot.</summary>
public static class CursorUsageQuotaParser
{
    /// <summary>The Swift <c>AgentProvider.cursor.rawValue</c> token.</summary>
    public const string ProviderToken = "cursor";

    /// <summary>Swift <c>managementURL</c>.</summary>
    public const string ManagementUrl = "https://cursor.com/dashboard";

    /// <summary>
    /// Build the exact snapshot from a usage-summary payload. Faithful port of
    /// <c>CursorQuotaAdapter.buildExactSnapshot</c>. <paramref name="userEmail"/> is the
    /// optional email enrichment the Swift adapter appends to the status line.
    /// </summary>
    public static ProviderQuotaSnapshot Parse(string json, string? userEmail = null)
    {
        var root = QuotaJson.TryParse(json);
        if (root is not JsonElement summary || summary.ValueKind != JsonValueKind.Object)
        {
            return new ProviderQuotaSnapshot
            {
                Provider = ProviderToken,
                FetchedAt = DateTimeOffset.UtcNow,
                Source = ProviderQuotaSourceKind.Unavailable,
                Confidence = ProviderQuotaConfidence.Unavailable,
                ManagementUrl = ManagementUrl,
                StatusMessage = "Cursor usage-summary payload was not valid JSON.",
                Buckets = ProviderQuotaSnapshot.NoBuckets,
            };
        }

        var buckets = new List<ProviderQuotaBucket>();

        QuotaJson.TryGetProperty(summary, "individual_usage", out var individual);
        if (individual.ValueKind != JsonValueKind.Object)
        {
            QuotaJson.TryGetProperty(summary, "individualUsage", out individual);
        }

        var hasPlan = individual.ValueKind == JsonValueKind.Object
            && (individual.TryGetProperty("plan", out var plan) && plan.ValueKind == JsonValueKind.Object);
        var hasOnDemand = individual.ValueKind == JsonValueKind.Object
            && ((individual.TryGetProperty("on_demand", out var onDemand) && onDemand.ValueKind == JsonValueKind.Object)
                || (individual.TryGetProperty("onDemand", out onDemand) && onDemand.ValueKind == JsonValueKind.Object));

        var resetsAt = QuotaJson.ParseIso8601(
            ReadString(summary, "billing_cycle_end", "billingCycleEnd"));

        if (hasPlan)
        {
            individual.TryGetProperty("plan", out plan);
            var planUsed = (QuotaJson.FirstNumber(plan, "used") ?? 0) / 100.0;
            var planLimit = (QuotaJson.FirstNumber(plan, "limit") ?? 0) / 100.0;
            var autoPct = QuotaJson.FirstNumber(plan, "auto_percent_used", "autoPercentUsed");
            var apiPct = QuotaJson.FirstNumber(plan, "api_percent_used", "apiPercentUsed");
            var totalPct = QuotaJson.FirstNumber(plan, "total_percent_used", "totalPercentUsed")
                ?? (autoPct is double a
                    ? (apiPct is double b ? (a + b) / 2 : a)
                    : (double?)null);

            if (planLimit > 0 || planUsed > 0)
            {
                buckets.Add(new ProviderQuotaBucket
                {
                    Key = "cursor-plan",
                    Label = "Included usage",
                    WindowKind = ProviderQuotaWindowKind.Monthly,
                    UsedValue = planUsed,
                    LimitValue = planLimit,
                    RemainingValue = Math.Max(planLimit - planUsed, 0),
                    UsedPercent = totalPct,
                    ResetsAt = resetsAt,
                    Unit = ProviderQuotaUnit.Currency,
                    IsEstimated = false,
                });
            }

            if (autoPct is double auto && auto > 0)
            {
                buckets.Add(PercentBucket("cursor-auto", "Auto + Composer", auto, resetsAt));
            }

            if (apiPct is double api && api > 0)
            {
                buckets.Add(PercentBucket("cursor-api", "API usage", api, resetsAt));
            }
        }

        if (hasOnDemand)
        {
            individual.TryGetProperty("on_demand", out onDemand);
            if (onDemand.ValueKind != JsonValueKind.Object)
            {
                individual.TryGetProperty("onDemand", out onDemand);
            }

            var rawUsed = QuotaJson.FirstNumber(onDemand, "used") ?? 0;
            var rawLimit = QuotaJson.FirstNumber(onDemand, "limit") ?? 0;
            if (rawUsed > 0 || rawLimit > 0)
            {
                var odUsed = rawUsed / 100.0;
                var odLimit = rawLimit / 100.0;
                if (odUsed > 0 || odLimit > 0)
                {
                    var odPct = odLimit > 0 ? (odUsed / odLimit) * 100 : 0.0;
                    buckets.Add(new ProviderQuotaBucket
                    {
                        Key = "cursor-ondemand",
                        Label = "On-demand",
                        WindowKind = ProviderQuotaWindowKind.Monthly,
                        UsedValue = odUsed,
                        LimitValue = odLimit,
                        RemainingValue = odLimit > 0 ? Math.Max(odLimit - odUsed, 0) : (double?)null,
                        UsedPercent = odPct,
                        ResetsAt = resetsAt,
                        Unit = ProviderQuotaUnit.Currency,
                        IsEstimated = false,
                    });
                }
            }
        }

        var membership = ReadString(summary, "membership_type", "membershipType");
        var tier = string.IsNullOrEmpty(membership) ? "Cursor" : Capitalized(membership!);
        var emailSuffix = string.IsNullOrEmpty(userEmail) ? string.Empty : $" ({userEmail})";
        var unlimited = ReadBool(summary, "is_unlimited", "isUnlimited") == true;

        return new ProviderQuotaSnapshot
        {
            Provider = ProviderToken,
            FetchedAt = DateTimeOffset.UtcNow,
            Source = ProviderQuotaSourceKind.OfficialApi,
            Confidence = ProviderQuotaConfidence.Exact,
            ManagementUrl = ManagementUrl,
            StatusMessage = $"{tier}{emailSuffix} — {(unlimited ? "Unlimited" : "Capped")} plan.",
            Buckets = buckets,
        };
    }

    private static ProviderQuotaBucket PercentBucket(string key, string label, double pct, DateTimeOffset? resetsAt)
    {
        return new ProviderQuotaBucket
        {
            Key = key,
            Label = label,
            WindowKind = ProviderQuotaWindowKind.Monthly,
            UsedValue = pct,
            LimitValue = 100,
            RemainingValue = Math.Max(100 - pct, 0),
            UsedPercent = pct,
            ResetsAt = resetsAt,
            Unit = ProviderQuotaUnit.Percent,
            IsEstimated = false,
        };
    }

    private static string? ReadString(JsonElement obj, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (obj.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String)
            {
                var text = value.GetString();
                if (!string.IsNullOrEmpty(text))
                {
                    return text;
                }
            }
        }

        return null;
    }

    private static bool? ReadBool(JsonElement obj, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (obj.TryGetProperty(key, out var value))
            {
                if (value.ValueKind == JsonValueKind.True)
                {
                    return true;
                }

                if (value.ValueKind == JsonValueKind.False)
                {
                    return false;
                }
            }
        }

        return null;
    }

    /// <summary>
    /// Word-capitalise a membership string, matching Swift <c>String.capitalized</c>
    /// (first letter of each word upper, the rest lower).
    /// </summary>
    private static string Capitalized(string value)
    {
        return CultureInfo.InvariantCulture.TextInfo.ToTitleCase(value.ToLowerInvariant());
    }
}

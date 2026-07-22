using System;
using System.Collections.Generic;
using System.Text.Json;

namespace OpenBurnBar.App.Presentation.Quota;

// ── MECHANISM 1 · Claude Code statusline-hook payload ────────────────────────
//
// Portable parse half of the macOS Claude statusline bridge. The
// net8.0-windows adapter half — installing the `.cmd`/PowerShell statusline
// wrapper into `~/.claude/settings.json` and file-watching the emitted
// `snapshot.json` — is deferred (mirrors ClaudeQuotaBridgeManager +
// ClaudeStatuslineWatcher, both Windows-pathed). THIS file is the pure
// payload → ProviderQuotaSnapshot transform, portable and unit-tested on macOS.
//
// Parity sources (macOS):
//   • AgentLens/Services/ProviderQuota/ClaudeOAuthUsageFetcher.swift
//       ClaudeRateLimits.init(from:) — the window map parse (used/remaining/reset).
//   • AgentLens/Services/ProviderQuota/ClaudeQuotaAdapter.swift
//       claudeWindowCandidates + claudeQuotaBuckets(from:) — the bucket build,
//       and the statusline branch (localCLI / exact) that reads
//       payload["rate_limits"].

/// <summary>Parses a Claude Code statusline-hook snapshot payload into a quota snapshot.</summary>
public static class ClaudeStatuslineQuotaParser
{
    /// <summary>The Swift <c>AgentProvider.claudeCode.rawValue</c> token.</summary>
    public const string ProviderToken = "claudeCode";

    /// <summary>Swift <c>managementURL</c> for the statusline branch.</summary>
    public const string ManagementUrl = "https://code.claude.com/docs/en/statusline";

    /// <summary>Swift default status line for the local-bridge branch (no plan suffix).</summary>
    public const string DefaultStatusMessage =
        "Quota captured from Claude Code's local status line JSON bridge.";

    /// <summary>One parsed rate-limit window. Swift <c>ClaudeRateLimits.Window</c>.</summary>
    public sealed record Window(
        string Key,
        double? UsedPercentage,
        double? RemainingPercentage,
        DateTimeOffset? ResetsAt);

    /// <summary>Anthropic window keys → (label, kind). Swift <c>claudeWindowCandidates</c>.</summary>
    private static readonly (string Key, string Label, ProviderQuotaWindowKind Kind)[] WindowCandidates =
    {
        ("five_hour", "5-hour window", ProviderQuotaWindowKind.RollingHours),
        ("seven_day", "7-day window", ProviderQuotaWindowKind.RollingDays),
        ("seven_day_sonnet", "7-day Sonnet window", ProviderQuotaWindowKind.RollingDays),
        ("seven_day_opus", "7-day Opus window", ProviderQuotaWindowKind.RollingDays),
        ("seven_day_oauth_apps", "7-day OAuth Apps window", ProviderQuotaWindowKind.RollingDays),
    };

    private static readonly string[] UsedKeys =
        { "used_percentage", "usedPercent", "percentage", "utilization", "used" };

    private static readonly string[] RemainingKeys = { "remaining_percentage", "remainingPercent" };

    private static readonly string[] ResetKeys = { "resets_at", "reset_at", "resetTime" };

    /// <summary>
    /// Parse the full statusline snapshot JSON into a snapshot. Locates the
    /// <c>rate_limits</c> map (or the bare object) exactly like the Swift
    /// <c>ClaudeRateLimits.init(from data:)</c>, then builds the buckets.
    /// Returns a snapshot with an empty bucket list when no window carries a signal.
    /// </summary>
    public static ProviderQuotaSnapshot Parse(
        string json,
        DateTimeOffset fetchedAt,
        string? statusMessage = null)
    {
        return ClaudeStatuslineQuotaDomainCore.Apply(
            json,
            () => ParseLegacy(json, fetchedAt, statusMessage),
            fetchedAt,
            statusMessage ?? DefaultStatusMessage);
    }

    internal static ProviderQuotaSnapshot ParseLegacy(
        string json,
        DateTimeOffset fetchedAt,
        string? statusMessage = null)
    {
        var windows = ParseWindows(json);
        var buckets = BuildBuckets(windows);
        var legacy = new ProviderQuotaSnapshot
        {
            Provider = ProviderToken,
            FetchedAt = fetchedAt,
            Source = ProviderQuotaSourceKind.LocalCli,
            Confidence = ProviderQuotaConfidence.Exact,
            ManagementUrl = ManagementUrl,
            StatusMessage = statusMessage ?? DefaultStatusMessage,
            Buckets = buckets,
        };
        return legacy;
    }

    /// <summary>
    /// Parse the window map. Accepts either <c>{"rate_limits": {...}}</c> or the bare
    /// <c>{...}</c> map (Swift <c>ClaudeRateLimits.init(from data:)</c> accepts both).
    /// </summary>
    public static IReadOnlyDictionary<string, Window> ParseWindows(string json)
    {
        var root = QuotaJson.TryParse(json);
        if (root is not JsonElement element || element.ValueKind != JsonValueKind.Object)
        {
            return new Dictionary<string, Window>();
        }

        var bucket = element;
        if (element.TryGetProperty("rate_limits", out var nested) && nested.ValueKind == JsonValueKind.Object)
        {
            bucket = nested;
        }

        return ParseWindowMap(bucket);
    }

    /// <summary>Parse a rate-limits object map (Swift <c>ClaudeRateLimits.init(from dictionary:)</c>).</summary>
    public static IReadOnlyDictionary<string, Window> ParseWindowMap(JsonElement map)
    {
        var parsed = new Dictionary<string, Window>();
        if (map.ValueKind != JsonValueKind.Object)
        {
            return parsed;
        }

        foreach (var property in map.EnumerateObject())
        {
            if (property.Value.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            var used = QuotaJson.FirstNumber(property.Value, UsedKeys);
            var remaining = QuotaJson.FirstNumber(property.Value, RemainingKeys)
                ?? (used is double u ? Math.Max(0, 100 - u) : (double?)null);
            var reset = QuotaJson.FirstDate(property.Value, ResetKeys);

            if (used is null && remaining is null && reset is null)
            {
                continue;
            }

            parsed[property.Name] = new Window(property.Name, used, remaining, reset);
        }

        return parsed;
    }

    /// <summary>
    /// Build the percent buckets from the parsed windows. Faithful to
    /// <c>ClaudeQuotaAdapter.claudeQuotaBuckets(from:)</c>: only the candidate keys,
    /// only when a window carries a used-or-remaining signal.
    /// </summary>
    public static IReadOnlyList<ProviderQuotaBucket> BuildBuckets(IReadOnlyDictionary<string, Window> windows)
    {
        var buckets = new List<ProviderQuotaBucket>();
        foreach (var (key, label, windowKind) in WindowCandidates)
        {
            if (!windows.TryGetValue(key, out var window))
            {
                continue;
            }

            if (window.UsedPercentage is null && window.RemainingPercentage is null)
            {
                continue;
            }

            buckets.Add(new ProviderQuotaBucket
            {
                Key = $"claude-{QuotaJson.SanitizeKey(key)}",
                Label = label,
                WindowKind = windowKind,
                UsedValue = window.UsedPercentage,
                LimitValue = 100,
                RemainingValue = window.RemainingPercentage,
                UsedPercent = window.UsedPercentage,
                ResetsAt = window.ResetsAt,
                Unit = ProviderQuotaUnit.Percent,
                IsEstimated = false,
            });
        }

        return buckets;
    }
}

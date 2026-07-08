using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Quota;

/// <summary>
/// Maps B4 Firestore <c>quota_snapshots</c> rows (Mac-computed quota) into the workspace
/// <see cref="QuotaSampleAccount"/> view model without changing UI types.
/// </summary>
internal static class QuotaCloudAccountMapper
{
    public static IReadOnlyList<QuotaSampleAccount> ToAccounts(IReadOnlyList<CloudQuotaSnapshotRow> rows)
    {
        var accounts = new List<QuotaSampleAccount>();
        foreach (CloudQuotaSnapshotRow row in rows)
        {
            QuotaSampleAccount? account = ToAccount(row);
            if (account is not null)
            {
                accounts.Add(account);
            }
        }

        return accounts
            .OrderByDescending(a => a.Entry.Pressure)
            .ThenBy(a => a.Entry.DisplayName, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static QuotaSampleAccount? ToAccount(CloudQuotaSnapshotRow row)
    {
        if (!TryResolveProvider(row.ProviderToken, out AgentProviderBrand provider))
        {
            return null;
        }

        IReadOnlyList<CloudQuotaBucketRow> ordered = OrderBuckets(row.Buckets);
        if (ordered.Count == 0)
        {
            return null;
        }

        CloudQuotaBucketRow primary = ordered[0];
        double pressure = PressureFromBucket(primary);
        QuotaDialBucket? outer = ToDialBucket(ordered.ElementAtOrDefault(0));
        QuotaDialBucket? inner = ordered.Count > 1 ? ToDialBucket(ordered[1]) : null;

        string accountLabel = !string.IsNullOrWhiteSpace(row.AccountLabel)
            ? row.AccountLabel.Trim()
            : (!string.IsNullOrWhiteSpace(row.AccountId) ? row.AccountId.Trim() : "default");

        string entryId = $"{provider}:{accountLabel}";

        DateTimeOffset? nextReset = primary.ResetsAt ?? outer?.ResetsAt ?? inner?.ResetsAt;

        var entry = new SubscriptionEntry(
            id: entryId,
            provider: provider,
            accountLabel: accountLabel,
            pressure: pressure,
            hasDisplayableBucket: outer is not null || inner is not null,
            nextResetDate: nextReset,
            fetchedAt: row.FetchedAt);

        return new QuotaSampleAccount(entry, outer, inner);
    }

    private static IReadOnlyList<CloudQuotaBucketRow> OrderBuckets(IReadOnlyList<CloudQuotaBucketRow> buckets)
    {
        return buckets
            .OrderByDescending(WindowRank)
            .ThenBy(b => b.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static int WindowRank(CloudQuotaBucketRow bucket)
    {
        string? window = bucket.Window?.Trim();
        if (string.IsNullOrEmpty(window))
        {
            return 0;
        }

        return window.ToLowerInvariant() switch
        {
            "monthly" => 50,
            "weekly" => 40,
            "rollingdays" or "7day" => 35,
            "daily" => 30,
            "rollinghours" or "5hour" => 20,
            "custom" => 10,
            _ => 15,
        };
    }

    private static double PressureFromBucket(CloudQuotaBucketRow bucket)
    {
        if (bucket.Limit is > 0 && bucket.Used is double used)
        {
            return Math.Clamp(used / bucket.Limit.Value, 0, 1);
        }

        if (bucket.Remaining is double remaining && bucket.Limit is > 0)
        {
            return Math.Clamp(1 - remaining / bucket.Limit.Value, 0, 1);
        }

        if (bucket.Used is >= 0 and <= 100 && bucket.Limit is null or 100)
        {
            return Math.Clamp(bucket.Used.Value / 100, 0, 1);
        }

        if (bucket.Remaining is >= 0 and <= 100 && bucket.Limit is null or 100)
        {
            return Math.Clamp(1 - bucket.Remaining.Value / 100, 0, 1);
        }

        return 0.5;
    }

    private static QuotaDialBucket? ToDialBucket(CloudQuotaBucketRow? bucket)
    {
        if (bucket is null)
        {
            return null;
        }

        QuotaWindowKind kind = MapWindowKind(bucket.Window);
        DateTimeOffset? resetsAt = bucket.ResetsAt;

        if (bucket.Limit is > 0 && bucket.Remaining is double remaining)
        {
            return new QuotaDialBucket(
                kind,
                remainingValue: remaining,
                limitValue: bucket.Limit,
                resetsAt: resetsAt,
                label: bucket.Label);
        }

        if (bucket.Limit is > 0 && bucket.Used is double used)
        {
            double pct = Math.Clamp(used / bucket.Limit.Value * 100, 0, 100);
            return new QuotaDialBucket(kind, usedPercent: pct, resetsAt: resetsAt, label: bucket.Label);
        }

        if (bucket.Used is >= 0 and <= 100)
        {
            return new QuotaDialBucket(kind, usedPercent: bucket.Used, resetsAt: resetsAt, label: bucket.Label);
        }

        if (bucket.Remaining is >= 0 and <= 100)
        {
            double usedPct = Math.Clamp(100 - bucket.Remaining.Value, 0, 100);
            return new QuotaDialBucket(kind, usedPercent: usedPct, resetsAt: resetsAt, label: bucket.Label);
        }

        return null;
    }

    private static QuotaWindowKind MapWindowKind(string? window)
    {
        if (string.IsNullOrWhiteSpace(window))
        {
            return QuotaWindowKind.Custom;
        }

        return window.Trim().ToLowerInvariant() switch
        {
            "rollinghours" => QuotaWindowKind.RollingHours,
            "rollingdays" => QuotaWindowKind.RollingDays,
            "daily" => QuotaWindowKind.Daily,
            "weekly" => QuotaWindowKind.Weekly,
            "monthly" => QuotaWindowKind.Monthly,
            "lifetime" => QuotaWindowKind.Lifetime,
            _ => QuotaWindowKind.Custom,
        };
    }

    /// <summary>Swift <c>AgentProvider.fromPersistedToken</c> — normalize token to <see cref="AgentProviderBrand"/>.</summary>
    private static bool TryResolveProvider(string token, out AgentProviderBrand provider)
    {
        string normalized = token
            .Trim()
            .ToLowerInvariant()
            .Replace(" ", string.Empty, StringComparison.Ordinal)
            .Replace("-", string.Empty, StringComparison.Ordinal)
            .Replace("_", string.Empty, StringComparison.Ordinal);

        foreach (AgentProviderBrand candidate in Enum.GetValues<AgentProviderBrand>())
        {
            string canon = PersistedToken(candidate);
            if (canon == normalized)
            {
                provider = candidate;
                return true;
            }
        }

        provider = default;
        return false;
    }
    private static string PersistedToken(AgentProviderBrand brand) =>
        ProviderMetadata.DisplayName(brand)
            .ToLowerInvariant()
            .Replace(" ", string.Empty, StringComparison.Ordinal);
}
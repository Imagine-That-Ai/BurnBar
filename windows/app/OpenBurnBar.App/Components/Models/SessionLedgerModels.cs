// PORTED (hand-authored, parity-with-Swift) from:
//   AgentLens/Views/Components/SessionLedgerSection.swift
//     — SessionLedgerBucket (shortLabel, startOfBucket, sectionTitle),
//       SessionLedgerSupport (matchesSearch, groupedSessions)
//
// Pure, platform-agnostic (`System` only) so it compiles + runs on macOS and is asserted by
// windows/tests/components/SessionLedgerModelTests.cs. The WinUI control
// (Components/SessionLedgerSection) renders the grouped result. `TokenUsage` is represented
// by the display-only <see cref="SessionLedgerRow"/> value the shell maps its usage rows into.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace OpenBurnBar.App.Components;

/// <summary>Time bucket the ledger groups sessions into. Swift: <c>SessionLedgerBucket</c>.</summary>
public enum SessionLedgerBucket
{
    Hour,
    Day,
    Week,
    Month,
}

/// <summary>Display-only projection of a <c>TokenUsage</c> row, carrying the fields the ledger
/// searches, groups, and renders. The shell maps its real usage rows into this value.</summary>
public sealed class SessionLedgerRow
{
    public string Id { get; }
    public string ProjectName { get; }
    public string Model { get; }
    public string SessionId { get; }
    public string ProviderDisplayName { get; }
    public DateTimeOffset StartTime { get; }
    public double Cost { get; }
    public long TotalTokens { get; }
    public long CacheReadTokens { get; }

    public SessionLedgerRow(
        string id,
        string projectName,
        string model,
        string sessionId,
        string providerDisplayName,
        DateTimeOffset startTime,
        double cost,
        long totalTokens,
        long cacheReadTokens)
    {
        Id = id ?? string.Empty;
        ProjectName = projectName ?? string.Empty;
        Model = model ?? string.Empty;
        SessionId = sessionId ?? string.Empty;
        ProviderDisplayName = providerDisplayName ?? string.Empty;
        StartTime = startTime;
        Cost = cost;
        TotalTokens = totalTokens;
        CacheReadTokens = cacheReadTokens;
    }

    /// <summary>Swift: <c>SessionLedgerEntryRow.cacheEfficient</c> — over half the tokens were
    /// cache reads.</summary>
    public bool CacheEfficient => TotalTokens > 0 && (double)CacheReadTokens / TotalTokens > 0.5;
}

/// <summary>A grouped section of sessions under one bucket start. Swift: the tuple
/// <c>(bucketStart, title, sessions)</c> returned by <c>groupedSessions</c>.</summary>
public sealed class SessionLedgerGroup
{
    public DateTimeOffset BucketStart { get; }
    public string Title { get; }
    public IReadOnlyList<SessionLedgerRow> Sessions { get; }

    public SessionLedgerGroup(DateTimeOffset bucketStart, string title, IReadOnlyList<SessionLedgerRow> sessions)
    {
        BucketStart = bucketStart;
        Title = title;
        Sessions = sessions;
    }
}

/// <summary>Bucket labels + boundary + section-title math. Swift: <c>SessionLedgerBucket</c>.</summary>
public static class SessionLedgerBucketExtensions
{
    /// <summary>Swift: <c>SessionLedgerBucket.shortLabel</c>.</summary>
    public static string ShortLabel(this SessionLedgerBucket bucket) => bucket switch
    {
        SessionLedgerBucket.Hour => "Hour",
        SessionLedgerBucket.Day => "Day",
        SessionLedgerBucket.Week => "Week",
        SessionLedgerBucket.Month => "Month",
        _ => "Day",
    };

    /// <summary>Start of the bucket containing <paramref name="date"/>. Swift:
    /// <c>SessionLedgerBucket.startOfBucket(containing:calendar:)</c>. Weeks start Monday
    /// (ISO), matching the macOS <c>.weekOfYear</c> interval on the default calendar.</summary>
    public static DateTimeOffset StartOfBucket(this SessionLedgerBucket bucket, DateTimeOffset date)
    {
        switch (bucket)
        {
            case SessionLedgerBucket.Hour:
                return new DateTimeOffset(date.Year, date.Month, date.Day, date.Hour, 0, 0, date.Offset);
            case SessionLedgerBucket.Day:
                return new DateTimeOffset(date.Year, date.Month, date.Day, 0, 0, 0, date.Offset);
            case SessionLedgerBucket.Week:
            {
                DateTimeOffset startOfDay = new(date.Year, date.Month, date.Day, 0, 0, 0, date.Offset);
                int deltaFromMonday = ((int)startOfDay.DayOfWeek + 6) % 7; // Mon=0 … Sun=6
                return startOfDay.AddDays(-deltaFromMonday);
            }
            case SessionLedgerBucket.Month:
                return new DateTimeOffset(date.Year, date.Month, 1, 0, 0, 0, date.Offset);
            default:
                return date;
        }
    }

    /// <summary>Human section header for a bucket start. Swift:
    /// <c>SessionLedgerBucket.sectionTitle(for:calendar:)</c> (invariant-culture rendering;
    /// the macOS path uses the localized <c>.formatted</c> API).</summary>
    public static string SectionTitle(this SessionLedgerBucket bucket, DateTimeOffset bucketStart)
    {
        CultureInfo ci = CultureInfo.InvariantCulture;
        switch (bucket)
        {
            case SessionLedgerBucket.Hour:
                return bucketStart.ToString("MMM d, h:mm tt", ci);
            case SessionLedgerBucket.Day:
                return bucketStart.ToString("dddd, MMMM d, yyyy", ci);
            case SessionLedgerBucket.Week:
            {
                DateTimeOffset end = bucketStart.AddDays(6);
                return $"{bucketStart.ToString("MMM d", ci)} – {end.ToString("MMM d", ci)}, {bucketStart.ToString("yyyy", ci)}";
            }
            case SessionLedgerBucket.Month:
                return bucketStart.ToString("MMMM yyyy", ci);
            default:
                return bucketStart.ToString("d", ci);
        }
    }
}

/// <summary>Filtering + grouping. Swift: <c>SessionLedgerSupport</c>.</summary>
public static class SessionLedgerSupport
{
    /// <summary>Swift: <c>SessionLedgerSupport.matchesSearch(_:query:)</c>.</summary>
    public static bool MatchesSearch(SessionLedgerRow usage, string query)
    {
        string q = (query ?? string.Empty).Trim().ToLowerInvariant();
        if (q.Length == 0)
        {
            return true;
        }

        if (usage.ProjectName.ToLowerInvariant().Contains(q)) return true;
        if (usage.Model.ToLowerInvariant().Contains(q)) return true;
        if (usage.SessionId.ToLowerInvariant().Contains(q)) return true;
        if (usage.ProviderDisplayName.ToLowerInvariant().Contains(q)) return true;
        if (usage.Id.ToLowerInvariant().Contains(q)) return true;
        return false;
    }

    /// <summary>Group sessions into bucket sections, newest bucket first, sessions sorted
    /// newest-first inside each. Swift: <c>SessionLedgerSupport.groupedSessions(_:bucket:calendar:)</c>.</summary>
    public static IReadOnlyList<SessionLedgerGroup> GroupedSessions(
        IReadOnlyList<SessionLedgerRow> usages,
        SessionLedgerBucket bucket)
    {
        var sorted = (usages ?? Array.Empty<SessionLedgerRow>())
            .OrderByDescending(u => u.StartTime)
            .ToList();

        var buckets = new Dictionary<DateTimeOffset, List<SessionLedgerRow>>();
        foreach (SessionLedgerRow u in sorted)
        {
            DateTimeOffset key = bucket.StartOfBucket(u.StartTime);
            if (!buckets.TryGetValue(key, out List<SessionLedgerRow>? list))
            {
                list = new List<SessionLedgerRow>();
                buckets[key] = list;
            }

            list.Add(u);
        }

        return buckets.Keys
            .OrderByDescending(k => k)
            .Select(k => new SessionLedgerGroup(k, bucket.SectionTitle(k), buckets[k]))
            .ToList();
    }
}

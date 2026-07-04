using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.SessionLogs;

// PORTED (faithful) from the pure, unit-testable compute functions in
// AgentLens/Views/SessionLogs/SessionLogsView.swift:
//   static func computeFilteredLogs(...)   (source/device/search filter pass)
//   static func computeLogGroups(...)       (time / provider / project grouping)
//   private static func timeGroups/providerGroups/projectGroups(...)
//
// These are `static` in Swift precisely so `SessionLogGroupsCacheTests` can pin the
// matrix without a SwiftUI host; the same discipline lets `SessionLogGroupingTests`
// (a real `dotnet test`) pin it here without a WinUI host.

/// <summary>Pure filter + grouping passes for the session-logs command center.</summary>
public static class SessionLogGrouping
{
    /// <summary>
    /// Deterministic filter pass. Swift: <c>computeFilteredLogs</c>. When
    /// <paramref name="searchText"/> is non-empty on the Local data source, the caller
    /// supplies pre-matched ids (FTS/retrieval) via <paramref name="searchMatchedIds"/>
    /// and this projects them in rank order; on Cloud/iCloud it substring-filters.
    /// </summary>
    public static IReadOnlyList<SessionLogRecord> ComputeFilteredLogs(
        IReadOnlyList<SessionLogRecord> allLogs,
        SessionLogSourceFilter sourceFilter,
        string? deviceFilter,
        string? localDeviceId,
        string searchText,
        SessionLogDataSource dataSource,
        IReadOnlyList<string>? searchMatchedIds)
    {
        IEnumerable<SessionLogRecord> result = sourceFilter switch
        {
            SessionLogSourceFilter.Provider => allLogs.Where(r => r.SourceType == SessionLogSourceType.ProviderLog),
            SessionLogSourceFilter.Assistant => allLogs.Where(r => r.SourceType == SessionLogSourceType.CliAssistant),
            _ => allLogs,
        };

        if (!string.IsNullOrEmpty(deviceFilter))
        {
            result = result.Where(record =>
                record.IsRemote
                    ? record.SourceDeviceId == deviceFilter
                    : localDeviceId == deviceFilter);
        }

        var filtered = result.ToList();

        string trimmedQuery = (searchText ?? string.Empty).Trim();
        if (trimmedQuery.Length == 0)
        {
            return filtered;
        }

        if (dataSource == SessionLogDataSource.Local)
        {
            var byId = new Dictionary<string, SessionLogRecord>(StringComparer.Ordinal);
            foreach (var record in filtered)
            {
                byId[record.Id] = record;
            }

            var matched = new List<SessionLogRecord>();
            foreach (var id in searchMatchedIds ?? Array.Empty<string>())
            {
                if (byId.TryGetValue(id, out var record))
                {
                    matched.Add(record);
                }
            }

            return matched;
        }

        return SubstringFilter(filtered, trimmedQuery);
    }

    /// <summary>Case-insensitive substring match over the columns a human scans — title,
    /// project, provider, and transcript body. Swift: <c>substringFilteredLogs(from:query:)</c>
    /// (the Cloud/iCloud path). The Local path uses FTS/retrieval ids instead.</summary>
    public static IReadOnlyList<SessionLogRecord> SubstringFilter(IReadOnlyList<SessionLogRecord> logs, string query)
    {
        string q = query.Trim();
        if (q.Length == 0)
        {
            return logs;
        }

        return logs.Where(r =>
            Contains(r.DisplayTitle, q)
            || Contains(r.InferredTaskTitle, q)
            || Contains(r.ProjectName, q)
            || Contains(r.ProviderDisplayName, q)
            || Contains(r.Provider, q)
            || Contains(r.FullText, q)).ToList();
    }

    private static bool Contains(string? haystack, string needle) =>
        haystack is not null && haystack.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0;

    /// <summary>Deterministic grouping pass. Swift: <c>computeLogGroups(from:groupMode:now:)</c>.
    /// <paramref name="now"/> is injectable so the time buckets are unit-testable.</summary>
    public static IReadOnlyList<SessionLogGroup> ComputeLogGroups(
        IReadOnlyList<SessionLogRecord> logs,
        SessionLogGroupMode groupMode,
        DateTimeOffset now) => groupMode switch
        {
            SessionLogGroupMode.Provider => ProviderGroups(logs),
            SessionLogGroupMode.Project => ProjectGroups(logs),
            _ => TimeGroups(logs, now),
        };

    private static IReadOnlyList<SessionLogGroup> TimeGroups(IReadOnlyList<SessionLogRecord> logs, DateTimeOffset now)
    {
        var offset = now.Offset;
        var startOfToday = new DateTimeOffset(now.Year, now.Month, now.Day, 0, 0, 0, offset);
        var startOfYesterday = startOfToday.AddDays(-1);
        // Week starts Monday (ISO). Swift uses the locale's first weekday; Monday is the
        // deterministic choice the port's tests pin.
        int daysFromMonday = ((int)now.DayOfWeek - (int)DayOfWeek.Monday + 7) % 7;
        var startOfWeek = startOfToday.AddDays(-daysFromMonday);
        var startOfMonth = new DateTimeOffset(now.Year, now.Month, 1, 0, 0, 0, offset);

        var today = new List<SessionLogRecord>();
        var yesterday = new List<SessionLogRecord>();
        var week = new List<SessionLogRecord>();
        var month = new List<SessionLogRecord>();
        var older = new List<SessionLogRecord>();

        foreach (var log in logs)
        {
            var date = log.BucketDate;
            if (date >= startOfToday)
            {
                today.Add(log);
            }
            else if (date >= startOfYesterday)
            {
                yesterday.Add(log);
            }
            else if (date >= startOfWeek)
            {
                week.Add(log);
            }
            else if (date >= startOfMonth)
            {
                month.Add(log);
            }
            else
            {
                older.Add(log);
            }
        }

        var defs = new (string Id, string Title, string Icon, SessionLogAccent Accent, List<SessionLogRecord> Logs)[]
        {
            ("today", "Today", "", SessionLogAccent.Ember, today),
            ("yesterday", "Yesterday", "", SessionLogAccent.Amber, yesterday),
            ("week", "This Week", "", SessionLogAccent.Blaze, week),
            ("month", "This Month", "", SessionLogAccent.Whimsy, month),
            ("older", "Older", "", SessionLogAccent.Muted, older),
        };

        return defs
            .Where(d => d.Logs.Count != 0)
            .Select(d => new SessionLogGroup(d.Id, d.Title, d.Icon, d.Accent, null, d.Logs))
            .ToList();
    }

    private static IReadOnlyList<SessionLogGroup> ProviderGroups(IReadOnlyList<SessionLogRecord> logs) =>
        logs
            .GroupBy(l => l.Provider, StringComparer.Ordinal)
            .Select(g => new SessionLogGroup(
                Id: $"provider-{g.Key}",
                Title: g.First().ProviderDisplayName,
                SystemImage: "",
                Accent: SessionLogAccent.Amber,
                Provider: g.Key,
                Logs: g.ToList()))
            .OrderByDescending(g => g.Logs.Count)
            .ToList();

    private static IReadOnlyList<SessionLogGroup> ProjectGroups(IReadOnlyList<SessionLogRecord> logs) =>
        logs
            .GroupBy(l => l.ProjectName, StringComparer.Ordinal)
            .Select(g => new SessionLogGroup(
                Id: $"project-{g.Key}",
                Title: string.IsNullOrEmpty(g.Key) ? "Unknown" : g.Key,
                SystemImage: "",
                Accent: SessionLogAccent.Amber,
                Provider: null,
                Logs: g.ToList()))
            .OrderByDescending(g => g.Logs.Count)
            .ToList();
}

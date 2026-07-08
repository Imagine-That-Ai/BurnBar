using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.SessionLogs;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real tests for the pure filter + grouping passes ported from
/// SessionLogsView.swift's <c>computeFilteredLogs</c> / <c>computeLogGroups</c>. The
/// Swift originals are <c>static</c> so <c>SessionLogGroupsCacheTests</c> can pin the
/// matrix without a SwiftUI host; this pins the same matrix without a WinUI host.
/// </summary>
public sealed class SessionLogGroupingTests
{
    // Wednesday 2026-07-22 12:00Z — chosen so all five time buckets are reachable
    // (Monday/early-month `now` values collapse the week/month buckets).
    private static readonly DateTimeOffset Now = new(2026, 7, 22, 12, 0, 0, TimeSpan.Zero);

    private static SessionLogRecord Rec(
        string id,
        string provider = "Claude Code",
        string project = "Alpha",
        DateTimeOffset? start = null,
        SessionLogSourceType source = SessionLogSourceType.ProviderLog,
        string title = "",
        string fullText = "")
    {
        return new SessionLogRecord(
            Id: id,
            Provider: provider,
            ProviderDisplayName: provider,
            SessionId: "s-" + id,
            ProjectName: project,
            InferredTaskTitle: title.Length == 0 ? "Task " + id : title,
            FullText: fullText,
            MessageCount: 3,
            IndexedAt: start ?? Now,
            StartTime: start,
            SourceType: source);
    }

    private static IReadOnlyList<SessionLogRecord> Filter(
        IReadOnlyList<SessionLogRecord> logs,
        SessionLogSourceFilter sourceFilter = SessionLogSourceFilter.All,
        string search = "",
        SessionLogDataSource dataSource = SessionLogDataSource.Local,
        IReadOnlyList<string>? matched = null) =>
        SessionLogGrouping.ComputeFilteredLogs(logs, sourceFilter, null, null, search, dataSource, matched);

    [Fact]
    public void TimeGroups_BucketsByStartDate_InOrder()
    {
        var logs = new[]
        {
            Rec("today", start: new DateTimeOffset(2026, 7, 22, 9, 0, 0, TimeSpan.Zero)),
            Rec("yesterday", start: new DateTimeOffset(2026, 7, 21, 10, 0, 0, TimeSpan.Zero)),
            Rec("week", start: new DateTimeOffset(2026, 7, 20, 10, 0, 0, TimeSpan.Zero)),
            Rec("month", start: new DateTimeOffset(2026, 7, 10, 10, 0, 0, TimeSpan.Zero)),
            Rec("older", start: new DateTimeOffset(2026, 6, 15, 10, 0, 0, TimeSpan.Zero)),
        };

        var groups = SessionLogGrouping.ComputeLogGroups(logs, SessionLogGroupMode.Time, Now);

        Assert.Equal(new[] { "today", "yesterday", "week", "month", "older" }, groups.Select(g => g.Id));
        Assert.Equal(new[] { "Today", "Yesterday", "This Week", "This Month", "Older" }, groups.Select(g => g.Title));
        Assert.All(groups, g => Assert.Single(g.Logs));
        // Each group carries the record whose id names the bucket.
        Assert.Equal("today", groups[0].Logs[0].Id);
        Assert.Equal("older", groups[4].Logs[0].Id);
    }

    [Fact]
    public void TimeGroups_OmitsEmptyBuckets()
    {
        var logs = new[]
        {
            Rec("t1", start: new DateTimeOffset(2026, 7, 22, 9, 0, 0, TimeSpan.Zero)),
            Rec("o1", start: new DateTimeOffset(2026, 1, 1, 9, 0, 0, TimeSpan.Zero)),
        };

        var groups = SessionLogGrouping.ComputeLogGroups(logs, SessionLogGroupMode.Time, Now);

        Assert.Equal(new[] { "today", "older" }, groups.Select(g => g.Id));
    }

    [Fact]
    public void ProviderGroups_SortByCountDescending()
    {
        var logs = new[]
        {
            Rec("a", provider: "Claude Code"),
            Rec("b", provider: "Claude Code"),
            Rec("c", provider: "Codex"),
        };

        var groups = SessionLogGrouping.ComputeLogGroups(logs, SessionLogGroupMode.Provider, Now);

        Assert.Equal(2, groups.Count);
        Assert.Equal("Claude Code", groups[0].Title);
        Assert.Equal(2, groups[0].Logs.Count);
        Assert.Equal("Codex", groups[1].Title);
        Assert.Equal("provider-Claude Code", groups[0].Id);
        Assert.Equal("Claude Code", groups[0].Provider);
    }

    [Fact]
    public void ProjectGroups_MapEmptyProjectToUnknown_AndSortByCount()
    {
        var logs = new[]
        {
            Rec("a", project: "Alpha"),
            Rec("b", project: "Alpha"),
            Rec("c", project: ""),
        };

        var groups = SessionLogGrouping.ComputeLogGroups(logs, SessionLogGroupMode.Project, Now);

        Assert.Equal("Alpha", groups[0].Title);
        Assert.Equal(2, groups[0].Logs.Count);
        Assert.Equal("Unknown", groups[1].Title);
        Assert.Null(groups[1].Provider);
    }

    [Fact]
    public void SourceFilter_KeepsOnlyMatchingSourceType()
    {
        var logs = new[]
        {
            Rec("p1", source: SessionLogSourceType.ProviderLog),
            Rec("c1", source: SessionLogSourceType.CliAssistant),
        };

        Assert.Equal(new[] { "p1", "c1" }, Filter(logs, SessionLogSourceFilter.All).Select(r => r.Id));
        Assert.Equal(new[] { "p1" }, Filter(logs, SessionLogSourceFilter.Provider).Select(r => r.Id));
        Assert.Equal(new[] { "c1" }, Filter(logs, SessionLogSourceFilter.Assistant).Select(r => r.Id));
    }

    [Fact]
    public void LocalSearch_ProjectsMatchedIds_InRankOrder()
    {
        var logs = new[] { Rec("a"), Rec("b"), Rec("c") };

        // Local path projects the FTS/retrieval ids in the order given (best first),
        // dropping ids not in the filtered set.
        var result = Filter(logs, search: "run", dataSource: SessionLogDataSource.Local, matched: new[] { "b", "a", "zzz" });

        Assert.Equal(new[] { "b", "a" }, result.Select(r => r.Id));
    }

    [Fact]
    public void LocalSearch_EmptyMatched_YieldsNothing()
    {
        var logs = new[] { Rec("a"), Rec("b") };

        var result = Filter(logs, search: "nomatch", dataSource: SessionLogDataSource.Local, matched: Array.Empty<string>());

        Assert.Empty(result);
    }

    [Fact]
    public void CloudSearch_SubstringMatchesTitleProjectProviderAndBody()
    {
        var logs = new[]
        {
            Rec("a", project: "Alpha", title: "Refactor"),
            Rec("b", project: "Beta", title: "Fix login", fullText: "alpha particle notes"),
            Rec("c", project: "Gamma", title: "Docs"),
        };

        var result = Filter(logs, search: "alpha", dataSource: SessionLogDataSource.Cloud)
            .Select(r => r.Id)
            .OrderBy(x => x)
            .ToArray();

        // "a" matches on project; "b" matches on body text. "c" does not match.
        Assert.Equal(new[] { "a", "b" }, result);
    }

    [Fact]
    public void EmptySearch_ReturnsAllUnfiltered()
    {
        var logs = new[] { Rec("a"), Rec("b") };
        Assert.Equal(2, Filter(logs, search: "   ").Count);
    }
}

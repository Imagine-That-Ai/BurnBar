using System;
using System.Collections.Generic;
using OpenBurnBar.App.Components;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts the session-ledger model against SessionLedgerSection.swift.</summary>
public sealed class SessionLedgerModelTests
{
    private static SessionLedgerRow Row(
        string id, string project, string model, string session, string provider,
        DateTimeOffset start, double cost = 0, long total = 0, long cacheRead = 0) =>
        new(id, project, model, session, provider, start, cost, total, cacheRead);

    [Theory]
    [InlineData(SessionLedgerBucket.Hour, "Hour")]
    [InlineData(SessionLedgerBucket.Day, "Day")]
    [InlineData(SessionLedgerBucket.Week, "Week")]
    [InlineData(SessionLedgerBucket.Month, "Month")]
    public void ShortLabel(SessionLedgerBucket bucket, string expected) =>
        Assert.Equal(expected, bucket.ShortLabel());

    [Fact]
    public void StartOfBucket_hour_truncates_minutes()
    {
        var d = new DateTimeOffset(2026, 7, 3, 14, 37, 12, TimeSpan.Zero);
        Assert.Equal(new DateTimeOffset(2026, 7, 3, 14, 0, 0, TimeSpan.Zero), SessionLedgerBucket.Hour.StartOfBucket(d));
    }

    [Fact]
    public void StartOfBucket_day_is_midnight()
    {
        var d = new DateTimeOffset(2026, 7, 3, 14, 37, 12, TimeSpan.Zero);
        Assert.Equal(new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.Zero), SessionLedgerBucket.Day.StartOfBucket(d));
    }

    [Fact]
    public void StartOfBucket_week_starts_monday()
    {
        // 2026-07-03 is a Friday; the ISO week starts Monday 2026-06-29.
        var friday = new DateTimeOffset(2026, 7, 3, 9, 0, 0, TimeSpan.Zero);
        DateTimeOffset weekStart = SessionLedgerBucket.Week.StartOfBucket(friday);
        Assert.Equal(new DateTimeOffset(2026, 6, 29, 0, 0, 0, TimeSpan.Zero), weekStart);
        Assert.Equal(DayOfWeek.Monday, weekStart.DayOfWeek);
    }

    [Fact]
    public void StartOfBucket_month_is_first_of_month()
    {
        var d = new DateTimeOffset(2026, 7, 3, 14, 0, 0, TimeSpan.Zero);
        Assert.Equal(new DateTimeOffset(2026, 7, 1, 0, 0, 0, TimeSpan.Zero), SessionLedgerBucket.Month.StartOfBucket(d));
    }

    [Fact]
    public void MatchesSearch_empty_query_matches_all()
    {
        var row = Row("id", "proj", "model", "sess", "Codex", DateTimeOffset.Now);
        Assert.True(SessionLedgerSupport.MatchesSearch(row, ""));
        Assert.True(SessionLedgerSupport.MatchesSearch(row, "   "));
    }

    [Theory]
    [InlineData("proj")]      // project
    [InlineData("claude")]    // model (case-insensitive)
    [InlineData("SESS")]      // session id
    [InlineData("codex")]     // provider display name
    public void MatchesSearch_scans_each_field(string query)
    {
        var row = Row("id-123", "my-project", "claude-opus", "sess-abc", "Codex", DateTimeOffset.Now);
        Assert.True(SessionLedgerSupport.MatchesSearch(row, query));
    }

    [Fact]
    public void MatchesSearch_no_match_returns_false()
    {
        var row = Row("id", "proj", "model", "sess", "Codex", DateTimeOffset.Now);
        Assert.False(SessionLedgerSupport.MatchesSearch(row, "nonexistent"));
    }

    [Fact]
    public void GroupedSessions_buckets_newest_first_with_sorted_sessions()
    {
        var older = Row("a", "p", "m", "s", "Codex", new DateTimeOffset(2026, 7, 1, 10, 0, 0, TimeSpan.Zero));
        var newerSameDay = Row("b", "p", "m", "s", "Codex", new DateTimeOffset(2026, 7, 1, 18, 0, 0, TimeSpan.Zero));
        var newestDay = Row("c", "p", "m", "s", "Codex", new DateTimeOffset(2026, 7, 3, 9, 0, 0, TimeSpan.Zero));

        IReadOnlyList<SessionLedgerGroup> groups = SessionLedgerSupport.GroupedSessions(
            new List<SessionLedgerRow> { older, newestDay, newerSameDay },
            SessionLedgerBucket.Day);

        Assert.Equal(2, groups.Count);
        // Newest bucket (Jul 3) first.
        Assert.Equal("c", groups[0].Sessions[0].Id);
        // Jul 1 bucket: two sessions, newest-first.
        Assert.Equal(new[] { "b", "a" }, new[] { groups[1].Sessions[0].Id, groups[1].Sessions[1].Id });
    }

    [Fact]
    public void CacheEfficient_needs_majority_cache_reads()
    {
        Assert.True(Row("1", "p", "m", "s", "X", DateTimeOffset.Now, total: 100, cacheRead: 60).CacheEfficient);
        Assert.False(Row("2", "p", "m", "s", "X", DateTimeOffset.Now, total: 100, cacheRead: 40).CacheEfficient);
        Assert.False(Row("3", "p", "m", "s", "X", DateTimeOffset.Now, total: 0, cacheRead: 0).CacheEfficient);
    }

    [Fact]
    public void SectionTitle_month_and_week_render()
    {
        var jul = new DateTimeOffset(2026, 7, 1, 0, 0, 0, TimeSpan.Zero);
        Assert.Equal("July 2026", SessionLedgerBucket.Month.SectionTitle(jul));

        var weekStart = new DateTimeOffset(2026, 6, 29, 0, 0, 0, TimeSpan.Zero);
        Assert.Equal("Jun 29 – Jul 5, 2026", SessionLedgerBucket.Week.SectionTitle(weekStart));
    }
}

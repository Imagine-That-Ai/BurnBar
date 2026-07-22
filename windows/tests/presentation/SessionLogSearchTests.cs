using System;
using System.Linq;
using OpenBurnBar.App.Presentation.SessionLogs;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

public sealed class SessionLogSearchTests
{
    [Fact]
    public void EmptyQueryReturnsMostRecentRecordsWithStableTieBreak()
    {
        var records = new[]
        {
            Record("z", "Zulu", DateTimeOffset.Parse("2026-07-12T10:00:00Z")),
            Record("a", "Alpha", DateTimeOffset.Parse("2026-07-12T10:00:00Z")),
            Record("old", "Old", DateTimeOffset.Parse("2026-07-11T10:00:00Z")),
        };

        var result = SessionLogSearch.Rank(string.Empty, records, limit: 2);

        Assert.Equal(new[] { "a", "z" }, result.Select(record => record.Id));
    }

    [Fact]
    public void FtsIdsStayInProviderRankOrderAndUnknownIdsAreIgnored()
    {
        var records = new[]
        {
            Record("first", "First", DateTimeOffset.UtcNow),
            Record("second", "Second", DateTimeOffset.UtcNow),
        };

        var result = SessionLogSearch.Rank("query", records, new[] { "second", "missing", "first" });

        Assert.Equal(new[] { "second", "first" }, result.Select(record => record.Id));
    }

    [Fact]
    public void NonEmptyFtsResultDoesNotMixInMetadataOnlyRows()
    {
        var records = new[]
        {
            Record("fts", "Provider result", DateTimeOffset.UtcNow),
            Record("fallback", "Provider result", DateTimeOffset.UtcNow.AddMinutes(-1), project: "BurnBar"),
        };

        var result = SessionLogSearch.Rank("burnbar", records, new[] { "fts" });

        Assert.Equal(new[] { "fts" }, result.Select(record => record.Id));
    }

    [Fact]
    public void MetadataFallbackSupportsProjectAndSubsequenceSearch()
    {
        var records = new[]
        {
            Record("other", "Unrelated", DateTimeOffset.UtcNow, project: "docs"),
            Record("target", "Build release", DateTimeOffset.UtcNow.AddMinutes(-1), project: "BurnBar"),
        };

        var projectResult = SessionLogSearch.Rank("burn", records);
        var subsequenceResult = SessionLogSearch.Rank("br", records);

        Assert.Equal("target", Assert.Single(projectResult).Id);
        Assert.Equal("target", Assert.Single(subsequenceResult).Id);
    }

    [Fact]
    public void MultiTermSearchRequiresEveryTermAndHonorsLimit()
    {
        var records = new[]
        {
            Record("one", "Fix Windows parser", DateTimeOffset.UtcNow, project: "BurnBar"),
            Record("two", "Fix Windows parser", DateTimeOffset.UtcNow.AddMinutes(-1), project: "BurnBar"),
            Record("three", "Fix Windows parser", DateTimeOffset.UtcNow.AddMinutes(-2), project: "Other"),
        };

        var result = SessionLogSearch.Rank("windows burnbar", records, limit: 2);

        Assert.Equal(new[] { "one", "two" }, result.Select(record => record.Id));
    }

    private static SessionLogRecord Record(
        string id,
        string title,
        DateTimeOffset indexedAt,
        string project = "Project") =>
        new(
            Id: id,
            Provider: "codex",
            ProviderDisplayName: "Codex",
            SessionId: id,
            ProjectName: project,
            InferredTaskTitle: title,
            FullText: title,
            MessageCount: 1,
            IndexedAt: indexedAt);
}

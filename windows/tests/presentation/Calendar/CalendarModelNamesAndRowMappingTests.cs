using System;
using OpenBurnBar.App.Presentation.Calendar;
using OpenBurnBar.App.UsageRuntime;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Calendar;

/// <summary>
/// Pins the model-name normalization (parity:
/// <c>TokenExtractionUtility.normalizeModelKey/displayNameForModel</c>) and the
/// <see cref="CalendarUsageRow"/> mappers from the live engine + SQLCipher
/// records, including typed failure on corrupt timestamps.
/// </summary>
public sealed class CalendarModelNamesAndRowMappingTests
{
    [Theory]
    [InlineData("claude-opus-4-1", "claude-opus-4-1")]
    [InlineData("custom:gpt-5", "gpt-5")]
    [InlineData("Custom:GPT-5", "gpt-5")]
    [InlineData("vibeproxy: claude-opus-4-1", "claude-opus-4-1")]
    [InlineData("  codex-mini  ", "codex-mini")]
    public void NormalizeModelKey_strips_prefixes_and_lowercases(string raw, string expected)
    {
        Assert.Equal(expected, CalendarModelNames.NormalizeModelKey(raw));
    }

    [Theory]
    [InlineData("claude-opus-4-1", "Claude Opus 4 1")]
    [InlineData("gpt-5_codex", "Gpt 5 Codex")]
    [InlineData("", "")]
    public void DisplayNameForModel_title_cases_the_key(string raw, string expected)
    {
        Assert.Equal(expected, CalendarModelNames.DisplayNameForModel(raw));
    }

    [Fact]
    public void FromEngineRecord_maps_nano_cost_and_start_instant()
    {
        var record = new UsageEngineRecord
        {
            Id = "u-1",
            Provider = "Codex",
            SessionId = "sess-1",
            ProjectName = "proj",
            Model = "gpt-5",
            InputTokens = 10,
            OutputTokens = 5,
            TotalTokens = 15,
            CostNanoUsd = 2_500_000_000, // $2.50
            StartUnixMilliseconds = 1_783_000_000_000,
            UsageSource = "measured",
            ProviderId = "openai",
            ProvenanceMethod = "api",
            ProvenanceConfidence = "exact",
            EstimatorVersion = "v1",
        };

        CalendarUsageRow row = CalendarUsageRow.FromEngineRecord(record);

        Assert.Equal("u-1", row.Id);
        Assert.Equal(2.5, row.CostUsd, 9);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1_783_000_000_000), row.StartUtc);
        Assert.Equal(15, row.TotalTokens);
    }

    [Fact]
    public void FromEngineRecord_throws_typed_on_invalid_timestamp()
    {
        var record = new UsageEngineRecord
        {
            Id = "u-bad",
            Provider = "Codex",
            SessionId = "sess-1",
            ProjectName = "proj",
            Model = "gpt-5",
            StartUnixMilliseconds = long.MaxValue,
            UsageSource = "measured",
            ProviderId = "openai",
            ProvenanceMethod = "api",
            ProvenanceConfidence = "exact",
            EstimatorVersion = "v1",
        };

        CalendarUsageDataException ex = Assert.Throws<CalendarUsageDataException>(
            () => CalendarUsageRow.FromEngineRecord(record));
        Assert.Equal(CalendarUsageDataFailureKind.InvalidEngineRow, ex.Kind);
    }

    [Fact]
    public void FromStorageRecord_parses_the_grdb_datetime_codec()
    {
        var record = new TokenUsageRecord
        {
            Id = "u-2",
            Provider = "Claude Code",
            SessionId = "sess-9",
            ProjectName = "burnbar",
            Model = "claude-opus-4-1",
            Cost = 1.25,
            TotalTokens = 42,
            StartTime = "2026-07-06 10:15:30.500",
            EndTime = "2026-07-06 10:16:30.500",
            CreatedAt = "2026-07-06 10:16:31.000",
        };

        CalendarUsageRow row = CalendarUsageRow.FromStorageRecord(record);

        Assert.Equal("Claude Code", row.Provider);
        Assert.Equal(1.25, row.CostUsd);
        // Stored text is UTC (AssumeUniversal).
        Assert.Equal(new DateTimeOffset(2026, 7, 6, 10, 15, 30, 500, TimeSpan.Zero), row.StartUtc);
    }

    [Fact]
    public void FromStorageRecord_throws_typed_on_corrupt_start_time()
    {
        var record = new TokenUsageRecord
        {
            Id = "u-corrupt",
            Provider = "Codex",
            SessionId = "sess-1",
            ProjectName = "proj",
            Model = "gpt-5",
            StartTime = "not a timestamp",
            EndTime = "2026-07-06 10:16:30.500",
            CreatedAt = "2026-07-06 10:16:31.000",
        };

        CalendarUsageDataException ex = Assert.Throws<CalendarUsageDataException>(
            () => CalendarUsageRow.FromStorageRecord(record));
        Assert.Equal(CalendarUsageDataFailureKind.InvalidStorageRow, ex.Kind);
    }
}

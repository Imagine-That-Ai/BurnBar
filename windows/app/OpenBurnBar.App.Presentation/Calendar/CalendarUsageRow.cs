using System;
using System.Globalization;
using OpenBurnBar.App.UsageRuntime;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>Why a <see cref="CalendarUsageRow"/> could not be produced.</summary>
public enum CalendarUsageDataFailureKind
{
    /// <summary>A SQLCipher <c>token_usage</c> row carried an unparseable timestamp.</summary>
    InvalidStorageRow,

    /// <summary>The parser engine emitted a timestamp outside the representable range.</summary>
    InvalidEngineRow,
}

/// <summary>
/// Typed failure for corrupt usage rows. Corrupt timestamps are never silently
/// re-bucketed (that would fabricate an honest-looking day cell); the surface
/// degrades to a visible error state instead.
/// </summary>
public sealed class CalendarUsageDataException : Exception
{
    public CalendarUsageDataException(CalendarUsageDataFailureKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }

    public CalendarUsageDataException(CalendarUsageDataFailureKind kind, string message, Exception innerException)
        : base(message, innerException)
    {
        Kind = kind;
    }

    public CalendarUsageDataFailureKind Kind { get; }
}

/// <summary>
/// One usage event as the Calendar surface consumes it — the portable union of the
/// live runtime's <see cref="UsageEngineRecord"/>, the SQLCipher
/// <see cref="TokenUsageRecord"/>, and the decoded cloud usage doc. Parity:
/// <c>AgentLens/Services/Charts/CalendarDataService.swift</c> — sessions spanning
/// midnight are attributed to the local day their start time lands in, never split
/// and never UTC-truncated, so <see cref="StartUtc"/> is the bucketing instant.
/// </summary>
public sealed record CalendarUsageRow(
    string Id,
    string Provider,
    string SessionId,
    string ProjectName,
    string Model,
    long InputTokens,
    long OutputTokens,
    long CacheCreationTokens,
    long CacheReadTokens,
    long ReasoningTokens,
    long TotalTokens,
    double CostUsd,
    DateTimeOffset StartUtc)
{
    /// <summary>Maps a live-runtime engine row. <c>startUnixMilliseconds</c> is the bucket instant.</summary>
    public static CalendarUsageRow FromEngineRecord(UsageEngineRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        DateTimeOffset startUtc;
        try
        {
            startUtc = DateTimeOffset.FromUnixTimeMilliseconds(record.StartUnixMilliseconds);
        }
        catch (ArgumentOutOfRangeException ex)
        {
            throw new CalendarUsageDataException(
                CalendarUsageDataFailureKind.InvalidEngineRow,
                $"The parser engine returned an invalid start timestamp for usage '{record.Id}'.",
                ex);
        }

        return new CalendarUsageRow(
            record.Id,
            record.Provider,
            record.SessionId,
            record.ProjectName ?? string.Empty,
            record.Model,
            record.InputTokens,
            record.OutputTokens,
            record.CacheCreationTokens,
            record.CacheReadTokens,
            record.ReasoningTokens,
            record.TotalTokens,
            record.CostUsd,
            startUtc);
    }

    /// <summary>
    /// Maps a SQLCipher <c>token_usage</c> row. <c>startTime</c> is ISO-ish UTC text
    /// ("yyyy-MM-dd HH:mm:ss.fff", the GRDB <c>.datetime</c> codec) and is the bucket instant.
    /// </summary>
    public static CalendarUsageRow FromStorageRecord(TokenUsageRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        if (!DateTimeOffset.TryParse(
                record.StartTime,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out DateTimeOffset startUtc))
        {
            throw new CalendarUsageDataException(
                CalendarUsageDataFailureKind.InvalidStorageRow,
                $"Encrypted usage storage returned an unparseable startTime for usage '{record.Id}'.");
        }

        return new CalendarUsageRow(
            record.Id,
            record.Provider,
            record.SessionId,
            record.ProjectName ?? string.Empty,
            record.Model,
            record.InputTokens,
            record.OutputTokens,
            record.CacheCreationTokens,
            record.CacheReadTokens,
            record.ReasoningTokens,
            record.TotalTokens,
            record.Cost,
            startUtc);
    }
}

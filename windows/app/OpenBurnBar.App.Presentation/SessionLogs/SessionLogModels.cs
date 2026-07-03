using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.SessionLogs;

// PORTED (record + enum subset) from:
//   AgentLens/Models/ConversationRecord.swift   (the record shape)
//   AgentLens/Views/SessionLogs/SessionLogsView.swift  (the filter/group enums + SessionLogGroup)
//
// The Windows list-detail surface reads exactly these fields. The Swift
// ConversationRecord carries cloud/iCloud/tombstone/version columns that the port's
// read seam does not surface yet (local read-only first); those are additive and
// omitted here to keep the presentation layer dependency-free and testable.

/// <summary>Discriminates indexed provider transcripts from the in-app CLI assistant log.
/// Swift: <c>enum ConversationSourceType</c>.</summary>
public enum SessionLogSourceType
{
    ProviderLog,
    CliAssistant,
}

/// <summary>Source-type filter chips. Swift: <c>enum SessionLogSourceFilter</c>.</summary>
public enum SessionLogSourceFilter
{
    All,
    Provider,
    Assistant,
}

/// <summary>How the command-center list is grouped. Swift: <c>enum SessionLogGroupMode</c>.</summary>
public enum SessionLogGroupMode
{
    Time,
    Provider,
    Project,
}

/// <summary>Which store the logs are read from. Swift: <c>enum SessionLogDataSource</c>.</summary>
public enum SessionLogDataSource
{
    Local,
    Cloud,
    ICloud,
}

/// <summary>
/// Indexed session transcript + metadata for the list-detail surface. Swift:
/// <c>struct ConversationRecord</c> (the subset the list/detail read).
/// </summary>
public sealed record SessionLogRecord(
    string Id,
    string Provider,
    string ProviderDisplayName,
    string SessionId,
    string ProjectName,
    string InferredTaskTitle,
    string FullText,
    int MessageCount,
    DateTimeOffset IndexedAt,
    string? SummaryTitle = null,
    string? Summary = null,
    string? SummaryModel = null,
    int UserWordCount = 0,
    int AssistantWordCount = 0,
    DateTimeOffset? StartTime = null,
    DateTimeOffset? EndTime = null,
    DateTimeOffset? FileModifiedAt = null,
    SessionLogSourceType SourceType = SessionLogSourceType.ProviderLog,
    bool IsRemote = false,
    string? SourceDeviceId = null,
    string? SourceDeviceName = null)
{
    /// <summary>Which instant a record buckets under in Time grouping — start first,
    /// then end, then file-mtime, then indexed. Swift: the <c>timeGroups</c> date pick.</summary>
    public DateTimeOffset BucketDate => StartTime ?? EndTime ?? FileModifiedAt ?? IndexedAt;

    /// <summary>Timeline instant used for the row's relative timestamp. Swift: the row's
    /// <c>timeLabel</c> (end → start → indexed).</summary>
    public DateTimeOffset TimelineDate => EndTime ?? StartTime ?? IndexedAt;

    /// <summary>Preferred list/detail title. Swift: <c>displayTitle</c> (summaryTitle → inferred → "Session").</summary>
    public string DisplayTitle =>
        !string.IsNullOrWhiteSpace(SummaryTitle)
            ? SummaryTitle!.Trim()
            : (string.IsNullOrEmpty(InferredTaskTitle) ? "Session" : InferredTaskTitle);
}

/// <summary>Semantic accent token for a group header. The XAML maps the token to the
/// matching Pensieve brush; keeping it a token (not a color) keeps this layer
/// dependency-free while preserving the Swift per-group accent choice.</summary>
public enum SessionLogAccent
{
    Ember,
    Amber,
    Blaze,
    Whimsy,
    Muted,
}

/// <summary>
/// One collapsible list section. Swift: <c>struct SessionLogGroup</c> (accent color
/// replaced by <see cref="Accent"/> token for the portable layer).
/// </summary>
public sealed record SessionLogGroup(
    string Id,
    string Title,
    string SystemImage,
    SessionLogAccent Accent,
    string? Provider,
    IReadOnlyList<SessionLogRecord> Logs)
{
    /// <summary>Count shown in the section header pill.</summary>
    public int Count => Logs.Count;
}

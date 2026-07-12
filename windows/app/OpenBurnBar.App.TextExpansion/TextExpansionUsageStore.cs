using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.TextExpansion;

/// <summary>One snippet's usage statistics. Faithful port of Swift <c>TextExpansionUsageRecord</c>.</summary>
public sealed class TextExpansionUsageRecord
{
    public TextExpansionUsageRecord(int count = 0, DateTimeOffset? lastUsedAt = null)
    {
        Count = count;
        LastUsedAt = lastUsedAt ?? DateTimeOffset.MinValue;
    }

    public int Count { get; }

    public DateTimeOffset LastUsedAt { get; }
}

/// <summary>
/// The full usage ledger: snippet id → usage record. Immutable value that produces a
/// new copy on increment. Faithful port of Swift <c>TextExpansionUsageLog</c>.
/// </summary>
public sealed class TextExpansionUsageLog
{
    public TextExpansionUsageLog(
        int schemaVersion = 1,
        IReadOnlyDictionary<string, TextExpansionUsageRecord>? records = null)
    {
        SchemaVersion = schemaVersion;
        Records = records ?? new Dictionary<string, TextExpansionUsageRecord>(StringComparer.Ordinal);
    }

    public int SchemaVersion { get; }

    public IReadOnlyDictionary<string, TextExpansionUsageRecord> Records { get; }

    public TextExpansionUsageRecord? Record(string id) =>
        Records.TryGetValue(id, out var record) ? record : null;

    /// <summary>Swift <c>incrementing(_:at:)</c>: bump count, advance lastUsedAt to max(existing, date).</summary>
    public TextExpansionUsageLog Incrementing(string id, DateTimeOffset date)
    {
        var updated = new Dictionary<string, TextExpansionUsageRecord>(Records, StringComparer.Ordinal);
        var existing = updated.TryGetValue(id, out var record) ? record : new TextExpansionUsageRecord();
        var lastUsed = date > existing.LastUsedAt ? date : existing.LastUsedAt;
        updated[id] = new TextExpansionUsageRecord(existing.Count + 1, lastUsed);
        return new TextExpansionUsageLog(SchemaVersion, updated);
    }
}

/// <summary>
/// Pure usage-ranking helper. Faithful port of Swift <c>TextExpansionUsageStore.rank</c>:
/// most-used first, then most-recently-used, then case-insensitive title as the
/// stable final tiebreaker.
/// </summary>
public static class TextExpansionUsageRanker
{
    public static IReadOnlyList<TextExpansionSnippet> Rank(
        IReadOnlyList<TextExpansionSnippet> snippets,
        TextExpansionUsageLog log)
    {
        return snippets
            .OrderByDescending(s => log.Record(s.Id)?.Count ?? 0)
            .ThenByDescending(s => log.Record(s.Id)?.LastUsedAt ?? DateTimeOffset.MinValue)
            .ThenBy(s => s.Title, StringComparer.InvariantCultureIgnoreCase)
            .ToList();
    }
}

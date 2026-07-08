using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.SessionLogs;
using StorageRecord = OpenBurnBar.Storage.ConversationRecord;

namespace OpenBurnBar.Storage.SessionLogs;

/// <summary>
/// Adapts the SQLCipher DataStore read seam (<see cref="IConversationReadStore"/>,
/// VAL-P0-DB-010) to the presentation-side <see cref="ISessionLogReadSource"/> the
/// WinUI list-detail view-model consumes. This is the real Windows read path from the
/// shared Mac-produced encrypted database into the session-logs surface — the Windows
/// analog of the macOS <c>DataStore.fetchConversations</c> / FTS search the SwiftUI
/// view drives.
///
/// Read-only and synchronous underneath (the store queries a single keyed connection);
/// the async signatures satisfy the seam and let a future streaming/off-thread
/// implementation slot in without touching callers. Exercised end-to-end on macOS by
/// StorageSessionLogReadSourceTests against the committed fixture.
/// </summary>
public sealed class StorageSessionLogReadSource : ISessionLogReadSource
{
    private readonly IConversationReadStore _store;

    public StorageSessionLogReadSource(IConversationReadStore store)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
    }

    /// <inheritdoc />
    public Task<IReadOnlyList<SessionLogRecord>> ListAsync(int limit = 200, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        IReadOnlyList<SessionLogRecord> mapped = _store
            .ListConversations(limit)
            .Select(Map)
            .ToList();
        return Task.FromResult(mapped);
    }

    /// <inheritdoc />
    public Task<IReadOnlyList<string>> SearchMatchingIdsAsync(string query, int limit = 200, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        string match = BuildFtsMatch(query);
        if (match.Length == 0)
        {
            return Task.FromResult((IReadOnlyList<string>)Array.Empty<string>());
        }

        IReadOnlyList<string> ids;
        try
        {
            ids = _store
                .SearchConversationsFts(match, limit)
                .Select(r => r.Conversation.Id)
                .ToList();
        }
        catch (Exception)
        {
            // A malformed FTS expression (or an FTS-less DB) must not crash search;
            // surface no matches, mirroring the macOS retrieval-search failure path.
            ids = Array.Empty<string>();
        }

        return Task.FromResult(ids);
    }

    /// <summary>
    /// Projects a storage row onto the presentation record. The storage read seam
    /// surfaces the identity + indexed-text columns; timeline/summary columns that the
    /// macOS record also carries are not in the read seam yet, so Time grouping buckets
    /// on <c>IndexedAt</c> here (still the correct "last known activity" fallback the
    /// Swift picker uses when start/end are absent).
    /// </summary>
    private static SessionLogRecord Map(StorageRecord record)
    {
        var indexedAt = ParseTimestamp(record.IndexedAt);
        return new SessionLogRecord(
            Id: record.Id,
            Provider: record.Provider,
            ProviderDisplayName: record.Provider,
            SessionId: record.SessionId,
            ProjectName: record.ProjectName,
            InferredTaskTitle: record.InferredTaskTitle,
            FullText: record.FullText,
            MessageCount: (int)Math.Clamp(record.MessageCount, int.MinValue, int.MaxValue),
            IndexedAt: indexedAt,
            SourceType: SessionLogSourceType.ProviderLog);
    }

    private static DateTimeOffset ParseTimestamp(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return DateTimeOffset.UnixEpoch;
        }

        if (DateTimeOffset.TryParse(
                value,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var parsed))
        {
            return parsed;
        }

        return DateTimeOffset.UnixEpoch;
    }

    /// <summary>
    /// Sanitizes a free-text query into a safe FTS5 MATCH expression: each alphanumeric
    /// token becomes a quoted term (phrase), joined by implicit AND. Quoting prevents a
    /// stray operator/quote in user input from throwing an FTS5 syntax error; empty
    /// input yields an empty match (caller returns no results).
    /// </summary>
    public static string BuildFtsMatch(string query)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            return string.Empty;
        }

        var terms = query
            .Split(new[] { ' ', '\t', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(t => new string(t.Where(char.IsLetterOrDigit).ToArray()))
            .Where(t => t.Length != 0)
            .Select(t => "\"" + t + "\"");

        return string.Join(" ", terms);
    }
}

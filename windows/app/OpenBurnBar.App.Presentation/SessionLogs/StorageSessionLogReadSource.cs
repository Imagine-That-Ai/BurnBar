using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Storage;
using StorageRecord = OpenBurnBar.Storage.ConversationRecord;

namespace OpenBurnBar.App.Presentation.SessionLogs;

/// <summary>
/// Adapts the SQLCipher <see cref="IConversationReadStore"/> (VAL-P0-DB-010) to
/// <see cref="ISessionLogReadSource"/> for the WinUI list-detail surface. Wired from
/// <see cref="OpenBurnBar.App.Storage.WindowsStorageDevHost"/> when SQLCipher credentials
/// are configured.
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
        var rows = _store.ListConversations(limit);
        IReadOnlyList<SessionLogRecord> mapped = rows.Select(Map).ToList();
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
            ids = Array.Empty<string>();
        }

        return Task.FromResult(ids);
    }

    private static SessionLogRecord Map(StorageRecord record)
    {
        DateTimeOffset indexedAt = ParseTimestamp(record.IndexedAt);
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
                out DateTimeOffset parsed))
        {
            return parsed;
        }

        return DateTimeOffset.UnixEpoch;
    }

    /// <summary>
    /// Sanitizes a free-text query into a safe FTS5 MATCH expression.
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
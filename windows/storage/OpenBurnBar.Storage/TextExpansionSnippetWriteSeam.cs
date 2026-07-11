using System;
using System.Collections.Generic;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// Windows write/read seam for <c>text_expansion_snippets</c> — peer of the Mac GRDB
/// <c>TextExpansionSnippetStore</c> (AgentLens/Services/DataStore/
/// TextExpansionSnippetStore.swift) over the same v43 migration schema
/// (<c>v43_text_expansion_snippets</c>). Faithful to the Mac store's SQL: the same
/// upsert column set + <c>ON CONFLICT(id)</c> update, the same soft-delete that bumps
/// <c>revision</c> and nulls <c>syncedAt</c>, and the same unsynced predicate
/// (<c>syncedAt IS NULL OR syncedAt &lt; updatedAt</c>).
/// </summary>
/// <remarks>
/// Dates are persisted as ISO-8601 UTC text via <see cref="StorageDateCodec"/> — the
/// same convention the sibling sync seam <see cref="BudgetRuleWriteSeam"/> uses, and
/// accepted on reopen by the Mac <c>OpenBurnBarDatabase.parseDateValue</c> ISO fallback.
/// The trigger is canonicalized (trim, strip leading <c>&amp;&amp;</c>, lowercase) before
/// persist, matching the Mac store so the <c>text_expansion_snippets_trigger_active_idx</c>
/// unique-active-trigger invariant holds identically on both platforms.
/// </remarks>
public static class TextExpansionSnippetWriteSeam
{
    public static int Upsert(SqliteConnection connection, TextExpansionSnippetRow row, bool markUnsynced = true)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(row);

        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO text_expansion_snippets (
                id, title, trigger, body, mode, isEnabled, scopeJSON, revision,
                createdAt, updatedAt, deletedAt, syncedAt, sourceDeviceID
            ) VALUES (
                $id, $title, $trigger, $body, $mode, $isEnabled, $scopeJSON, $revision,
                $createdAt, $updatedAt, $deletedAt, $syncedAt, $sourceDeviceID
            )
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                trigger = excluded.trigger,
                body = excluded.body,
                mode = excluded.mode,
                isEnabled = excluded.isEnabled,
                scopeJSON = excluded.scopeJSON,
                revision = excluded.revision,
                createdAt = excluded.createdAt,
                updatedAt = excluded.updatedAt,
                deletedAt = excluded.deletedAt,
                syncedAt = excluded.syncedAt,
                sourceDeviceID = excluded.sourceDeviceID
            """;

        string canonicalTrigger = CanonicalizeTrigger(row.Trigger);
        command.Parameters.AddWithValue("$id", row.Id);
        command.Parameters.AddWithValue("$title", row.Title);
        command.Parameters.AddWithValue("$trigger", canonicalTrigger);
        command.Parameters.AddWithValue("$body", row.Body);
        command.Parameters.AddWithValue("$mode", row.Mode);
        command.Parameters.AddWithValue("$isEnabled", row.IsEnabled ? 1 : 0);
        command.Parameters.AddWithValue("$scopeJSON", row.ScopeJson);
        command.Parameters.AddWithValue("$revision", row.Revision);
        command.Parameters.AddWithValue("$createdAt", StorageDateCodec.ToIso(row.CreatedAt));
        command.Parameters.AddWithValue("$updatedAt", StorageDateCodec.ToIso(row.UpdatedAt));
        command.Parameters.AddWithValue("$deletedAt", row.DeletedAt is DateTimeOffset deleted ? StorageDateCodec.ToIso(deleted) : DBNull.Value);
        object syncedValue = markUnsynced || row.SyncedAt is not DateTimeOffset synced
            ? DBNull.Value
            : StorageDateCodec.ToIso(synced);
        command.Parameters.AddWithValue("$syncedAt", syncedValue);
        command.Parameters.AddWithValue("$sourceDeviceID", (object?)row.SourceDeviceId ?? DBNull.Value);

        int affected = command.ExecuteNonQuery();
        transaction.Commit();
        return affected;
    }

    public static List<TextExpansionSnippetRow> FetchAll(SqliteConnection connection, bool includeDeleted = false)
    {
        ArgumentNullException.ThrowIfNull(connection);
        using var command = connection.CreateCommand();
        command.CommandText = includeDeleted
            ? "SELECT * FROM text_expansion_snippets ORDER BY updatedAt DESC, title ASC"
            : "SELECT * FROM text_expansion_snippets WHERE deletedAt IS NULL ORDER BY updatedAt DESC, title ASC";
        return ReadAll(command);
    }

    public static List<TextExpansionSnippetRow> FetchUnsynced(SqliteConnection connection, int limit = 200)
    {
        ArgumentNullException.ThrowIfNull(connection);
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT * FROM text_expansion_snippets
            WHERE syncedAt IS NULL OR syncedAt < updatedAt
            ORDER BY updatedAt ASC
            LIMIT $limit
            """;
        command.Parameters.AddWithValue("$limit", Math.Max(0, limit));
        return ReadAll(command);
    }

    public static int MarkSynced(SqliteConnection connection, IReadOnlyList<string> ids, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(ids);
        if (ids.Count == 0)
        {
            return 0;
        }

        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;

        var placeholders = new string[ids.Count];
        for (int i = 0; i < ids.Count; i++)
        {
            placeholders[i] = $"$id{i}";
            command.Parameters.AddWithValue($"$id{i}", ids[i]);
        }

        command.Parameters.AddWithValue("$syncedAt", StorageDateCodec.ToIso(at));
        command.CommandText =
            $"UPDATE text_expansion_snippets SET syncedAt = $syncedAt WHERE id IN ({string.Join(", ", placeholders)})";

        int affected = command.ExecuteNonQuery();
        transaction.Commit();
        return affected;
    }

    public static int Delete(SqliteConnection connection, string id, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(connection);
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            UPDATE text_expansion_snippets
            SET deletedAt = $at, updatedAt = $at, syncedAt = NULL, isEnabled = 0, revision = revision + 1
            WHERE id = $id
            """;
        command.Parameters.AddWithValue("$at", StorageDateCodec.ToIso(at));
        command.Parameters.AddWithValue("$id", id);
        int affected = command.ExecuteNonQuery();
        transaction.Commit();
        return affected;
    }

    public static long Count(SqliteConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(1) FROM text_expansion_snippets WHERE deletedAt IS NULL";
        return Convert.ToInt64(command.ExecuteScalar());
    }

    public static TextExpansionSnippetRow? Read(SqliteConnection connection, string id)
    {
        ArgumentNullException.ThrowIfNull(connection);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM text_expansion_snippets WHERE id = $id LIMIT 1";
        command.Parameters.AddWithValue("$id", id);
        using var reader = command.ExecuteReader();
        return reader.Read() ? ReadRow(reader) : null;
    }

    private static List<TextExpansionSnippetRow> ReadAll(SqliteCommand command)
    {
        var list = new List<TextExpansionSnippetRow>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            list.Add(ReadRow(reader));
        }

        return list;
    }

    private static TextExpansionSnippetRow ReadRow(SqliteDataReader reader)
    {
        return new TextExpansionSnippetRow(
            Id: reader.GetString(reader.GetOrdinal("id")),
            Title: reader.GetString(reader.GetOrdinal("title")),
            Trigger: reader.GetString(reader.GetOrdinal("trigger")),
            Body: reader.GetString(reader.GetOrdinal("body")),
            Mode: reader.GetString(reader.GetOrdinal("mode")),
            IsEnabled: reader.GetInt64(reader.GetOrdinal("isEnabled")) != 0,
            ScopeJson: reader.GetString(reader.GetOrdinal("scopeJSON")),
            Revision: (int)reader.GetInt64(reader.GetOrdinal("revision")),
            CreatedAt: StorageDateCodec.FromIso(GetStringOrNull(reader, "createdAt")),
            UpdatedAt: StorageDateCodec.FromIso(GetStringOrNull(reader, "updatedAt")),
            DeletedAt: GetDateOrNull(reader, "deletedAt"),
            SyncedAt: GetDateOrNull(reader, "syncedAt"),
            SourceDeviceId: GetStringOrNull(reader, "sourceDeviceID"));
    }

    private static string? GetStringOrNull(SqliteDataReader reader, string column)
    {
        int ord = reader.GetOrdinal(column);
        return reader.IsDBNull(ord) ? null : reader.GetString(ord);
    }

    private static DateTimeOffset? GetDateOrNull(SqliteDataReader reader, string column)
    {
        string? text = GetStringOrNull(reader, column);
        return string.IsNullOrWhiteSpace(text) ? null : StorageDateCodec.FromIso(text);
    }

    /// <summary>Trim, strip every leading <c>&amp;&amp;</c>, lowercase — mirrors Swift <c>TextExpansionTrigger.canonicalName</c>.</summary>
    private static string CanonicalizeTrigger(string raw)
    {
        string value = raw.Trim();
        while (value.StartsWith("&&", StringComparison.Ordinal))
        {
            value = value.Substring(2);
        }

        return value.ToLowerInvariant();
    }
}

/// <summary>
/// A row of <c>text_expansion_snippets</c>. Storage-local record (peer of
/// <see cref="BudgetRuleRow"/>); the portable <c>TextExpansionSnippet</c> domain model
/// lives in OpenBurnBar.App.TextExpansion and is mapped to/from this row by the caller.
/// </summary>
public sealed record TextExpansionSnippetRow(
    string Id,
    string Title,
    string Trigger,
    string Body,
    string Mode,
    bool IsEnabled,
    string ScopeJson,
    int Revision,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt,
    DateTimeOffset? SyncedAt,
    string? SourceDeviceId);

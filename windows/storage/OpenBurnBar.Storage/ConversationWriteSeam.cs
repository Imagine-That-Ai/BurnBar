using System;
using System.Collections.Generic;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>Writable projection for parser-produced local conversations.</summary>
public sealed record ConversationWriteRecord
{
    public required string Id { get; init; }
    public required string Provider { get; init; }
    public required string SessionId { get; init; }
    public required string ProjectName { get; init; }
    public required string InferredTaskTitle { get; init; }
    public required string FullText { get; init; }
    public string? IndexedAt { get; init; }
    public long MessageCount { get; init; }
    public string? WorkingDirectory { get; init; }
}

/// <summary>
/// Atomic Windows peer of the macOS conversation upsert. Uses UPDATE-style
/// conflict handling so the external-content FTS table does not accumulate the
/// orphan rows historically caused by INSERT OR REPLACE.
/// </summary>
public static class ConversationWriteSeam
{
    /// <summary>Compatibility entry point for existing storage callers.</summary>
    public static int WriteConversations(
        SqliteConnection connection,
        IReadOnlyList<ConversationRecord> records)
    {
        ArgumentNullException.ThrowIfNull(records);
        var writable = new ConversationWriteRecord[records.Count];
        for (int index = 0; index < records.Count; index++)
        {
            ConversationRecord record = records[index];
            writable[index] = new ConversationWriteRecord
            {
                Id = record.Id,
                Provider = record.Provider,
                SessionId = record.SessionId,
                ProjectName = record.ProjectName,
                InferredTaskTitle = record.InferredTaskTitle,
                FullText = record.FullText,
                IndexedAt = record.IndexedAt,
                MessageCount = record.MessageCount,
            };
        }
        return WriteConversationBatch(connection, writable);
    }

    public static int WriteConversationBatch(
        SqliteConnection connection,
        IEnumerable<ConversationWriteRecord> records)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(records);

        using var transaction = connection.BeginTransaction();
        int affected = WriteConversationBatch(connection, transaction, records);
        transaction.Commit();
        return affected;
    }

    internal static int WriteConversationBatch(
        SqliteConnection connection,
        SqliteTransaction transaction,
        IEnumerable<ConversationWriteRecord> records)
    {
        EnsureFtsTriggers(connection, transaction);

        int affected = 0;
        foreach (ConversationWriteRecord record in records)
        {
            affected += WriteConversation(connection, transaction, record);
        }
        return affected;
    }

    private static int WriteConversation(
        SqliteConnection connection,
        SqliteTransaction transaction,
        ConversationWriteRecord record)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO conversations (
                id, provider, sessionId, projectName, inferredTaskTitle,
                fullText, indexedAt, messageCount, deletedAt, workingDirectory
            ) VALUES (
                $id, $provider, $sessionId, $projectName, $inferredTaskTitle,
                $fullText, $indexedAt, $messageCount, NULL, $workingDirectory
            )
            ON CONFLICT(id) DO UPDATE SET
                provider = excluded.provider,
                sessionId = excluded.sessionId,
                projectName = excluded.projectName,
                inferredTaskTitle = excluded.inferredTaskTitle,
                fullText = excluded.fullText,
                indexedAt = excluded.indexedAt,
                messageCount = excluded.messageCount,
                deletedAt = NULL,
                workingDirectory = excluded.workingDirectory
            """;
        Bind(command, "$id", record.Id);
        Bind(command, "$provider", record.Provider);
        Bind(command, "$sessionId", record.SessionId);
        Bind(command, "$projectName", record.ProjectName);
        Bind(command, "$inferredTaskTitle", record.InferredTaskTitle);
        Bind(command, "$fullText", record.FullText);
        Bind(command, "$indexedAt", (object?)record.IndexedAt ?? DBNull.Value);
        Bind(command, "$messageCount", record.MessageCount);
        Bind(command, "$workingDirectory", (object?)record.WorkingDirectory ?? DBNull.Value);
        return command.ExecuteNonQuery();
    }

    private static void EnsureFtsTriggers(
        SqliteConnection connection,
        SqliteTransaction transaction)
    {
        bool needsRebuild = !TriggerExists(connection, transaction, "conversations_ai");
        string[] statements =
        [
            """
            CREATE TRIGGER IF NOT EXISTS conversations_ai AFTER INSERT ON conversations BEGIN
                INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS conversations_ad AFTER DELETE ON conversations BEGIN
                INSERT INTO conversations_fts(conversations_fts, rowid, inferredTaskTitle, fullText)
                VALUES ('delete', old.rowid, old.inferredTaskTitle, old.fullText);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS conversations_au AFTER UPDATE ON conversations BEGIN
                INSERT INTO conversations_fts(conversations_fts, rowid, inferredTaskTitle, fullText)
                VALUES ('delete', old.rowid, old.inferredTaskTitle, old.fullText);
                INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
            END
            """,
        ];

        foreach (string statement in statements)
        {
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = statement;
            command.ExecuteNonQuery();
        }

        if (needsRebuild)
        {
            using var rebuild = connection.CreateCommand();
            rebuild.Transaction = transaction;
            rebuild.CommandText = "INSERT INTO conversations_fts(conversations_fts) VALUES ('rebuild')";
            rebuild.ExecuteNonQuery();
        }
    }

    private static bool TriggerExists(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string name)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = $name LIMIT 1";
        Bind(command, "$name", name);
        return command.ExecuteScalar() is not null;
    }

    private static void Bind(SqliteCommand command, string name, object value)
    {
        var parameter = command.CreateParameter();
        parameter.ParameterName = name;
        parameter.Value = value;
        command.Parameters.Add(parameter);
    }
}

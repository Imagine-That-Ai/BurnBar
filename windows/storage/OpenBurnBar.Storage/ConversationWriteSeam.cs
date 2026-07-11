using System;
using System.Collections.Generic;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

/// <summary>
/// Idempotent encrypted conversation upsert used by the Windows log-ingestion runtime.
/// The FTS triggers are installed on both fresh and pre-existing Windows databases.
/// </summary>
public static class ConversationWriteSeam
{
    private static readonly string[] FtsTriggerStatements =
    {
        """
        CREATE TRIGGER IF NOT EXISTS conversations_ai AFTER INSERT ON conversations BEGIN
            INSERT INTO conversations_fts(rowid, fullText, inferredTaskTitle)
            VALUES (new.rowid, new.fullText, new.inferredTaskTitle);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS conversations_ad AFTER DELETE ON conversations BEGIN
            INSERT INTO conversations_fts(conversations_fts, rowid, fullText, inferredTaskTitle)
            VALUES ('delete', old.rowid, old.fullText, old.inferredTaskTitle);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS conversations_au AFTER UPDATE ON conversations BEGIN
            INSERT INTO conversations_fts(conversations_fts, rowid, fullText, inferredTaskTitle)
            VALUES ('delete', old.rowid, old.fullText, old.inferredTaskTitle);
            INSERT INTO conversations_fts(rowid, fullText, inferredTaskTitle)
            VALUES (new.rowid, new.fullText, new.inferredTaskTitle);
        END
        """,
    };

    public static int WriteConversations(SqliteConnection connection, IReadOnlyList<ConversationRecord> records)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(records);
        if (records.Count == 0)
        {
            return 0;
        }

        using var transaction = connection.BeginTransaction();
        bool needsFtsRebuild = !TriggerExists(connection, transaction, "conversations_ai");
        foreach (string statement in FtsTriggerStatements)
        {
            using var trigger = connection.CreateCommand();
            trigger.Transaction = transaction;
            trigger.CommandText = statement;
            trigger.ExecuteNonQuery();
        }

        if (needsFtsRebuild)
        {
            using var rebuild = connection.CreateCommand();
            rebuild.Transaction = transaction;
            rebuild.CommandText = "INSERT INTO conversations_fts(conversations_fts) VALUES ('rebuild')";
            rebuild.ExecuteNonQuery();
        }

        int affected = 0;
        foreach (ConversationRecord record in records)
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
            command.Parameters.AddWithValue("$id", record.Id);
            command.Parameters.AddWithValue("$provider", record.Provider);
            command.Parameters.AddWithValue("$sessionId", record.SessionId);
            command.Parameters.AddWithValue("$projectName", record.ProjectName);
            command.Parameters.AddWithValue("$inferredTaskTitle", record.InferredTaskTitle);
            command.Parameters.AddWithValue("$fullText", record.FullText);
            command.Parameters.AddWithValue("$indexedAt", (object?)record.IndexedAt ?? DBNull.Value);
            command.Parameters.AddWithValue("$messageCount", record.MessageCount);
            command.Parameters.AddWithValue("$workingDirectory", DBNull.Value);
            affected += command.ExecuteNonQuery();
        }

        transaction.Commit();
        return affected;
    }

    private static bool TriggerExists(SqliteConnection connection, SqliteTransaction transaction, string name)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = $name LIMIT 1";
        command.Parameters.AddWithValue("$name", name);
        return command.ExecuteScalar() is not null;
    }
}

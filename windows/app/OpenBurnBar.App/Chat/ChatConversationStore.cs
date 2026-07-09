using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;
using OpenBurnBar.App.Presentation.Chat;
using OpenBurnBar.App.Storage;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.Chat;

public sealed record ChatThreadSnapshot(string ThreadId, IReadOnlyList<ChatMessageRecord> Messages);

public interface IChatConversationStore
{
    ChatThreadSnapshot LoadMostRecentThread();

    void SaveMessages(
        string threadId,
        IReadOnlyList<ChatMessageRecord> messages,
        ChatFailureKind? failureKind = null,
        string? failureMessage = null);

    void RecordRetrievalState(string threadId, string messageId, ChatFailureKind kind, string detail);
}

public sealed class NoopChatConversationStore : IChatConversationStore
{
    public ChatThreadSnapshot LoadMostRecentThread() => new(Guid.NewGuid().ToString(), Array.Empty<ChatMessageRecord>());

    public void SaveMessages(
        string threadId,
        IReadOnlyList<ChatMessageRecord> messages,
        ChatFailureKind? failureKind = null,
        string? failureMessage = null)
    {
    }

    public void RecordRetrievalState(string threadId, string messageId, ChatFailureKind kind, string detail)
    {
    }
}

public static class ChatConversationStoreFactory
{
    public static IChatConversationStore CreateDefault()
    {
        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime();
        if (!status.IsReady)
        {
            return new UnavailableChatConversationStore(status.RecoveryState?.Title ?? "Storage is unavailable.");
        }

        var (path, passphrase) = WindowsStorageDevHost.ResolveCredentials();
        return new SqlCipherChatConversationStore(path!, passphrase!);
    }
}

public sealed class UnavailableChatConversationStore : IChatConversationStore
{
    private readonly string _reason;

    public UnavailableChatConversationStore(string reason)
    {
        _reason = reason;
    }

    public ChatThreadSnapshot LoadMostRecentThread() => new(Guid.NewGuid().ToString(), Array.Empty<ChatMessageRecord>());

    public void SaveMessages(
        string threadId,
        IReadOnlyList<ChatMessageRecord> messages,
        ChatFailureKind? failureKind = null,
        string? failureMessage = null)
    {
        throw new ChatPersistenceException(_reason);
    }

    public void RecordRetrievalState(string threadId, string messageId, ChatFailureKind kind, string detail)
    {
        throw new ChatPersistenceException(_reason);
    }
}

public sealed class ChatPersistenceException : Exception
{
    public ChatPersistenceException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}

public sealed class SqlCipherChatConversationStore : IChatConversationStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly string _databasePath;
    private readonly string _passphrase;

    public SqlCipherChatConversationStore(string databasePath, string passphrase)
    {
        _databasePath = databasePath;
        _passphrase = passphrase;
        using SqliteConnection connection = OpenConnection();
        EnsureSchema(connection);
    }

    public ChatThreadSnapshot LoadMostRecentThread()
    {
        using SqliteConnection connection = OpenConnection();
        EnsureSchema(connection);
        string? threadId = ReadMostRecentThreadId(connection);
        if (threadId is null)
        {
            return new ChatThreadSnapshot(Guid.NewGuid().ToString(), Array.Empty<ChatMessageRecord>());
        }

        return new ChatThreadSnapshot(threadId, ReadMessages(connection, threadId));
    }

    public void SaveMessages(
        string threadId,
        IReadOnlyList<ChatMessageRecord> messages,
        ChatFailureKind? failureKind = null,
        string? failureMessage = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(threadId);
        using SqliteConnection connection = OpenConnection();
        EnsureSchema(connection);
        using var transaction = connection.BeginTransaction();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        DateTimeOffset createdAt = messages.Count == 0 ? now : messages.Min(message => message.Timestamp);
        DateTimeOffset updatedAt = messages.Count == 0 ? now : messages.Max(message => message.Timestamp);
        UpsertThread(connection, transaction, threadId, createdAt, updatedAt);

        using (var delete = connection.CreateCommand())
        {
            delete.Transaction = transaction;
            delete.CommandText = "DELETE FROM chat_messages WHERE threadId = $threadId";
            delete.Parameters.AddWithValue("$threadId", threadId);
            delete.ExecuteNonQuery();
        }

        foreach (ChatMessageRecord message in messages)
        {
            InsertMessage(connection, transaction, threadId, message, failureKind, failureMessage);
        }

        if (failureKind is not null && messages.Count > 0)
        {
            InsertFailure(connection, transaction, threadId, messages[^1].Id, failureKind.Value, failureMessage ?? string.Empty);
        }

        transaction.Commit();
    }

    public void RecordRetrievalState(string threadId, string messageId, ChatFailureKind kind, string detail)
    {
        using SqliteConnection connection = OpenConnection();
        EnsureSchema(connection);
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO chat_retrieval_events (id, threadId, messageId, kind, detail, createdAt)
            VALUES ($id, $threadId, $messageId, $kind, $detail, $createdAt)
            """;
        command.Parameters.AddWithValue("$id", Guid.NewGuid().ToString());
        command.Parameters.AddWithValue("$threadId", threadId);
        command.Parameters.AddWithValue("$messageId", messageId);
        command.Parameters.AddWithValue("$kind", kind.ToString());
        command.Parameters.AddWithValue("$detail", detail);
        command.Parameters.AddWithValue("$createdAt", FormatDate(DateTimeOffset.UtcNow));
        command.ExecuteNonQuery();
    }

    public static void EnsureSchema(SqliteConnection connection)
    {
        Execute(connection,
            """
            CREATE TABLE IF NOT EXISTS chat_threads (
                id TEXT NOT NULL PRIMARY KEY,
                title TEXT,
                backend TEXT NOT NULL DEFAULT 'cli',
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL,
                projectPath TEXT,
                sessionId TEXT
            )
            """);
        Execute(connection, "CREATE INDEX IF NOT EXISTS chat_threads_updated_idx ON chat_threads(updatedAt DESC)");

        Execute(connection,
            """
            CREATE TABLE IF NOT EXISTS chat_messages (
                id TEXT NOT NULL PRIMARY KEY,
                threadId TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                cliUsed TEXT,
                transcriptPiecesJSON TEXT,
                attachmentsJSON TEXT,
                errorKind TEXT,
                errorMessage TEXT,
                retrievalStateJSON TEXT,
                modelUsed TEXT,
                backend TEXT,
                isStreaming INTEGER NOT NULL DEFAULT 0,
                metadata TEXT
            )
            """);
        EnsureColumn(connection, "chat_messages", "threadId", "TEXT NOT NULL DEFAULT 'default'");
        EnsureColumn(connection, "chat_messages", "cliUsed", "TEXT");
        EnsureColumn(connection, "chat_messages", "transcriptPiecesJSON", "TEXT");
        EnsureColumn(connection, "chat_messages", "attachmentsJSON", "TEXT");
        EnsureColumn(connection, "chat_messages", "errorKind", "TEXT");
        EnsureColumn(connection, "chat_messages", "errorMessage", "TEXT");
        EnsureColumn(connection, "chat_messages", "retrievalStateJSON", "TEXT");
        EnsureColumn(connection, "chat_messages", "modelUsed", "TEXT");
        EnsureColumn(connection, "chat_messages", "backend", "TEXT");
        EnsureColumn(connection, "chat_messages", "isStreaming", "INTEGER NOT NULL DEFAULT 0");
        EnsureColumn(connection, "chat_messages", "metadata", "TEXT");
        Execute(connection, "CREATE INDEX IF NOT EXISTS chat_messages_thread_time_idx ON chat_messages(threadId, timestamp)");
        Execute(connection, "CREATE INDEX IF NOT EXISTS chat_messages_timestamp_idx ON chat_messages(timestamp DESC)");

        Execute(connection,
            """
            CREATE TABLE IF NOT EXISTS chat_stream_failures (
                id TEXT NOT NULL PRIMARY KEY,
                threadId TEXT NOT NULL,
                messageId TEXT,
                kind TEXT NOT NULL,
                message TEXT NOT NULL,
                createdAt TEXT NOT NULL
            )
            """);
        Execute(connection, "CREATE INDEX IF NOT EXISTS chat_stream_failures_thread_idx ON chat_stream_failures(threadId, createdAt DESC)");

        Execute(connection,
            """
            CREATE TABLE IF NOT EXISTS chat_retrieval_events (
                id TEXT NOT NULL PRIMARY KEY,
                threadId TEXT NOT NULL,
                messageId TEXT NOT NULL,
                kind TEXT NOT NULL,
                detail TEXT NOT NULL,
                createdAt TEXT NOT NULL
            )
            """);
        Execute(connection, "CREATE INDEX IF NOT EXISTS chat_retrieval_events_message_idx ON chat_retrieval_events(messageId, createdAt DESC)");
    }

    private SqliteConnection OpenConnection() => SqlCipherConnection.Open(_databasePath, _passphrase);

    private static string? ReadMostRecentThreadId(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT t.id
            FROM chat_threads t
            LEFT JOIN chat_messages m ON m.threadId = t.id
            GROUP BY t.id, t.createdAt, t.updatedAt
            HAVING COUNT(m.id) > 0
            ORDER BY COALESCE(MAX(m.timestamp), t.updatedAt, t.createdAt) DESC
            LIMIT 1
            """;
        return command.ExecuteScalar()?.ToString();
    }

    private static IReadOnlyList<ChatMessageRecord> ReadMessages(SqliteConnection connection, string threadId)
    {
        var messages = new List<ChatMessageRecord>();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT id, role, content, timestamp, cliUsed, transcriptPiecesJSON, attachmentsJSON
            FROM chat_messages
            WHERE threadId = $threadId
            ORDER BY timestamp ASC
            """;
        command.Parameters.AddWithValue("$threadId", threadId);
        using SqliteDataReader reader = command.ExecuteReader();
        while (reader.Read())
        {
            messages.Add(ReadMessage(reader));
        }

        return messages;
    }

    private static ChatMessageRecord ReadMessage(SqliteDataReader reader)
    {
        string id = reader.GetString(0);
        ChatMessageRole role = ParseRole(reader.GetString(1));
        string content = reader.GetString(2);
        DateTimeOffset timestamp = ParseDate(reader.GetString(3));
        string? cliUsed = reader.IsDBNull(4) ? null : reader.GetString(4);
        var pieces = reader.IsDBNull(5)
            ? new List<ChatTranscriptPiece>()
            : DecodeTranscriptPieces(reader.GetString(5));
        var attachments = reader.IsDBNull(6)
            ? Array.Empty<ChatAttachmentRecord>()
            : DecodeAttachments(reader.GetString(6));
        return new ChatMessageRecord(
            role,
            content,
            id,
            timestamp,
            cliUsed,
            pieces,
            attachments: attachments);
    }

    private static void UpsertThread(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string threadId,
        DateTimeOffset createdAt,
        DateTimeOffset updatedAt)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO chat_threads (id, backend, createdAt, updatedAt)
            VALUES ($id, 'cli', $createdAt, $updatedAt)
            ON CONFLICT(id) DO UPDATE SET updatedAt = excluded.updatedAt
            """;
        command.Parameters.AddWithValue("$id", threadId);
        command.Parameters.AddWithValue("$createdAt", FormatDate(createdAt));
        command.Parameters.AddWithValue("$updatedAt", FormatDate(updatedAt));
        command.ExecuteNonQuery();
    }

    private static void InsertMessage(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string threadId,
        ChatMessageRecord message,
        ChatFailureKind? failureKind,
        string? failureMessage)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO chat_messages (
                id, threadId, role, content, timestamp, cliUsed,
                transcriptPiecesJSON, attachmentsJSON, errorKind, errorMessage,
                backend, isStreaming
            ) VALUES (
                $id, $threadId, $role, $content, $timestamp, $cliUsed,
                $pieces, $attachments, $errorKind, $errorMessage,
                'cli', 0
            )
            """;
        command.Parameters.AddWithValue("$id", message.Id);
        command.Parameters.AddWithValue("$threadId", threadId);
        command.Parameters.AddWithValue("$role", RoleText(message.Role));
        command.Parameters.AddWithValue("$content", message.Content);
        command.Parameters.AddWithValue("$timestamp", FormatDate(message.Timestamp));
        command.Parameters.AddWithValue("$cliUsed", (object?)message.CliUsed ?? DBNull.Value);
        command.Parameters.AddWithValue("$pieces", (object?)EncodeTranscriptPieces(message.TranscriptPieces) ?? DBNull.Value);
        command.Parameters.AddWithValue("$attachments", (object?)EncodeAttachments(message.Attachments) ?? DBNull.Value);
        command.Parameters.AddWithValue("$errorKind", (object?)failureKind?.ToString() ?? DBNull.Value);
        command.Parameters.AddWithValue("$errorMessage", (object?)failureMessage ?? DBNull.Value);
        command.ExecuteNonQuery();
    }

    private static void InsertFailure(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string threadId,
        string messageId,
        ChatFailureKind kind,
        string message)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO chat_stream_failures (id, threadId, messageId, kind, message, createdAt)
            VALUES ($id, $threadId, $messageId, $kind, $message, $createdAt)
            """;
        command.Parameters.AddWithValue("$id", Guid.NewGuid().ToString());
        command.Parameters.AddWithValue("$threadId", threadId);
        command.Parameters.AddWithValue("$messageId", messageId);
        command.Parameters.AddWithValue("$kind", kind.ToString());
        command.Parameters.AddWithValue("$message", message);
        command.Parameters.AddWithValue("$createdAt", FormatDate(DateTimeOffset.UtcNow));
        command.ExecuteNonQuery();
    }

    private static string? EncodeTranscriptPieces(IReadOnlyList<ChatTranscriptPiece> pieces)
    {
        if (pieces.Count == 0)
        {
            return null;
        }

        var records = pieces.Select(piece => new StoredTranscriptPiece(
            piece.Id,
            KindText(piece.Kind),
            piece.Value,
            piece.Detail));
        return JsonSerializer.Serialize(records, JsonOptions);
    }

    private static List<ChatTranscriptPiece> DecodeTranscriptPieces(string json)
    {
        var records = JsonSerializer.Deserialize<StoredTranscriptPiece[]>(json, JsonOptions)
            ?? Array.Empty<StoredTranscriptPiece>();
        return records
            .Select(piece => new ChatTranscriptPiece(ParsePieceKind(piece.Kind), piece.Value, piece.Detail, piece.Id))
            .ToList();
    }

    private static string? EncodeAttachments(IReadOnlyList<ChatAttachmentRecord> attachments)
    {
        return attachments.Count == 0 ? null : JsonSerializer.Serialize(attachments, JsonOptions);
    }

    private static ChatAttachmentRecord[] DecodeAttachments(string json)
    {
        return JsonSerializer.Deserialize<ChatAttachmentRecord[]>(json, JsonOptions)
            ?? Array.Empty<ChatAttachmentRecord>();
    }

    private static void EnsureColumn(SqliteConnection connection, string table, string column, string declaration)
    {
        using (var info = connection.CreateCommand())
        {
            info.CommandText = "PRAGMA table_info(" + table + ")";
            using SqliteDataReader reader = info.ExecuteReader();
            while (reader.Read())
            {
                if (string.Equals(reader.GetString(1), column, StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }
            }
        }

        Execute(connection, "ALTER TABLE " + table + " ADD COLUMN " + column + " " + declaration);
    }

    private static void Execute(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private static string FormatDate(DateTimeOffset timestamp) =>
        timestamp.UtcDateTime.ToString("O", CultureInfo.InvariantCulture);

    private static DateTimeOffset ParseDate(string text) =>
        DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
            ? parsed
            : DateTimeOffset.FromUnixTimeSeconds(0);

    private static string RoleText(ChatMessageRole role) =>
        role switch
        {
            ChatMessageRole.User => "user",
            ChatMessageRole.Assistant => "assistant",
            ChatMessageRole.System => "system",
            _ => "system",
        };

    private static ChatMessageRole ParseRole(string role) =>
        role switch
        {
            "user" => ChatMessageRole.User,
            "assistant" => ChatMessageRole.Assistant,
            "system" => ChatMessageRole.System,
            _ => ChatMessageRole.System,
        };

    private static string KindText(ChatTranscriptPieceKind kind) =>
        kind switch
        {
            ChatTranscriptPieceKind.Text => "text",
            ChatTranscriptPieceKind.Reasoning => "reasoning",
            ChatTranscriptPieceKind.Refusal => "refusal",
            ChatTranscriptPieceKind.ToolUse => "toolUse",
            ChatTranscriptPieceKind.ToolResult => "toolResult",
            _ => "text",
        };

    private static ChatTranscriptPieceKind ParsePieceKind(string kind) =>
        kind switch
        {
            "reasoning" => ChatTranscriptPieceKind.Reasoning,
            "refusal" => ChatTranscriptPieceKind.Refusal,
            "toolUse" => ChatTranscriptPieceKind.ToolUse,
            "toolResult" => ChatTranscriptPieceKind.ToolResult,
            _ => ChatTranscriptPieceKind.Text,
        };

    private sealed record StoredTranscriptPiece(string Id, string Kind, string Value, string? Detail);
}

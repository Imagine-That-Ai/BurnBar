using System;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Data.Sqlite;
using OpenBurnBar.App.Chat;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Chat;
using OpenBurnBar.App.Storage;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.Storage.Tests;

[Collection(WindowsStorageTestCollection.Name)]
public sealed class ChatConversationStoreTests : IDisposable
{
    public void Dispose()
    {
        WindowsStorageDevHost.ResetForTests();
    }

    [Fact]
    public void CleanProfile_ProvisionsChatHistoryTables()
    {
        using TestProfile profile = TestProfile.Create();

        WindowsStorageDevHost.InitializeRuntime();
        var (_, passphrase) = WindowsStorageDevHost.ResolveCredentials();

        using SqliteConnection connection = SqlCipherConnection.Open(profile.DatabasePath, passphrase!);
        Assert.True(TableExists(connection, "chat_threads"));
        Assert.True(TableExists(connection, "chat_messages"));
        Assert.True(TableExists(connection, "chat_stream_failures"));
        Assert.True(TableExists(connection, "chat_retrieval_events"));
    }

    [Fact]
    public void MessagesErrorsRetrievalAndAttachments_RoundTripEncryptedAcrossRestart()
    {
        using TestProfile profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        var (_, passphrase) = WindowsStorageDevHost.ResolveCredentials();
        var store = new SqlCipherChatConversationStore(profile.DatabasePath, passphrase!);
        string threadId = "thread-chat-001";
        var user = new ChatMessageRecord(
            ChatMessageRole.User,
            "hello from encrypted chat",
            id: "message-user-001",
            timestamp: DateTimeOffset.Parse("2026-07-09T20:00:00Z"),
            attachments: new[]
            {
                new ChatAttachmentRecord(
                    "att-1",
                    "textDocument",
                    "notes.txt",
                    "text/plain",
                    21,
                    "attachments/att-1-notes.txt",
                    "preview text"),
                new ChatAttachmentRecord(
                    "att-missing",
                    "generic",
                    "missing.zip",
                    "application/zip",
                    42,
                    "attachments/missing.zip",
                    IsMissing: true),
            });
        var assistant = new ChatMessageRecord(
            ChatMessageRole.Assistant,
            "partial",
            id: "message-assistant-001",
            timestamp: DateTimeOffset.Parse("2026-07-09T20:00:01Z"),
            cliUsed: "cli",
            transcriptPieces: new()
            {
                new ChatTranscriptPiece(ChatTranscriptPieceKind.Text, "partial", id: "piece-1"),
                new ChatTranscriptPiece(ChatTranscriptPieceKind.ToolUse, "Read", "notes.txt", "piece-2"),
            });

        store.SaveMessages(
            threadId,
            new[] { user, assistant },
            ChatFailureKind.MalformedStream,
            "backend emitted malformed JSON");
        store.RecordRetrievalState(
            threadId,
            assistant.Id,
            ChatFailureKind.RetrievalDegraded,
            "local FTS unavailable; answered without retrieved passages");

        var reopened = new SqlCipherChatConversationStore(profile.DatabasePath, passphrase!);
        ChatThreadSnapshot snapshot = reopened.LoadMostRecentThread();

        Assert.Equal(threadId, snapshot.ThreadId);
        Assert.Equal(2, snapshot.Messages.Count);
        Assert.Equal("hello from encrypted chat", snapshot.Messages[0].Content);
        Assert.Equal(2, snapshot.Messages[0].Attachments.Count);
        Assert.True(snapshot.Messages[0].Attachments.Single(a => a.Id == "att-missing").IsMissing);
        Assert.Equal(2, snapshot.Messages[1].TranscriptPieces.Count);

        using SqliteConnection connection = SqlCipherConnection.Open(profile.DatabasePath, passphrase!);
        Assert.Equal(1, ScalarLong(connection, "SELECT count(*) FROM chat_stream_failures WHERE kind='MalformedStream'"));
        Assert.Equal(1, ScalarLong(connection, "SELECT count(*) FROM chat_retrieval_events WHERE kind='RetrievalDegraded'"));
        Assert.True(SqlCipherConnection.FileIsEncrypted(profile.DatabasePath));
        AssertFileDoesNotContain(profile.DatabasePath, "hello from encrypted chat");
    }

    [Fact]
    public void AttachmentStager_ImportsPasteDropReferencesAndMarksMissingFiles()
    {
        using TestProfile profile = TestProfile.Create();
        string workspace = Path.Combine(profile.Root, "workspace");
        string dropSource = Path.Combine(profile.Root, "drop & quote ^ unicode Ω.txt");
        File.WriteAllText(dropSource, "dropped file body", Encoding.UTF8);

        ChatAttachmentRecord dropped = WindowsChatAttachmentStager.ImportFile(dropSource, workspace);
        ChatAttachmentRecord pasted = WindowsChatAttachmentStager.ImportPastedText(
            "pasted text body",
            workspace,
            "paste <payload>.txt");

        Assert.Equal("textDocument", dropped.Kind);
        Assert.Equal("drop & quote ^ unicode Ω.txt", dropped.DisplayName);
        Assert.Equal("dropped file body", dropped.ExtractedTextPreview);
        Assert.Contains("paste__payload_.txt", pasted.WorkspaceRelativePath, StringComparison.Ordinal);
        Assert.False(WindowsChatAttachmentStager.MarkMissingIfAbsent(dropped, workspace).IsMissing);

        File.Delete(Path.Combine(workspace, dropped.WorkspaceRelativePath.Replace('/', Path.DirectorySeparatorChar)));
        Assert.True(WindowsChatAttachmentStager.MarkMissingIfAbsent(dropped, workspace).IsMissing);
    }

    private static bool TableExists(SqliteConnection connection, string table)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=$name";
        command.Parameters.AddWithValue("$name", table);
        return Convert.ToInt64(command.ExecuteScalar()) == 1;
    }

    private static long ScalarLong(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(command.ExecuteScalar());
    }

    private static void AssertFileDoesNotContain(string path, string text)
    {
        byte[] haystack = File.ReadAllBytes(path);
        byte[] needle = Encoding.UTF8.GetBytes(text);
        for (var i = 0; i <= haystack.Length - needle.Length; i++)
        {
            var found = true;
            for (var j = 0; j < needle.Length; j++)
            {
                if (haystack[i + j] != needle[j])
                {
                    found = false;
                    break;
                }
            }

            Assert.False(found, "Encrypted database file contains plaintext chat content.");
        }
    }

    private sealed class TestProfile : IDisposable
    {
        private readonly string _root;

        private TestProfile(string root, AppConfiguration configuration, string databasePath)
        {
            _root = root;
            Configuration = configuration;
            DatabasePath = databasePath;
        }

        public AppConfiguration Configuration { get; }

        public string DatabasePath { get; }

        public string Root => _root;

        public static TestProfile Create()
        {
            string root = Path.Combine(Path.GetTempPath(), "obb-chat-storage-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            string configPath = Path.Combine(root, "app_config.json");
            var configuration = new AppConfiguration(configPath);
            string databasePath = Path.Combine(root, "openburnbar.sqlite");
            configuration.UpdateAndSave(model =>
            {
                model.SqlCipherDbPath = databasePath;
                model.SqlCipherPassphrase = Convert.ToBase64String(Encoding.UTF8.GetBytes("openburnbar-chat-test-passphrase-0001"));
            });
            WindowsStorageDevHost.ConfigureForTests(configuration, databasePath);
            return new TestProfile(root, configuration, databasePath);
        }

        public void Dispose()
        {
            try
            {
                Directory.Delete(_root, recursive: true);
            }
            catch
            {
                // Best-effort cleanup.
            }
        }
    }
}

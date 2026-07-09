using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
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
    public void UnavailableStore_LoadMostRecentThreadThrowsTypedFailure()
    {
        var store = new UnavailableChatConversationStore(
            ChatPersistenceFailureKind.Locked,
            "Chat history is locked.",
            "The database is locked by another process.");

        ChatPersistenceException ex = Assert.Throws<ChatPersistenceException>(() => store.LoadMostRecentThread());
        Assert.Equal(ChatPersistenceFailureKind.Locked, ex.Kind);
        Assert.Contains("locked", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ChatSurfaceViewModel_InitialLoadFailureShowsDegradedStateInsteadOfEmptyHistory()
    {
        var store = new FailingConversationStore(new ChatPersistenceException(
            ChatPersistenceFailureKind.Corrupt,
            "The chat database could not be decoded."));

        var viewModel = new ChatSurfaceViewModel(
            new EmptyChatStreamDriver(),
            store: store,
            executableInventory: ReadyExecutableInventory.CurrentProcess());

        Assert.True(viewModel.HasHistoryDegradedState);
        Assert.False(viewModel.ShowEmptyState);
        Assert.False(viewModel.ShowMessageList);
        Assert.False(viewModel.CanSend);
        Assert.Equal(ChatPersistenceFailureKind.Corrupt.ToString(), viewModel.HistoryStateKind);
        Assert.Contains("could not be decoded", viewModel.HistoryStateMessage, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ChatSurfaceViewModel_RestartRehydratesDurableThread()
    {
        using TestProfile profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        var (_, passphrase) = WindowsStorageDevHost.ResolveCredentials();
        var store = new SqlCipherChatConversationStore(profile.DatabasePath, passphrase!);
        string threadId = "thread-restart-001";
        store.SaveMessages(
            threadId,
            new[]
            {
                new ChatMessageRecord(
                    ChatMessageRole.User,
                    "restart recovery question",
                    id: "restart-user-001",
                    timestamp: DateTimeOffset.Parse("2026-07-09T22:00:00Z")),
                new ChatMessageRecord(
                    ChatMessageRole.Assistant,
                    "restart recovery answer",
                    id: "restart-assistant-001",
                    timestamp: DateTimeOffset.Parse("2026-07-09T22:00:01Z")),
            });

        var restarted = new ChatSurfaceViewModel(
            new EmptyChatStreamDriver(),
            store: new SqlCipherChatConversationStore(profile.DatabasePath, passphrase!),
            executableInventory: ReadyExecutableInventory.CurrentProcess());

        Assert.False(restarted.HasHistoryDegradedState);
        Assert.False(restarted.ShowEmptyState);
        Assert.True(restarted.ShowMessageList);
        Assert.Equal(2, restarted.Messages.Count);
        Assert.Equal("restart recovery question", restarted.Messages[0].UserText);
        Assert.True(SqlCipherConnection.FileIsEncrypted(profile.DatabasePath));
        AssertFileDoesNotContain(profile.DatabasePath, "restart recovery question");
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

    private sealed class EmptyChatStreamDriver : IChatStreamDriver
    {
        public async IAsyncEnumerable<ChatStreamEvent> StreamAsync(
            string userText,
            IReadOnlyList<ChatMessageRecord> history,
            [EnumeratorCancellation] CancellationToken cancellationToken)
        {
            await System.Threading.Tasks.Task.CompletedTask.ConfigureAwait(false);
            yield break;
        }
    }

    private sealed class FailingConversationStore : IChatConversationStore
    {
        private readonly ChatPersistenceException _failure;

        public FailingConversationStore(ChatPersistenceException failure)
        {
            _failure = failure;
        }

        public ChatThreadSnapshot LoadMostRecentThread() => throw _failure;

        public void SaveMessages(
            string threadId,
            IReadOnlyList<ChatMessageRecord> messages,
            ChatFailureKind? failureKind = null,
            string? failureMessage = null) =>
            throw _failure;

        public void RecordRetrievalState(string threadId, string messageId, ChatFailureKind kind, string detail) =>
            throw _failure;
    }

    private sealed class ReadyExecutableInventory : IChatExecutableInventory
    {
        private readonly ApprovedChatExecutable _executable;

        private ReadyExecutableInventory(ApprovedChatExecutable executable)
        {
            _executable = executable;
        }

        public static ReadyExecutableInventory CurrentProcess()
        {
            string path = Environment.ProcessPath!;
            return new ReadyExecutableInventory(new ApprovedChatExecutable(
                "test-process",
                path,
                ApprovedChatExecutableCatalog.ComputeSha256(path)));
        }

        public ChatExecutableInventorySnapshot LoadSnapshot() =>
            new(
                new[] { _executable },
                new ChatExecutableInventoryStatus(
                    ChatExecutableInventoryStatusKind.Ready,
                    "Chat CLI executable approved.",
                    _executable.Path));

        public ApprovedChatExecutableCatalog LoadCatalog() => new(new[] { _executable });

        public ApprovedChatExecutable ApproveExecutable(string path, string? id = null) => _executable;

        public ApprovedChatExecutable RotateExecutable(string id, string path) => _executable;

        public bool RemoveExecutable(string id) => true;
    }
}

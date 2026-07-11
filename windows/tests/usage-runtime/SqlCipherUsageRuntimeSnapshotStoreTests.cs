using System;
using System.IO;
using System.Threading.Tasks;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.UsageRuntime.Tests;

public sealed class SqlCipherUsageRuntimeSnapshotStoreTests
{
    [Fact]
    public async Task PersistAsync_AtomicallyWritesEncryptedUsageConversationAndFts()
    {
        string directory = Path.Combine(Path.GetTempPath(), "obb-runtime-store-" + Guid.NewGuid().ToString("N"));
        string databasePath = Path.Combine(directory, "openburnbar.sqlite");
        const string passphrase = "usage-runtime-test-passphrase";
        Directory.CreateDirectory(directory);
        try
        {
            var provisioner = new WindowsSqlCipherProvisioner();
            provisioner.EnsureReady(databasePath, passphrase, "test-protected-key");
            var store = new SqlCipherUsageRuntimeSnapshotStore(
                () => new UsageRuntimeStorageCredentials(databasePath, passphrase));

            await store.PersistAsync(Response());

            Assert.True(SqlCipherConnection.FileIsEncrypted(databasePath));
            using var reader = OpenBurnBarStorage.OpenReadOnly(databasePath, passphrase);
            TokenUsageRecord usage = Assert.Single(TokenUsageReadSeam.ListRecent(reader.Connection, 10));
            Assert.Equal("Claude Code", usage.Provider);
            Assert.Equal(15, usage.TotalTokens);
            ConversationRecord conversation = Assert.IsType<ConversationRecord>(
                reader.GetConversation("Claude Code:session-1"));
            Assert.Equal("Runtime ingestion", conversation.InferredTaskTitle);
            ConversationSearchResult match = Assert.Single(reader.SearchConversationsFts("needle", 10));
            Assert.Equal(conversation.Id, match.Conversation.Id);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static UsageEngineScanResponse Response() => new()
    {
        Ok = true,
        Providers = new[]
        {
            new UsageProviderScanResult
            {
                Provider = "Claude Code",
                Status = UsageProviderScanStatus.Succeeded,
                UsageCount = 1,
                ConversationCount = 1,
            },
        },
        Usages = new[]
        {
            new UsageEngineRecord
            {
                Id = "usage-1",
                Provider = "Claude Code",
                SessionId = "session-1",
                ProjectName = "BurnBar",
                Model = "claude-sonnet-4",
                InputTokens = 10,
                OutputTokens = 5,
                TotalTokens = 15,
                CostNanoUsd = 42_000_000,
                StartUnixMilliseconds = 1_750_000_000_000,
                EndUnixMilliseconds = 1_750_000_001_000,
                CreatedUnixMilliseconds = 1_750_000_001_000,
                UsageSource = "provider_log",
                ProviderId = "anthropic",
                ProvenanceMethod = "transcript",
                ProvenanceConfidence = "exact",
                EstimatorVersion = "fixture",
            },
        },
        Conversations = new[]
        {
            new UsageEngineConversation
            {
                Id = "Claude Code:session-1",
                Provider = "Claude Code",
                SessionId = "session-1",
                ProjectName = "BurnBar",
                InferredTaskTitle = "Runtime ingestion",
                FullText = "A searchable needle in the encrypted transcript.",
                IndexedUnixMilliseconds = 1_750_000_001_000,
                MessageCount = 2,
                WorkingDirectory = "C:\\src\\BurnBar",
            },
        },
    };
}

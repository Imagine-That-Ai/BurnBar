using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.UsageRuntime;

public sealed record UsageRuntimeStorageCredentials(string DatabasePath, string Passphrase);

public interface IUsageRuntimeSnapshotStore
{
    ValueTask PersistAsync(
        UsageEngineScanResponse response,
        CancellationToken cancellationToken = default);
}

public sealed class SqlCipherUsageRuntimeSnapshotStore : IUsageRuntimeSnapshotStore
{
    private readonly Func<UsageRuntimeStorageCredentials> _credentialsProvider;

    public SqlCipherUsageRuntimeSnapshotStore(
        Func<UsageRuntimeStorageCredentials> credentialsProvider)
    {
        _credentialsProvider = credentialsProvider
            ?? throw new ArgumentNullException(nameof(credentialsProvider));
    }

    public ValueTask PersistAsync(
        UsageEngineScanResponse response,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(response);
        cancellationToken.ThrowIfCancellationRequested();

        UsageRuntimeStorageCredentials credentials = _credentialsProvider();
        if (string.IsNullOrWhiteSpace(credentials.DatabasePath)
            || string.IsNullOrWhiteSpace(credentials.Passphrase))
        {
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.Storage,
                "The encrypted usage database is not ready.");
        }

        try
        {
            using var connection = SqlCipherConnection.Open(
                credentials.DatabasePath,
                credentials.Passphrase);
            cancellationToken.ThrowIfCancellationRequested();

            IReadOnlyList<TokenUsageRecord> usages = response.Usages.Select(MapUsage).ToArray();
            IReadOnlyList<ConversationWriteRecord> conversations = response.Conversations
                .Select(MapConversation)
                .ToArray();
            UsageRuntimeSnapshotWriteSeam.Write(connection, usages, conversations);
        }
        catch (UsageRuntimeException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.Storage,
                "OpenBurnBar could not update its encrypted usage database.",
                ex);
        }

        return ValueTask.CompletedTask;
    }

    private static TokenUsageRecord MapUsage(UsageEngineRecord usage)
    {
        RequireText(usage.Id, "usage id");
        RequireText(usage.Provider, "usage provider");
        RequireText(usage.SessionId, "usage session id");
        RequireText(usage.Model, "usage model");

        return new TokenUsageRecord
        {
            Id = usage.Id,
            Provider = usage.Provider,
            SessionId = usage.SessionId,
            ProjectName = usage.ProjectName ?? string.Empty,
            Model = usage.Model,
            InputTokens = usage.InputTokens,
            OutputTokens = usage.OutputTokens,
            CacheCreationTokens = usage.CacheCreationTokens,
            CacheReadTokens = usage.CacheReadTokens,
            ReasoningTokens = usage.ReasoningTokens,
            TotalTokens = usage.TotalTokens,
            Cost = usage.CostUsd,
            StartTime = FormatDate(usage.StartUnixMilliseconds),
            EndTime = FormatDate(usage.EndUnixMilliseconds),
            CreatedAt = FormatDate(usage.CreatedUnixMilliseconds),
            UsageSource = usage.UsageSource,
            ProviderID = usage.ProviderId,
            ProviderAccountID = usage.ProviderAccountId,
            ProviderAccountLabel = usage.ProviderAccountLabel,
            ProviderAccountSource = usage.ProviderAccountSource,
            ProvenanceMethod = usage.ProvenanceMethod,
            ProvenanceConfidence = usage.ProvenanceConfidence,
            EstimatorVersion = usage.EstimatorVersion,
            ParentRequestID = usage.ParentRequestId,
        };
    }

    private static ConversationWriteRecord MapConversation(UsageEngineConversation conversation)
    {
        RequireText(conversation.Id, "conversation id");
        RequireText(conversation.Provider, "conversation provider");
        RequireText(conversation.SessionId, "conversation session id");

        return new ConversationWriteRecord
        {
            Id = conversation.Id,
            Provider = conversation.Provider,
            SessionId = conversation.SessionId,
            ProjectName = conversation.ProjectName ?? string.Empty,
            InferredTaskTitle = conversation.InferredTaskTitle ?? string.Empty,
            FullText = conversation.FullText ?? string.Empty,
            IndexedAt = FormatDate(conversation.IndexedUnixMilliseconds),
            MessageCount = conversation.MessageCount,
            WorkingDirectory = conversation.WorkingDirectory,
        };
    }

    private static string FormatDate(long unixMilliseconds)
    {
        try
        {
            return DateTimeOffset.FromUnixTimeMilliseconds(unixMilliseconds)
                .UtcDateTime
                .ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);
        }
        catch (ArgumentOutOfRangeException ex)
        {
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.InvalidEngineResponse,
                "The parser engine returned an invalid timestamp.",
                ex);
        }
    }

    private static void RequireText(string? value, string field)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new UsageRuntimeException(
                UsageRuntimeFailureKind.InvalidEngineResponse,
                $"The parser engine returned an empty {field}.");
        }
    }
}

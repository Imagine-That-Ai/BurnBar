using System;
using System.Collections.Generic;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

public sealed record UsageRuntimeSnapshotWriteResult(
    int UsageRowsAffected,
    int ConversationRowsAffected);

/// <summary>
/// Commits usage and conversation projections from one parser scan as a single
/// SQLCipher transaction. A failed FTS or usage write cannot leave a half-scan.
/// </summary>
public static class UsageRuntimeSnapshotWriteSeam
{
    public static UsageRuntimeSnapshotWriteResult Write(
        SqliteConnection connection,
        IEnumerable<TokenUsageRecord> usages,
        IEnumerable<ConversationWriteRecord> conversations)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(usages);
        ArgumentNullException.ThrowIfNull(conversations);

        using var transaction = connection.BeginTransaction();
        int usageRows = TokenUsageWriteSeam.WriteTokenUsageBatch(connection, transaction, usages);
        int conversationRows = ConversationWriteSeam.WriteConversationBatch(
            connection,
            transaction,
            conversations);
        transaction.Commit();
        return new UsageRuntimeSnapshotWriteResult(usageRows, conversationRows);
    }
}

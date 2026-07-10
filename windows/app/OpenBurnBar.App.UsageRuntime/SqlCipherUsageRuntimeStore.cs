using OpenBurnBar.Storage;

namespace OpenBurnBar.App.UsageRuntime;

public sealed class SqlCipherUsageRuntimeStore : IUsageRuntimeStore
{
    private readonly string _databasePath;
    private readonly string _passphrase;
    private readonly object _gate = new();

    public SqlCipherUsageRuntimeStore(string databasePath, string passphrase)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(passphrase);
        _databasePath = databasePath;
        _passphrase = passphrase;
    }

    public (int UsageRows, int Conversations) Persist(IReadOnlyList<ParsedUsageLog> logs)
    {
        ArgumentNullException.ThrowIfNull(logs);
        lock (_gate)
        {
            using var connection = SqlCipherConnection.Open(_databasePath, _passphrase);
            var usageRecords = new List<TokenUsageRecord>();
            var conversations = new List<ConversationRecord>();
            foreach (ParsedUsageLog log in logs)
            {
                usageRecords.AddRange(log.UsageRecords);
                if (log.Conversation is not null) conversations.Add(log.Conversation);
            }

            int usageRows = TokenUsageWriteSeam.WriteTokenUsages(connection, usageRecords);
            int conversationRows = ConversationWriteSeam.WriteConversations(connection, conversations);
            return (usageRows, conversationRows);
        }
    }

    public TokenUsageAggregateSnapshot LoadSnapshot()
    {
        lock (_gate)
        {
            using var connection = SqlCipherConnection.Open(_databasePath, _passphrase);
            return TokenUsageReadSeam.LoadAggregateSnapshot(connection);
        }
    }
}

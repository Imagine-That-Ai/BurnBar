using OpenBurnBar.Storage;

namespace OpenBurnBar.App.UsageRuntime;

public enum UsageRuntimePhase
{
    NotStarted,
    Discovering,
    Parsing,
    Persisting,
    Ready,
    Empty,
    Failed,
    Stopped,
}

public sealed record UsageRuntimeStatus(
    UsageRuntimePhase Phase,
    string Message,
    DateTimeOffset? LastScanAt = null,
    int DiscoveredFiles = 0,
    int ParsedFiles = 0,
    int FailedFiles = 0)
{
    public bool IsBusy => Phase is UsageRuntimePhase.Discovering
        or UsageRuntimePhase.Parsing
        or UsageRuntimePhase.Persisting;
}

public sealed record UsageScanResult(
    int DiscoveredFiles,
    int ParsedFiles,
    int FailedFiles,
    int WrittenUsageRows,
    int WrittenConversations,
    TokenUsageAggregateSnapshot Snapshot,
    DateTimeOffset CompletedAt);

public sealed record DiscoveredUsageLog(string Provider, string Path, DateTimeOffset LastWriteAt);

public sealed record ParsedUsageLog(
    IReadOnlyList<TokenUsageRecord> UsageRecords,
    ConversationRecord? Conversation);

public interface IUsageLogDiscovery
{
    IReadOnlyList<DiscoveredUsageLog> Discover(CancellationToken cancellationToken = default);

    IReadOnlyList<string> WatchRoots { get; }
}

public interface IUsageLogParser
{
    ParsedUsageLog Parse(DiscoveredUsageLog log, CancellationToken cancellationToken = default);
}

public interface IUsageRuntimeStore
{
    (int UsageRows, int Conversations) Persist(IReadOnlyList<ParsedUsageLog> logs);

    TokenUsageAggregateSnapshot LoadSnapshot();
}

public interface IWindowsUsageRuntime : IAsyncDisposable
{
    event EventHandler<TokenUsageAggregateSnapshot>? SnapshotChanged;

    event EventHandler<UsageRuntimeStatus>? StatusChanged;

    TokenUsageAggregateSnapshot Snapshot { get; }

    UsageRuntimeStatus Status { get; }

    Task StartAsync(CancellationToken cancellationToken = default);

    Task<UsageScanResult> ScanAsync(CancellationToken cancellationToken = default);

    Task StopAsync();
}

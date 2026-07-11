using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.UsageRuntime.Tests;

public sealed class UsageRuntimeTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "obb-usage-runtime-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void ClaudeParser_SumsMessageUsage_AndBuildsEncryptedConversationShape()
    {
        string path = WriteLog(
            "claude.jsonl",
            """
            {"session_id":"s-claude","cwd":"C:\\repo\\burnbar","timestamp":"2026-07-10T12:00:00Z","message":{"model":"claude-sonnet-4","content":[{"type":"text","text":"Implement the runtime"}],"usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":2}}}
            {"session_id":"s-claude","timestamp":"2026-07-10T12:01:00Z","message":{"model":"claude-sonnet-4","content":[{"type":"text","text":"Done"}],"usage":{"input_tokens":6,"output_tokens":3}}}
            """);

        ParsedUsageLog parsed = new JsonlUsageLogParser().Parse(Log("claude", path));

        TokenUsageRecord usage = Assert.Single(parsed.UsageRecords);
        Assert.Equal("s-claude", usage.SessionId);
        Assert.Equal("claude-sonnet-4", usage.Model);
        Assert.Equal(16, usage.InputTokens);
        Assert.Equal(7, usage.OutputTokens);
        Assert.Equal(2, usage.CacheReadTokens);
        Assert.Equal(25, usage.TotalTokens);
        Assert.Equal("burnbar", usage.ProjectName);
        Assert.NotNull(parsed.Conversation);
        Assert.Contains("Implement the runtime", parsed.Conversation!.FullText, StringComparison.Ordinal);
        Assert.DoesNotContain("session_id", parsed.Conversation.FullText, StringComparison.Ordinal);
    }

    [Fact]
    public void CodexParser_UsesLatestCumulativeUsage_InsteadOfDoubleCounting()
    {
        string path = WriteLog(
            "codex.jsonl",
            """
            {"session_id":"s-codex","timestamp":"2026-07-10T12:00:00Z","model":"gpt-5","usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}
            {"session_id":"s-codex","timestamp":"2026-07-10T12:01:00Z","model":"gpt-5","usage":{"input_tokens":180,"output_tokens":40,"total_tokens":220}}
            """);

        TokenUsageRecord usage = Assert.Single(new JsonlUsageLogParser().Parse(Log("codex", path)).UsageRecords);
        Assert.Equal(180, usage.InputTokens);
        Assert.Equal(40, usage.OutputTokens);
        Assert.Equal(220, usage.TotalTokens);
    }

    [Fact]
    public void Discovery_UsesKnownRoots_FiltersExtensions_AndCapsNewestFirst()
    {
        string claude = Path.Combine(_root, ".claude", "projects");
        Directory.CreateDirectory(claude);
        string older = Path.Combine(claude, "older.jsonl");
        string newer = Path.Combine(claude, "newer.json");
        File.WriteAllText(older, "{}");
        File.WriteAllText(newer, "{}");
        File.WriteAllText(Path.Combine(claude, "ignored.txt"), "{}");
        File.SetLastWriteTimeUtc(older, DateTime.UtcNow.AddMinutes(-2));
        File.SetLastWriteTimeUtc(newer, DateTime.UtcNow);

        var discovery = new WindowsUsageLogDiscovery(
            new[] { new DiscoveryRoot("claude", claude) },
            maxFiles: 1);

        DiscoveredUsageLog result = Assert.Single(discovery.Discover());
        Assert.Equal(newer, result.Path);
        Assert.Equal(claude, Assert.Single(discovery.WatchRoots));
    }

    [Fact]
    public void SqlCipherStore_PersistsUsageConversationFts_AndAggregateSnapshot()
    {
        Directory.CreateDirectory(_root);
        string database = Path.Combine(_root, "openburnbar.sqlite");
        const string passphrase = "usage-runtime-test-passphrase";
        new WindowsSqlCipherProvisioner().EnsureReady(database, passphrase, "test-protected-key");
        var store = new SqlCipherUsageRuntimeStore(database, passphrase);
        DateTimeOffset now = DateTimeOffset.UtcNow;
        string timestamp = now.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss.fff");
        var usage = new TokenUsageRecord
        {
            Id = "u-1",
            Provider = "claude",
            SessionId = "s-1",
            ProjectName = "burnbar",
            Model = "claude-sonnet-4",
            InputTokens = 10,
            OutputTokens = 5,
            TotalTokens = 15,
            Cost = 0.25,
            StartTime = timestamp,
            EndTime = timestamp,
            CreatedAt = timestamp,
        };
        var conversation = new ConversationRecord(
            "c-1", "claude", "s-1", "burnbar", "Parity runtime", "searchable windows transcript", timestamp, 2);

        (int usageRows, int conversations) = store.Persist(new[]
        {
            new ParsedUsageLog(new[] { usage }, conversation),
        });
        TokenUsageAggregateSnapshot snapshot = store.LoadSnapshot();

        Assert.Equal(1, usageRows);
        Assert.Equal(1, conversations);
        Assert.True(snapshot.HasData);
        Assert.Equal(15, snapshot.TotalTokens);
        Assert.Equal(1, snapshot.SessionCount);
        Assert.Equal(0.25, snapshot.TodayCostUsd, 3);
        Assert.Equal("claude", Assert.Single(snapshot.Providers).Id);

        using OpenBurnBarStorage readStore = OpenBurnBarStorage.OpenReadOnly(database, passphrase);
        ConversationSearchResult hit = Assert.Single(readStore.SearchConversationsFts("searchable"));
        Assert.Equal("c-1", hit.Conversation.Id);
    }

    [Fact]
    public async Task Runtime_PublishesProgressAndReadySnapshot()
    {
        var discovery = new FakeDiscovery(new[]
        {
            new DiscoveredUsageLog("claude", "fixture.jsonl", DateTimeOffset.UtcNow),
        });
        var parser = new FakeParser();
        var store = new FakeStore();
        await using var runtime = new WindowsUsageRuntime(discovery, parser, store);
        var phases = new List<UsageRuntimePhase>();
        runtime.StatusChanged += (_, status) => phases.Add(status.Phase);

        await runtime.StartAsync();

        Assert.Equal(UsageRuntimePhase.Ready, runtime.Status.Phase);
        Assert.Equal(1, runtime.Snapshot.SessionCount);
        Assert.Equal(
            new[] { UsageRuntimePhase.Discovering, UsageRuntimePhase.Parsing, UsageRuntimePhase.Persisting, UsageRuntimePhase.Ready },
            phases);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private string WriteLog(string name, string content)
    {
        Directory.CreateDirectory(_root);
        string path = Path.Combine(_root, name);
        File.WriteAllText(path, content);
        return path;
    }

    private static DiscoveredUsageLog Log(string provider, string path) =>
        new(provider, path, File.GetLastWriteTimeUtc(path));

    private sealed class FakeDiscovery(IReadOnlyList<DiscoveredUsageLog> logs) : IUsageLogDiscovery
    {
        public IReadOnlyList<string> WatchRoots => Array.Empty<string>();
        public IReadOnlyList<DiscoveredUsageLog> Discover(CancellationToken cancellationToken = default) => logs;
    }

    private sealed class FakeParser : IUsageLogParser
    {
        public ParsedUsageLog Parse(DiscoveredUsageLog log, CancellationToken cancellationToken = default) =>
            new(Array.Empty<TokenUsageRecord>(), new ConversationRecord(
                "c", log.Provider, "s", "p", "title", "body", DateTimeOffset.UtcNow.ToString("O"), 1));
    }

    private sealed class FakeStore : IUsageRuntimeStore
    {
        public (int UsageRows, int Conversations) Persist(IReadOnlyList<ParsedUsageLog> logs) => (0, logs.Count);
        public TokenUsageAggregateSnapshot LoadSnapshot() => new(
            0, 0, 0, 10, 1, DateTimeOffset.UtcNow, Array.Empty<double>(),
            Array.Empty<TokenUsageAggregateRow>(), Array.Empty<TokenUsageAggregateRow>());
    }
}

using System.Text.Json;
using OpenBurnBar.App.CloudSync.Pensieve;
using OpenBurnBar.CloudSync.Crypto;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

public sealed class PensieveKnowledgeWatcherTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "openburnbar-pensieve-" + Guid.NewGuid().ToString("N"));
    private static readonly byte[] Key = Enumerable.Repeat((byte)0x42, 32).ToArray();

    [Fact]
    public async Task Scan_WritesSealedBatchAndSessionSentinelThenDedupes()
    {
        string docs = Path.Combine(_root, "docs");
        string sessions = Path.Combine(_root, "sessions");
        string queue = Path.Combine(_root, "queue");
        Directory.CreateDirectory(docs);
        Directory.CreateDirectory(sessions);
        const string sourceText = "A private architecture decision that must be sealed before queueing.";
        await File.WriteAllTextAsync(Path.Combine(docs, "security.md"), sourceText);
        string sessionPath = Path.Combine(sessions, "session.jsonl");
        await File.WriteAllTextAsync(sessionPath, "{\"private\":\"transcript\"}");
        File.SetLastWriteTimeUtc(sessionPath, DateTime.UtcNow.AddMinutes(-5));

        await using var watcher = new PensieveKnowledgeWatcher(
            new[]
            {
                new PensieveWatchRoot(docs, PensieveSourceKind.RepoDocs, new[] { "md" }),
                new PensieveWatchRoot(sessions, PensieveSourceKind.ChatMemory, new[] { "jsonl" }),
            },
            queue,
            () => Key.ToArray(),
            debounceInterval: TimeSpan.FromMilliseconds(10),
            backstopInterval: TimeSpan.FromHours(1));

        PensieveWatcherStatus first = await watcher.ScanNowAsync();
        Assert.Equal(2, first.LastEnqueuedCount);
        Assert.Equal(PensieveWatcherErrorCode.None, first.ErrorCode);
        string batchPath = Assert.Single(Directory.GetFiles(queue, "*.json", SearchOption.TopDirectoryOnly));
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(
                UnixFileMode.UserRead | UnixFileMode.UserWrite,
                File.GetUnixFileMode(batchPath));
        }
        string wire = await File.ReadAllTextAsync(batchPath);
        Assert.DoesNotContain(sourceText, wire, StringComparison.Ordinal);
        PensieveKnowledgeBatch batch = JsonSerializer.Deserialize<PensieveKnowledgeBatch>(wire)!;
        PensieveKnowledgeVector vector = Assert.Single(batch.Vectors);
        Assert.Equal(sourceText, CloudVaultCrypto.OpenText(vector.SealedCiphertext, Key));

        string sentinelDirectory = Path.Combine(queue, "session-end-signals");
        string sentinelPath = Assert.Single(Directory.GetFiles(sentinelDirectory, "*.json"));
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(
                UnixFileMode.UserRead | UnixFileMode.UserWrite,
                File.GetUnixFileMode(sentinelPath));
        }
        using (JsonDocument sentinel = JsonDocument.Parse(await File.ReadAllTextAsync(sentinelPath)))
        {
            Assert.Equal(sessionPath, sentinel.RootElement.GetProperty("sessionPath").GetString());
            Assert.Equal("chat_memory", sentinel.RootElement.GetProperty("sourceKind").GetString());
            Assert.False(sentinel.RootElement.TryGetProperty("transcript", out _));
        }

        PensieveWatcherStatus second = await watcher.ScanNowAsync();
        Assert.Equal(0, second.LastEnqueuedCount);
        Assert.Single(Directory.GetFiles(queue, "*.json", SearchOption.TopDirectoryOnly));
        Assert.Single(Directory.GetFiles(sentinelDirectory, "*.json"));
    }

    [Fact]
    public async Task Scan_FailsClosedWithoutVaultKeyAndWritesNothing()
    {
        string docs = Path.Combine(_root, "docs");
        string queue = Path.Combine(_root, "queue");
        Directory.CreateDirectory(docs);
        await File.WriteAllTextAsync(Path.Combine(docs, "README.md"), "must not queue in plaintext");
        await using var watcher = new PensieveKnowledgeWatcher(
            new[] { new PensieveWatchRoot(docs, PensieveSourceKind.RepoDocs, new[] { "md" }) },
            queue,
            () => null);

        PensieveWatcherStatus status = await watcher.ScanNowAsync();

        Assert.Equal(PensieveWatcherErrorCode.VaultKeyUnavailable, status.ErrorCode);
        Assert.False(Directory.Exists(queue));
    }

    [Fact]
    public async Task Scan_SkipsMalformedUtf8AndOversizedSourcesWithoutWritingQueueData()
    {
        string docs = Path.Combine(_root, "docs");
        string queue = Path.Combine(_root, "queue");
        Directory.CreateDirectory(docs);
        await File.WriteAllBytesAsync(Path.Combine(docs, "invalid.md"), new byte[] { 0xC3, 0x28 });
        await using (var oversized = new FileStream(
            Path.Combine(docs, "oversized.md"),
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None))
        {
            oversized.SetLength(17L * 1024 * 1024);
        }
        await using var watcher = new PensieveKnowledgeWatcher(
            new[] { new PensieveWatchRoot(docs, PensieveSourceKind.RepoDocs, new[] { "md" }) },
            queue,
            () => Key.ToArray());

        PensieveWatcherStatus status = await watcher.ScanNowAsync();

        Assert.Equal(0, status.LastEnqueuedCount);
        Assert.Equal(PensieveWatcherErrorCode.None, status.ErrorCode);
        Assert.False(Directory.Exists(queue));
    }

    [Fact]
    public async Task Scan_DoesNotMutateCallerOwnedVaultKey()
    {
        string docs = Path.Combine(_root, "docs");
        string queue = Path.Combine(_root, "queue");
        Directory.CreateDirectory(docs);
        await File.WriteAllTextAsync(Path.Combine(docs, "README.md"), "caller key ownership");
        byte[] callerOwnedKey = Key.ToArray();
        await using var watcher = new PensieveKnowledgeWatcher(
            new[] { new PensieveWatchRoot(docs, PensieveSourceKind.RepoDocs, new[] { "md" }) },
            queue,
            () => callerOwnedKey);

        await watcher.ScanNowAsync();

        Assert.Equal(Key, callerOwnedKey);
    }

    [Fact]
    public void Constructor_RejectsQueueInsideWatchedRoot()
    {
        string docs = Path.Combine(_root, "docs");
        Directory.CreateDirectory(docs);

        var exception = Assert.Throws<ArgumentException>(() => new PensieveKnowledgeWatcher(
            new[] { new PensieveWatchRoot(docs, PensieveSourceKind.RepoDocs, new[] { "md" }) },
            Path.Combine(docs, "queue"),
            () => Key.ToArray()));

        Assert.Contains("outside", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Scan_ClassifiesUnwritableQueueSeparatelyFromSourceFailures()
    {
        string docs = Path.Combine(_root, "docs");
        string queueFile = Path.Combine(_root, "not-a-directory");
        Directory.CreateDirectory(docs);
        await File.WriteAllTextAsync(Path.Combine(docs, "README.md"), "queue error classification");
        await File.WriteAllTextAsync(queueFile, "occupied");
        await using var watcher = new PensieveKnowledgeWatcher(
            new[] { new PensieveWatchRoot(docs, PensieveSourceKind.RepoDocs, new[] { "md" }) },
            queueFile,
            () => Key.ToArray());

        PensieveWatcherStatus status = await watcher.ScanNowAsync();

        Assert.Equal(PensieveWatcherErrorCode.QueueWriteFailed, status.ErrorCode);
        Assert.Equal(0, status.LastEnqueuedCount);
    }

    [Fact]
    public async Task Start_IsIdempotentAndLiveFileEventTriggersDebouncedScan()
    {
        string docs = Path.Combine(_root, "docs");
        string queue = Path.Combine(_root, "queue");
        Directory.CreateDirectory(docs);
        await using var watcher = new PensieveKnowledgeWatcher(
            new[] { new PensieveWatchRoot(docs, PensieveSourceKind.Notes, new[] { "txt" }) },
            queue,
            () => Key.ToArray(),
            debounceInterval: TimeSpan.FromMilliseconds(40),
            backstopInterval: TimeSpan.FromHours(1));

        watcher.Start();
        watcher.Start();
        await File.WriteAllTextAsync(Path.Combine(docs, "decision.txt"), "Live watcher decision.");
        await WaitUntilAsync(
            () => Directory.Exists(queue) && Directory.GetFiles(queue, "*.json").Length == 1,
            TimeSpan.FromSeconds(5));

        Assert.True(watcher.Status.IsRunning);
        Assert.Equal(1, watcher.Status.LastEnqueuedCount);
        await watcher.DisposeAsync();
        Assert.False(watcher.Status.IsRunning);
    }

    [Fact]
    public async Task Dispose_AwaitsEveryDebouncedBurstAndPreventsLateQueueWrites()
    {
        string docs = Path.Combine(_root, "docs");
        string queue = Path.Combine(_root, "queue");
        Directory.CreateDirectory(docs);
        var watcher = new PensieveKnowledgeWatcher(
            new[] { new PensieveWatchRoot(docs, PensieveSourceKind.Notes, new[] { "txt" }) },
            queue,
            () => Key.ToArray(),
            debounceInterval: TimeSpan.FromSeconds(2),
            backstopInterval: TimeSpan.FromHours(1));
        watcher.Start();
        for (int index = 0; index < 25; index++)
        {
            await File.WriteAllTextAsync(Path.Combine(docs, $"burst-{index}.txt"), $"burst {index}");
        }

        await watcher.DisposeAsync();
        int filesAtDispose = Directory.Exists(queue)
            ? Directory.GetFiles(queue, "*.json", SearchOption.AllDirectories).Length
            : 0;
        await Task.Delay(150);

        int filesAfterDelay = Directory.Exists(queue)
            ? Directory.GetFiles(queue, "*.json", SearchOption.AllDirectories).Length
            : 0;
        Assert.Equal(filesAtDispose, filesAfterDelay);
        Assert.False(watcher.Status.IsRunning);
    }

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); }
        catch (DirectoryNotFoundException) { }
        catch (IOException) { }
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, TimeSpan timeout)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow + timeout;
        while (!predicate())
        {
            if (DateTimeOffset.UtcNow >= deadline)
            {
                throw new TimeoutException("Pensieve watcher did not produce the expected queue artifact.");
            }
            await Task.Delay(25);
        }
    }
}

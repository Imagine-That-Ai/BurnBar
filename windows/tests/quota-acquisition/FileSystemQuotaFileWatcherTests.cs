using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Quota.Acquisition.Windows;
using Xunit;

namespace OpenBurnBar.App.Quota.Acquisition.Tests;

/// <summary>
/// The real FileSystemWatcher adapter (the .Windows half). FileSystemWatcher is
/// a portable .NET API, so the debounced single-file contract is provable on the
/// macOS authoring host; the %APPDATA%-pathed live run is the WS-D remainder.
/// Timing-tolerant by design (real FS events).
/// </summary>
public sealed class FileSystemQuotaFileWatcherTests : IDisposable
{
    private readonly string _dir = AcquisitionTestSupport.CreateTempDirectory();

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public async Task Write_FiresChangedWithTheWatchedPath()
    {
        var path = Path.Combine(_dir, "claude_statusline_snapshot.json");
        using var watcher = new FileSystemQuotaFileWatcher(path, debounce: TimeSpan.FromMilliseconds(50));
        var fired = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        watcher.Changed += changed => fired.TrySetResult(changed);
        watcher.Start();

        await File.WriteAllTextAsync(path, "{\"rate_limits\":{}}");

        var completed = await Task.WhenAny(fired.Task, Task.Delay(TimeSpan.FromSeconds(10)));
        Assert.True(completed == fired.Task, "watcher never fired for a write");
        Assert.Equal(path, await fired.Task);
    }

    [Fact]
    public async Task AtomicReplace_DeleteThenRecreate_StillFires()
    {
        var path = Path.Combine(_dir, "snapshot.json");
        File.WriteAllText(path, "old");
        using var watcher = new FileSystemQuotaFileWatcher(path, debounce: TimeSpan.FromMilliseconds(50));
        var count = 0;
        var fired = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        watcher.Changed += _ =>
        {
            if (Interlocked.Increment(ref count) >= 1)
            {
                fired.TrySetResult();
            }
        };
        watcher.Start();

        // The atomic-replace pattern the Mac watcher needed a reopen dance for:
        // directory-level watching absorbs it directly.
        File.Delete(path);
        await File.WriteAllTextAsync(path, "new");

        var completed = await Task.WhenAny(fired.Task, Task.Delay(TimeSpan.FromSeconds(10)));
        Assert.True(completed == fired.Task, "watcher never fired for delete+recreate");
    }

    [Fact]
    public void Start_CreatesTheWatchedDirectory_AndIsIdempotent()
    {
        var nested = Path.Combine(_dir, "sub", "dir");
        var path = Path.Combine(nested, "snapshot.json");
        using var watcher = new FileSystemQuotaFileWatcher(path);

        watcher.Start();
        watcher.Start();

        Assert.True(Directory.Exists(nested));
    }

    [Fact]
    public void Dispose_ThenStart_IsSafe()
    {
        var watcher = new FileSystemQuotaFileWatcher(Path.Combine(_dir, "s.json"));
        watcher.Dispose();

        watcher.Start(); // no-op after dispose — must not throw or watch
    }
}

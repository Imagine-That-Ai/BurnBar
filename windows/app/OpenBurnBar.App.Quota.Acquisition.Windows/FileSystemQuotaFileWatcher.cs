using System;
using System.IO;
using System.Threading;

namespace OpenBurnBar.App.Quota.Acquisition.Windows;

// FileSystemWatcher-backed IQuotaFileWatcher — the Windows peer of the Mac
// DispatchSource watcher in AgentLens/Services/ProviderQuota/
// ClaudeStatuslineWatcher.swift. Watching the PARENT DIRECTORY (filtered to the
// file name) makes atomic replaces (delete + rename) self-healing without the
// Mac's fd-reopen backoff dance; the 250 ms debounce is preserved.

/// <summary>Debounced single-file watcher.</summary>
public sealed class FileSystemQuotaFileWatcher : IQuotaFileWatcher
{
    private readonly string _filePath;
    private readonly TimeSpan _debounce;
    private readonly object _gate = new();

    private FileSystemWatcher? _watcher;
    private Timer? _timer;
    private bool _disposed;

    /// <summary>Watch one file. Debounce defaults to the Mac 250 ms.</summary>
    public FileSystemQuotaFileWatcher(string filePath, TimeSpan? debounce = null)
    {
        _filePath = filePath ?? throw new ArgumentNullException(nameof(filePath));
        _debounce = debounce ?? QuotaAcquisitionPolicy.ChangeDebounce;
    }

    /// <inheritdoc />
    public event Action<string>? Changed;

    /// <inheritdoc />
    public void Start()
    {
        lock (_gate)
        {
            if (_disposed || _watcher is not null)
            {
                return;
            }

            string directory = Path.GetDirectoryName(_filePath) is { Length: > 0 } parent
                ? parent
                : ".";
            Directory.CreateDirectory(directory);

            _timer = new Timer(static state => ((FileSystemQuotaFileWatcher)state!).Fire(), this,
                Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);

            var watcher = new FileSystemWatcher(directory, Path.GetFileName(_filePath))
            {
                NotifyFilter = NotifyFilters.LastWrite
                    | NotifyFilters.FileName
                    | NotifyFilters.Size
                    | NotifyFilters.CreationTime,
            };
            watcher.Changed += OnFileSystemEvent;
            watcher.Created += OnFileSystemEvent;
            watcher.Deleted += OnFileSystemEvent;
            watcher.Renamed += OnFileSystemEvent;
            watcher.EnableRaisingEvents = true;
            _watcher = watcher;
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
            _watcher?.Dispose();
            _watcher = null;
            _timer?.Dispose();
            _timer = null;
        }
    }

    private void OnFileSystemEvent(object sender, FileSystemEventArgs args)
    {
        lock (_gate)
        {
            // Coalesce bursts: every event pushes the single timer's due time out
            // by the debounce window (Mac debounceNanoseconds semantics).
            _timer?.Change(_debounce, Timeout.InfiniteTimeSpan);
        }
    }

    private void Fire()
    {
        Changed?.Invoke(_filePath);
    }
}

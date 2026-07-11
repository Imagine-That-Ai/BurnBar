using OpenBurnBar.Storage;

namespace OpenBurnBar.App.UsageRuntime;

public sealed class WindowsUsageRuntime : IWindowsUsageRuntime
{
    private static readonly TimeSpan WatchDebounce = TimeSpan.FromMilliseconds(750);

    private readonly IUsageLogDiscovery _discovery;
    private readonly IUsageLogParser _parser;
    private readonly IUsageRuntimeStore _store;
    private readonly SemaphoreSlim _scanGate = new(1, 1);
    private readonly List<FileSystemWatcher> _watchers = new();
    private readonly object _debounceGate = new();

    private CancellationTokenSource? _lifetime;
    private CancellationTokenSource? _debounce;
    private bool _started;

    public WindowsUsageRuntime(
        IUsageLogDiscovery discovery,
        IUsageLogParser parser,
        IUsageRuntimeStore store)
    {
        _discovery = discovery ?? throw new ArgumentNullException(nameof(discovery));
        _parser = parser ?? throw new ArgumentNullException(nameof(parser));
        _store = store ?? throw new ArgumentNullException(nameof(store));
    }

    public event EventHandler<TokenUsageAggregateSnapshot>? SnapshotChanged;
    public event EventHandler<UsageRuntimeStatus>? StatusChanged;

    public TokenUsageAggregateSnapshot Snapshot { get; private set; } = TokenUsageAggregateSnapshot.Empty;
    public UsageRuntimeStatus Status { get; private set; } = new(UsageRuntimePhase.NotStarted, "Usage runtime has not started.");

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_started) return;
        _started = true;
        _lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        StartWatchers();
        await ScanAsync(_lifetime.Token).ConfigureAwait(false);
    }

    public async Task<UsageScanResult> ScanAsync(CancellationToken cancellationToken = default)
    {
        await _scanGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            SetStatus(new UsageRuntimeStatus(UsageRuntimePhase.Discovering, "Discovering provider logs..."));
            IReadOnlyList<DiscoveredUsageLog> discovered = await Task.Run(
                () => _discovery.Discover(cancellationToken),
                cancellationToken).ConfigureAwait(false);

            SetStatus(new UsageRuntimeStatus(
                UsageRuntimePhase.Parsing,
                discovered.Count == 0 ? "No provider logs found." : $"Parsing {discovered.Count} provider logs...",
                DiscoveredFiles: discovered.Count));

            var parsed = new List<ParsedUsageLog>(discovered.Count);
            int failed = 0;
            foreach (DiscoveredUsageLog log in discovered)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    ParsedUsageLog result = await Task.Run(
                        () => _parser.Parse(log, cancellationToken),
                        cancellationToken).ConfigureAwait(false);
                    if (result.UsageRecords.Count > 0 || result.Conversation is not null) parsed.Add(result);
                }
                catch (IOException)
                {
                    failed++;
                }
                catch (UnauthorizedAccessException)
                {
                    failed++;
                }
                catch (InvalidDataException)
                {
                    failed++;
                }
            }

            SetStatus(new UsageRuntimeStatus(
                UsageRuntimePhase.Persisting,
                "Updating encrypted usage data...",
                DiscoveredFiles: discovered.Count,
                ParsedFiles: parsed.Count,
                FailedFiles: failed));
            (int usageRows, int conversations) = await Task.Run(
                () => _store.Persist(parsed),
                cancellationToken).ConfigureAwait(false);
            TokenUsageAggregateSnapshot snapshot = await Task.Run(
                _store.LoadSnapshot,
                cancellationToken).ConfigureAwait(false);
            Snapshot = snapshot;
            SnapshotChanged?.Invoke(this, snapshot);

            DateTimeOffset completed = DateTimeOffset.UtcNow;
            SetStatus(new UsageRuntimeStatus(
                snapshot.HasData ? UsageRuntimePhase.Ready : UsageRuntimePhase.Empty,
                snapshot.HasData
                    ? $"Updated {snapshot.SessionCount} sessions from {parsed.Count} logs."
                    : "No supported usage records were found yet.",
                completed,
                discovered.Count,
                parsed.Count,
                failed));
            return new UsageScanResult(
                discovered.Count,
                parsed.Count,
                failed,
                usageRows,
                conversations,
                snapshot,
                completed);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            SetStatus(new UsageRuntimeStatus(UsageRuntimePhase.Failed, $"Usage scan failed: {ex.Message}"));
            throw;
        }
        finally
        {
            _scanGate.Release();
        }
    }

    public Task StopAsync()
    {
        _lifetime?.Cancel();
        lock (_debounceGate)
        {
            _debounce?.Cancel();
            _debounce?.Dispose();
            _debounce = null;
        }
        foreach (FileSystemWatcher watcher in _watchers) watcher.Dispose();
        _watchers.Clear();
        _started = false;
        SetStatus(new UsageRuntimeStatus(UsageRuntimePhase.Stopped, "Usage runtime stopped."));
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _lifetime?.Dispose();
        _scanGate.Dispose();
    }

    private void StartWatchers()
    {
        foreach (string root in _discovery.WatchRoots)
        {
            try
            {
                var watcher = new FileSystemWatcher(root)
                {
                    IncludeSubdirectories = true,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
                    Filter = "*.*",
                    EnableRaisingEvents = true,
                };
                watcher.Changed += OnLogChanged;
                watcher.Created += OnLogChanged;
                watcher.Renamed += OnLogChanged;
                _watchers.Add(watcher);
            }
            catch (IOException)
            {
                // A disappearing optional provider root does not block other providers.
            }
            catch (UnauthorizedAccessException)
            {
                // Permission state is surfaced by the scan's partial-file count.
            }
        }
    }

    private void OnLogChanged(object sender, FileSystemEventArgs e)
    {
        string extension = Path.GetExtension(e.FullPath);
        if (!extension.Equals(".jsonl", StringComparison.OrdinalIgnoreCase)
            && !extension.Equals(".json", StringComparison.OrdinalIgnoreCase)) return;

        lock (_debounceGate)
        {
            _debounce?.Cancel();
            _debounce?.Dispose();
            _debounce = CancellationTokenSource.CreateLinkedTokenSource(_lifetime?.Token ?? CancellationToken.None);
            CancellationToken token = _debounce.Token;
            _ = DebouncedScanAsync(token);
        }
    }

    private async Task DebouncedScanAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(WatchDebounce, cancellationToken).ConfigureAwait(false);
            await ScanAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        catch
        {
            // ScanAsync already publishes a typed failed state to the UI.
        }
    }

    private void SetStatus(UsageRuntimeStatus status)
    {
        Status = status;
        StatusChanged?.Invoke(this, status);
    }
}

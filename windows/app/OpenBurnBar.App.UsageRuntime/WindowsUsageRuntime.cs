using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.UsageRuntime;

/// <summary>
/// Process owner for local provider ingestion. Scans are serialized, file events
/// are debounced, and a periodic scan closes gaps caused by providers creating a
/// log directory after app launch or by dropped filesystem notifications.
/// </summary>
public sealed class WindowsUsageRuntime : IUsageRuntime
{
    private readonly object _stateGate = new();
    private readonly object _watcherGate = new();
    private readonly IUsageEngine _engine;
    private readonly IUsageRuntimeSnapshotStore _snapshotStore;
    private readonly WindowsUsagePaths _paths;
    private readonly TimeSpan _periodicInterval;
    private readonly TimeSpan _fileChangeDebounce;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Action<Exception>? _errorSink;
    private readonly SemaphoreSlim _scanGate = new(1, 1);
    private readonly List<FileSystemWatcher> _watchers = new();

    private UsageRuntimeState _state = UsageRuntimeState.NotStarted;
    private CancellationTokenSource? _lifetimeCancellation;
    private CancellationTokenSource? _debounceCancellation;
    private Task? _periodicTask;
    private Task? _startupTask;
    private bool _started;
    private bool _disposed;

    public WindowsUsageRuntime(
        IUsageEngine engine,
        IUsageRuntimeSnapshotStore snapshotStore,
        WindowsUsagePaths paths,
        TimeSpan? periodicInterval = null,
        TimeSpan? fileChangeDebounce = null,
        Func<DateTimeOffset>? clock = null,
        Action<Exception>? errorSink = null)
    {
        _engine = engine ?? throw new ArgumentNullException(nameof(engine));
        _snapshotStore = snapshotStore ?? throw new ArgumentNullException(nameof(snapshotStore));
        _paths = paths ?? throw new ArgumentNullException(nameof(paths));
        _periodicInterval = periodicInterval ?? TimeSpan.FromSeconds(60);
        _fileChangeDebounce = fileChangeDebounce ?? TimeSpan.FromMilliseconds(750);
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _errorSink = errorSink;

        if (_periodicInterval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(periodicInterval));
        }
        if (_fileChangeDebounce < TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(fileChangeDebounce));
        }
    }

    public event EventHandler<UsageRuntimeStateChangedEventArgs>? StateChanged;

    public UsageRuntimeState State
    {
        get
        {
            lock (_stateGate)
            {
                return _state;
            }
        }
    }

    /// <summary>Effective periodic refresh cadence selected by the app composition root.</summary>
    public TimeSpan PeriodicInterval => _periodicInterval;

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        lock (_stateGate)
        {
            if (_started)
            {
                return;
            }
            _started = true;
            _lifetimeCancellation = new CancellationTokenSource();
        }

        RebuildWatchers();
        _periodicTask = RunPeriodicScansAsync(_lifetimeCancellation.Token);
        Task startupTask = ScanAsync(UsageScanReason.Startup, cancellationToken);
        lock (_stateGate)
        {
            _startupTask = startupTask;
        }
        try
        {
            await startupTask.ConfigureAwait(false);
        }
        finally
        {
            lock (_stateGate)
            {
                if (ReferenceEquals(_startupTask, startupTask))
                {
                    _startupTask = null;
                }
            }
        }
    }

    public async Task ScanAsync(
        UsageScanReason reason,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        bool acquired;
        if (reason is UsageScanReason.FileChanged or UsageScanReason.Periodic)
        {
            acquired = await _scanGate.WaitAsync(0, cancellationToken).ConfigureAwait(false);
            if (!acquired)
            {
                return;
            }
        }
        else
        {
            await _scanGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            acquired = true;
        }

        UsageRuntimeState before = State;
        try
        {
            Publish(before with
            {
                Phase = UsageRuntimePhase.Scanning,
                Reason = reason,
                FailureKind = null,
                StatusMessage = reason == UsageScanReason.Manual
                    ? "Scanning provider activity..."
                    : "Refreshing provider activity...",
            });

            UsageEngineScanResponse response = await _engine
                .ScanAsync(_paths.ScanRequest, cancellationToken)
                .ConfigureAwait(false);
            if (!response.Ok)
            {
                throw new UsageRuntimeException(
                    UsageRuntimeFailureKind.NativeEngineFailure,
                    "The parser engine could not complete the usage scan.");
            }

            await _snapshotStore.PersistAsync(response, cancellationToken).ConfigureAwait(false);
            DateTimeOffset capturedAt = _clock();
            var snapshot = new UsageRuntimeSnapshot(
                response.Usages.ToArray(),
                response.Conversations.ToArray(),
                capturedAt);
            int failedProviders = response.Providers.Count(provider =>
                provider.Status == UsageProviderScanStatus.Failed);
            bool hasData = snapshot.Usages.Count > 0 || snapshot.Conversations.Count > 0;

            UsageRuntimePhase phase = failedProviders > 0
                ? UsageRuntimePhase.Degraded
                : hasData
                    ? UsageRuntimePhase.Ready
                    : UsageRuntimePhase.NoData;
            string status = phase switch
            {
                UsageRuntimePhase.Degraded => "Some providers could not be refreshed. Retry the scan.",
                UsageRuntimePhase.Ready => $"Updated {FormatFreshness(capturedAt, capturedAt)}",
                _ => "No supported provider activity found yet.",
            };

            Publish(new UsageRuntimeState(
                phase,
                reason,
                snapshot,
                response.Providers.ToArray(),
                capturedAt,
                failedProviders > 0 ? UsageRuntimeFailureKind.NativeEngineFailure : null,
                status));
            RebuildWatchers();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            Publish(before);
            throw;
        }
        catch (UsageRuntimeException ex)
        {
            _errorSink?.Invoke(ex);
            PublishFailure(before, reason, ex.Kind);
        }
        catch (Exception ex)
        {
            _errorSink?.Invoke(ex);
            PublishFailure(before, reason, UsageRuntimeFailureKind.Unexpected);
        }
        finally
        {
            if (acquired)
            {
                _scanGate.Release();
            }
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        CancellationTokenSource? lifetime;
        Task? periodic;
        Task? startup;
        lock (_stateGate)
        {
            if (!_started)
            {
                return;
            }
            _started = false;
            lifetime = _lifetimeCancellation;
            _lifetimeCancellation = null;
            periodic = _periodicTask;
            _periodicTask = null;
            startup = _startupTask;
            _startupTask = null;
        }

        lifetime?.Cancel();
        CancelDebounce();
        DisposeWatchers();
        if (periodic is not null)
        {
            try
            {
                await periodic.WaitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (lifetime?.IsCancellationRequested == true)
            {
            }
        }
        if (startup is not null)
        {
            await startup.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        lifetime?.Dispose();
        Publish(State with
        {
            Phase = UsageRuntimePhase.Stopped,
            Reason = null,
            StatusMessage = "Usage runtime stopped.",
        });
    }

    private async Task RunPeriodicScansAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(_periodicInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
            {
                await ScanAsync(UsageScanReason.Periodic, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private void RebuildWatchers()
    {
        lock (_watcherGate)
        {
            DisposeWatchersUnlocked();
            foreach (string directory in _paths.WatchDirectories
                         .Where(Directory.Exists)
                         .Distinct(StringComparer.OrdinalIgnoreCase))
            {
                try
                {
                    var watcher = new FileSystemWatcher(directory)
                    {
                        IncludeSubdirectories = true,
                        NotifyFilter = NotifyFilters.FileName
                            | NotifyFilters.DirectoryName
                            | NotifyFilters.LastWrite
                            | NotifyFilters.Size,
                        Filter = "*",
                        EnableRaisingEvents = true,
                    };
                    watcher.Changed += OnProviderFileChanged;
                    watcher.Created += OnProviderFileChanged;
                    watcher.Deleted += OnProviderFileChanged;
                    watcher.Renamed += OnProviderFileRenamed;
                    watcher.Error += OnWatcherError;
                    _watchers.Add(watcher);
                }
                catch (Exception ex) when (ex is IOException
                                           or UnauthorizedAccessException
                                           or ArgumentException)
                {
                    _errorSink?.Invoke(ex);
                }
            }
        }
    }

    private void OnProviderFileChanged(object sender, FileSystemEventArgs args) => ScheduleDebouncedScan();

    private void OnProviderFileRenamed(object sender, RenamedEventArgs args) => ScheduleDebouncedScan();

    private void OnWatcherError(object sender, ErrorEventArgs args)
    {
        _errorSink?.Invoke(args.GetException());
        ScheduleDebouncedScan();
    }

    private void ScheduleDebouncedScan()
    {
        CancellationToken lifetimeToken;
        lock (_stateGate)
        {
            if (!_started || _lifetimeCancellation is null)
            {
                return;
            }
            lifetimeToken = _lifetimeCancellation.Token;
        }

        lock (_watcherGate)
        {
            _debounceCancellation?.Cancel();
            _debounceCancellation?.Dispose();
            _debounceCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetimeToken);
            _ = RunDebouncedScanAsync(_debounceCancellation.Token);
        }
    }

    private async Task RunDebouncedScanAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(_fileChangeDebounce, cancellationToken).ConfigureAwait(false);
            await ScanAsync(UsageScanReason.FileChanged, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private void CancelDebounce()
    {
        lock (_watcherGate)
        {
            _debounceCancellation?.Cancel();
            _debounceCancellation?.Dispose();
            _debounceCancellation = null;
        }
    }

    private void DisposeWatchers()
    {
        lock (_watcherGate)
        {
            DisposeWatchersUnlocked();
        }
    }

    private void DisposeWatchersUnlocked()
    {
        foreach (FileSystemWatcher watcher in _watchers)
        {
            watcher.EnableRaisingEvents = false;
            watcher.Changed -= OnProviderFileChanged;
            watcher.Created -= OnProviderFileChanged;
            watcher.Deleted -= OnProviderFileChanged;
            watcher.Renamed -= OnProviderFileRenamed;
            watcher.Error -= OnWatcherError;
            watcher.Dispose();
        }
        _watchers.Clear();
    }

    private void PublishFailure(
        UsageRuntimeState before,
        UsageScanReason reason,
        UsageRuntimeFailureKind kind)
    {
        UsageRuntimePhase phase = kind == UsageRuntimeFailureKind.NativeEngineUnavailable
            ? UsageRuntimePhase.Unavailable
            : before.LastSuccessfulScan is null
                ? UsageRuntimePhase.Failed
                : UsageRuntimePhase.Degraded;
        string message = kind switch
        {
            UsageRuntimeFailureKind.NativeEngineUnavailable =>
                "Usage engine unavailable. Repair or reinstall OpenBurnBar.",
            UsageRuntimeFailureKind.Storage =>
                "Encrypted usage storage needs attention. Open Data & Privacy settings.",
            _ => "Usage refresh failed. Retry the scan or open Diagnostics.",
        };
        Publish(before with
        {
            Phase = phase,
            Reason = reason,
            FailureKind = kind,
            StatusMessage = message,
        });
    }

    private void Publish(UsageRuntimeState next)
    {
        UsageRuntimeState previous;
        lock (_stateGate)
        {
            previous = _state;
            _state = next;
        }

        EventHandler<UsageRuntimeStateChangedEventArgs>? handlers = StateChanged;
        if (handlers is null)
        {
            return;
        }

        var args = new UsageRuntimeStateChangedEventArgs(previous, next);
        foreach (EventHandler<UsageRuntimeStateChangedEventArgs> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, args);
            }
            catch (Exception ex)
            {
                _errorSink?.Invoke(ex);
            }
        }
    }

    public static string FormatFreshness(DateTimeOffset capturedAt, DateTimeOffset now)
    {
        TimeSpan age = now - capturedAt;
        if (age < TimeSpan.FromMinutes(1))
        {
            return "just now";
        }
        if (age < TimeSpan.FromHours(1))
        {
            int minutes = Math.Max(1, (int)Math.Floor(age.TotalMinutes));
            return $"{minutes} min ago";
        }
        if (age < TimeSpan.FromDays(1))
        {
            int hours = Math.Max(1, (int)Math.Floor(age.TotalHours));
            return $"{hours} hr ago";
        }
        return capturedAt.ToLocalTime().ToString("MMM d, h:mm tt");
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }
        await StopAsync().ConfigureAwait(false);
        _disposed = true;
        _scanGate.Dispose();
        if (_engine is IDisposable disposableEngine)
        {
            disposableEngine.Dispose();
        }
        if (_snapshotStore is IDisposable disposableStore)
        {
            disposableStore.Dispose();
        }
    }
}

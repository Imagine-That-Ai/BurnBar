using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;

namespace OpenBurnBar.App.Quota.Acquisition;

// Fan-in over the acquisition sources, mirroring the Mac pacing discipline:
//   • ProviderQuotaService.startAutomaticRefresh — 5 min initial delay, 15 min
//     interval (RunAutomaticRefreshLoopAsync);
//   • QuotaRefreshActor.maxConcurrentQuotaFetches = 4 (the refresh semaphore);
//   • ClaudeStatuslineWatcher's 250 ms debounce (SignalChangeAsync);
//   • one retry per source on error (Swift's single-retry-after-nudge shape).
// Time is injectable (IQuotaAcquisitionClock) so every timing path is
// deterministic under test.

/// <summary>Coordinator tuning knobs (defaults = the Mac constants).</summary>
public sealed record QuotaAcquisitionOptions
{
    /// <summary>Change-signal debounce (250 ms).</summary>
    public TimeSpan ChangeDebounce { get; init; } = QuotaAcquisitionPolicy.ChangeDebounce;

    /// <summary>Attempts per source per refresh (1 retry).</summary>
    public int MaxAttemptsPerSource { get; init; } = 2;

    /// <summary>Delay between attempts.</summary>
    public TimeSpan RetryDelay { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>Automatic-loop initial delay (5 min).</summary>
    public TimeSpan InitialRefreshDelay { get; init; } = QuotaAcquisitionPolicy.AutoRefreshInitialDelay;

    /// <summary>Automatic-loop interval (15 min).</summary>
    public TimeSpan RefreshInterval { get; init; } = QuotaAcquisitionPolicy.AutoRefreshInterval;

    /// <summary>Fan-out cap (4).</summary>
    public int MaxConcurrentFetches { get; init; } = QuotaAcquisitionPolicy.MaxConcurrentFetches;
}

/// <summary>Fans acquisition sources into a per-source latest-snapshot stream.</summary>
public sealed class QuotaAcquisitionCoordinator : IDisposable
{
    private readonly IReadOnlyList<IQuotaPayloadSource> _sources;
    private readonly IQuotaAcquisitionClock _clock;
    private readonly QuotaAcquisitionOptions _options;
    private readonly SemaphoreSlim _fetchGate;

    private readonly object _gate = new();
    private readonly Dictionary<string, ProviderQuotaSnapshot> _latestBySource = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _lastErrors = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Task> _pendingSignals = new(StringComparer.Ordinal);
    private readonly List<IQuotaFileWatcher> _watchers = new();

    /// <summary>Create a coordinator over the given sources.</summary>
    public QuotaAcquisitionCoordinator(
        IEnumerable<IQuotaPayloadSource> sources,
        IQuotaAcquisitionClock? clock = null,
        QuotaAcquisitionOptions? options = null)
    {
        _sources = (sources ?? throw new ArgumentNullException(nameof(sources))).ToList();
        _clock = clock ?? SystemQuotaAcquisitionClock.Instance;
        _options = options ?? new QuotaAcquisitionOptions();
        _fetchGate = new SemaphoreSlim(Math.Max(1, _options.MaxConcurrentFetches));
    }

    /// <summary>Raised (with the new latest list) whenever a refresh changed a snapshot.</summary>
    public event Action<IReadOnlyList<ProviderQuotaSnapshot>>? SnapshotsChanged;

    /// <summary>
    /// The latest snapshot per source, ordered by source id. Last-known-good is
    /// sticky: a source that later yields nothing keeps its previous snapshot
    /// (Mac store semantics — snapshots persist until replaced).
    /// </summary>
    public IReadOnlyList<ProviderQuotaSnapshot> LatestSnapshots
    {
        get
        {
            lock (_gate)
            {
                return _latestBySource
                    .OrderBy(static pair => pair.Key, StringComparer.Ordinal)
                    .Select(static pair => pair.Value)
                    .ToList();
            }
        }
    }

    /// <summary>Last error message per source id (observability; cleared on success).</summary>
    public IReadOnlyDictionary<string, string> LastErrors
    {
        get
        {
            lock (_gate)
            {
                return new Dictionary<string, string>(_lastErrors, StringComparer.Ordinal);
            }
        }
    }

    /// <summary>Refresh every source (capped fan-out) and return the latest list.</summary>
    public async Task<IReadOnlyList<ProviderQuotaSnapshot>> RefreshAsync(CancellationToken cancellationToken = default)
    {
        var tasks = _sources.Select(source => AcquireGatedAsync(source, cancellationToken)).ToList();
        var results = await Task.WhenAll(tasks).ConfigureAwait(false);

        var changed = false;
        lock (_gate)
        {
            for (var i = 0; i < _sources.Count; i++)
            {
                changed |= StoreLocked(_sources[i].SourceId, results[i]);
            }
        }

        if (changed)
        {
            SnapshotsChanged?.Invoke(LatestSnapshots);
        }

        return LatestSnapshots;
    }

    /// <summary>Refresh one source by id (no-op for unknown ids).</summary>
    public async Task RefreshSourceAsync(string sourceId, CancellationToken cancellationToken = default)
    {
        IQuotaPayloadSource? source = _sources.FirstOrDefault(s => s.SourceId == sourceId);
        if (source is null)
        {
            return;
        }

        ProviderQuotaSnapshot? snapshot = await AcquireGatedAsync(source, cancellationToken).ConfigureAwait(false);

        bool changed;
        lock (_gate)
        {
            changed = StoreLocked(sourceId, snapshot);
        }

        if (changed)
        {
            SnapshotsChanged?.Invoke(LatestSnapshots);
        }
    }

    /// <summary>
    /// Debounced change signal (the watcher path). Signals for the same source
    /// within the debounce window coalesce into ONE refresh — the returned task
    /// completes when that refresh does.
    /// </summary>
    public Task SignalChangeAsync(string sourceId, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_pendingSignals.TryGetValue(sourceId, out Task? pending))
            {
                return pending;
            }

            Task task = DebouncedRefreshAsync(sourceId, cancellationToken);
            _pendingSignals[sourceId] = task;
            return task;
        }
    }

    /// <summary>Route a watcher's change events into <see cref="SignalChangeAsync"/> and start it.</summary>
    public void AttachWatcher(IQuotaFileWatcher watcher, string sourceId)
    {
        ArgumentNullException.ThrowIfNull(watcher);
        watcher.Changed += changedPath => _ = SignalChangeSafeAsync(sourceId);
        lock (_gate)
        {
            _watchers.Add(watcher);
        }

        watcher.Start();
    }

    /// <summary>
    /// The Mac auto-refresh cadence: wait the initial delay, then refresh every
    /// interval until cancelled.
    /// </summary>
    public async Task RunAutomaticRefreshLoopAsync(CancellationToken cancellationToken)
    {
        await _clock.Delay(_options.InitialRefreshDelay, cancellationToken).ConfigureAwait(false);
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await RefreshAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception)
            {
                // Per-source failures are already isolated; this guards the loop itself.
            }

            await _clock.Delay(_options.RefreshInterval, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        List<IQuotaFileWatcher> watchers;
        lock (_gate)
        {
            watchers = new List<IQuotaFileWatcher>(_watchers);
            _watchers.Clear();
        }

        foreach (IQuotaFileWatcher watcher in watchers)
        {
            watcher.Dispose();
        }

        _fetchGate.Dispose();
    }

    private async Task SignalChangeSafeAsync(string sourceId)
    {
        try
        {
            await SignalChangeAsync(sourceId).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Watcher callbacks must never throw into the file-watcher thread.
        }
    }

    private async Task DebouncedRefreshAsync(string sourceId, CancellationToken cancellationToken)
    {
        try
        {
            await _clock.Delay(_options.ChangeDebounce, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (_gate)
            {
                _pendingSignals.Remove(sourceId);
            }
        }

        await RefreshSourceAsync(sourceId, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Store a result. Returns whether the latest list changed. Caller holds the gate.</summary>
    private bool StoreLocked(string sourceId, ProviderQuotaSnapshot? snapshot)
    {
        if (snapshot is null)
        {
            // Sticky last-known-good: "no signal" keeps the previous snapshot.
            return false;
        }

        _latestBySource.TryGetValue(sourceId, out ProviderQuotaSnapshot? previous);
        _latestBySource[sourceId] = snapshot;
        return !ReferenceEquals(previous, snapshot);
    }

    private async Task<ProviderQuotaSnapshot?> AcquireGatedAsync(
        IQuotaPayloadSource source,
        CancellationToken cancellationToken)
    {
        await _fetchGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await AcquireWithRetryAsync(source, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _fetchGate.Release();
        }
    }

    private async Task<ProviderQuotaSnapshot?> AcquireWithRetryAsync(
        IQuotaPayloadSource source,
        CancellationToken cancellationToken)
    {
        var attempts = Math.Max(1, _options.MaxAttemptsPerSource);
        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            try
            {
                ProviderQuotaSnapshot? snapshot =
                    await source.TryAcquireAsync(cancellationToken).ConfigureAwait(false);
                lock (_gate)
                {
                    _lastErrors.Remove(source.SourceId);
                }

                return snapshot;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception)
            {
                lock (_gate)
                {
                    _lastErrors[source.SourceId] = exception.Message;
                }

                if (attempt < attempts)
                {
                    await _clock.Delay(_options.RetryDelay, cancellationToken).ConfigureAwait(false);
                }
            }
        }

        return null;
    }
}

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.CloudSync.Sync;

/// <summary>
/// The live Firestore sync orchestration: a portable poll-then-snapshot-diff loop
/// over the existing <see cref="ICloudSyncGateway"/> (the real
/// <c>FirestoreRestGateway</c> in production). Firestore's REST wire has no
/// <c>documents:listen</c> channel off-Apple, and the macOS "Cloud→Local" pull is
/// itself one-shot <c>getDocuments()</c> polling
/// (<c>AgentLens/Services/CloudSync/DownloadSyncService.swift</c>), so this
/// reproduces the change stream by polling each domain, diffing against last-known
/// state, and raising per-domain change events.
/// </summary>
/// <remarks>
/// <para><b>Fail-closed.</b> A domain read that throws (e.g. the App-Check-required
/// gateway refusing an un-attested request, or a transport fault) never clears the
/// domain's last-known state and never fabricates "Removed" changes; it raises
/// <see cref="DomainErrored"/> and schedules a backoff retry. Only a SUCCESSFUL poll
/// advances a domain's state.</para>
/// <para><b>Testable timeline.</b> <see cref="PollOnceAsync"/> is the deterministic
/// unit (no timers). <see cref="RunAsync"/> wraps it in a loop whose wait is an
/// injected delay function + <see cref="ISyncClock"/>, so backoff is proven without
/// real sleeping.</para>
/// </remarks>
public sealed class FirestoreSyncCoordinator
{
    private readonly ICloudSyncGateway _gateway;
    private readonly IReadOnlyList<SyncDomainDefinition> _domains;
    private readonly ISyncClock _clock;
    private readonly SyncBackoffPolicy _backoff;
    private readonly long _pollIntervalMillis;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly SemaphoreSlim _pollGate = new(1, 1);
    private readonly Dictionary<string, DomainState> _state = new(StringComparer.Ordinal);

    /// <summary>Raised (synchronously, inside the poll cycle) when a domain's documents change.</summary>
    public event Action<SyncDomainChangeEvent>? DomainChanged;

    /// <summary>Raised (synchronously, inside the poll cycle) when a domain's poll fails.</summary>
    public event Action<SyncDomainErrorEvent>? DomainErrored;

    public FirestoreSyncCoordinator(
        ICloudSyncGateway gateway,
        IReadOnlyList<SyncDomainDefinition> domains,
        ISyncClock? clock = null,
        SyncBackoffPolicy? backoff = null,
        TimeSpan? pollInterval = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _gateway = gateway ?? throw new ArgumentNullException(nameof(gateway));
        _domains = domains ?? throw new ArgumentNullException(nameof(domains));
        if (_domains.Count == 0)
        {
            throw new ArgumentException("At least one sync domain is required.", nameof(domains));
        }
        _clock = clock ?? SystemSyncClock.Instance;
        _backoff = backoff ?? SyncBackoffPolicy.Default;
        TimeSpan interval = pollInterval ?? TimeSpan.FromSeconds(30);
        if (interval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(pollInterval), interval, "Poll interval must be positive.");
        }
        _pollIntervalMillis = (long)interval.TotalMilliseconds;
        _delay = delay ?? ((span, ct) => Task.Delay(span, ct));

        foreach (SyncDomainDefinition domain in _domains)
        {
            _state[domain.Name] = new DomainState();
        }
    }

    /// <summary>The domains this coordinator polls.</summary>
    public IReadOnlyList<SyncDomainDefinition> Domains => _domains;

    /// <summary>The last-known document set for a domain (empty until its first successful poll).</summary>
    public IReadOnlyDictionary<string, CloudSyncFields> LastKnownState(string domain) =>
        _state.TryGetValue(domain, out DomainState? s) ? s.LastKnown : EmptyState;

    /// <summary>Consecutive failures recorded for a domain (0 after any success).</summary>
    public int ConsecutiveFailures(string domain) =>
        _state.TryGetValue(domain, out DomainState? s) ? s.ConsecutiveFailures : 0;

    /// <summary>
    /// Poll every domain once, diff against last-known state, raise change/error
    /// events, and return a summary. Deterministic and timer-free.
    /// </summary>
    public async Task<SyncCycleResult> PollOnceAsync(CancellationToken cancellationToken = default)
    {
        await _pollGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var changes = new List<SyncDomainChangeEvent>();
            var errors = new List<SyncDomainErrorEvent>();

            foreach (SyncDomainDefinition domain in _domains)
            {
                cancellationToken.ThrowIfCancellationRequested();
                DomainState state = _state[domain.Name];

                IReadOnlyList<ICloudSyncDocumentSnapshot> documents;
                try
                {
                    ICloudSyncQuerySnapshot snapshot = await domain.Query(_gateway, cancellationToken).ConfigureAwait(false);
                    documents = snapshot.Documents;
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    // Fail-closed: keep last-known state, schedule a backoff retry.
                    state.ConsecutiveFailures++;
                    long retryDelay = _backoff.DelayMillisFor(state.ConsecutiveFailures);
                    var errorEvent = new SyncDomainErrorEvent(
                        domain.Name, ex, state.ConsecutiveFailures, retryDelay, _clock.NowMillis + retryDelay);
                    errors.Add(errorEvent);
                    DomainErrored?.Invoke(errorEvent);
                    continue;
                }

                IReadOnlyList<SyncDocumentChange> domainChanges =
                    FirestoreSnapshotDiffer.Diff(state.LastKnown, documents);
                bool initial = !state.HasPolled;

                state.LastKnown = FirestoreSnapshotDiffer.ToState(documents);
                state.HasPolled = true;
                state.ConsecutiveFailures = 0;

                if (domainChanges.Count > 0 || initial)
                {
                    var changeEvent = new SyncDomainChangeEvent(domain.Name, domainChanges, documents, initial);
                    changes.Add(changeEvent);
                    DomainChanged?.Invoke(changeEvent);
                }
            }

            return new SyncCycleResult(_clock.NowMillis, changes, errors);
        }
        finally
        {
            _pollGate.Release();
        }
    }

    /// <summary>
    /// Poll continuously until <paramref name="cancellationToken"/> fires: a
    /// successful cycle waits <c>pollInterval</c>; a cycle with any failure waits the
    /// backoff for its most-failing domain. Returns when cancelled (no throw).
    /// </summary>
    public async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                SyncCycleResult result = await PollOnceAsync(cancellationToken).ConfigureAwait(false);

                long waitMillis = result.AnyFailed
                    ? _backoff.DelayMillisFor(result.MaxConsecutiveFailures)
                    : _pollIntervalMillis;

                await _delay(TimeSpan.FromMilliseconds(waitMillis), cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Normal shutdown.
        }
    }

    private static readonly IReadOnlyDictionary<string, CloudSyncFields> EmptyState =
        new Dictionary<string, CloudSyncFields>(StringComparer.Ordinal);

    private sealed class DomainState
    {
        public IReadOnlyDictionary<string, CloudSyncFields> LastKnown { get; set; } =
            new Dictionary<string, CloudSyncFields>(StringComparer.Ordinal);
        public bool HasPolled { get; set; }
        public int ConsecutiveFailures { get; set; }
    }
}

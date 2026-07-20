using System.Text.Json.Serialization;
using OpenBurnBar.CloudSync.Callable;

namespace OpenBurnBar.App.CloudSync.RuntimeSafety;

public sealed record WindowsRuntimeSafetyConfigResponse
{
    [JsonPropertyName("schemaVersion")]
    public string? SchemaVersion { get; init; }

    [JsonPropertyName("fetchedAtEpochMillis")]
    public long? FetchedAtEpochMillis { get; init; }

    [JsonPropertyName("maxAgeSeconds")]
    public int? MaxAgeSeconds { get; init; }

    [JsonPropertyName("computerUseWatchEnabled")]
    public bool? ComputerUseWatchEnabled { get; init; }

    [JsonPropertyName("computerUseBrowserEnabled")]
    public bool? ComputerUseBrowserEnabled { get; init; }

    [JsonPropertyName("computerUseSystemEnabled")]
    public bool? ComputerUseSystemEnabled { get; init; }

    [JsonPropertyName("computerUsePhoneControlEnabled")]
    public bool? ComputerUsePhoneControlEnabled { get; init; }

    [JsonPropertyName("computerUsePhoneControlAttestationRequired")]
    public bool? ComputerUsePhoneControlAttestationRequired { get; init; }

    [JsonPropertyName("computerUseTrustModesEnabled")]
    public bool? ComputerUseTrustModesEnabled { get; init; }

    [JsonPropertyName("computerUsePolishEnabled")]
    public bool? ComputerUsePolishEnabled { get; init; }

    [JsonPropertyName("computerUseKillSwitch")]
    public bool? ComputerUseKillSwitch { get; init; }

    [JsonPropertyName("computerUsePhoneControlRespectsDenyRegions")]
    public bool? ComputerUsePhoneControlRespectsDenyRegions { get; init; }

    [JsonPropertyName("mediaKillSwitch")]
    public bool? MediaKillSwitch { get; init; }
}

/// <summary>
/// Last verified fleet-safety projection. The secure default disables every
/// feature and activates both kill switches until an authenticated, App
/// Check-protected response passes schema and freshness validation.
/// </summary>
public sealed record WindowsRuntimeSafetySnapshot(
    bool IsResolved,
    DateTimeOffset FetchedAt,
    DateTimeOffset ExpiresAt,
    bool ComputerUseWatchEnabled,
    bool ComputerUseBrowserEnabled,
    bool ComputerUseSystemEnabled,
    bool ComputerUsePhoneControlEnabled,
    bool ComputerUsePhoneControlAttestationRequired,
    bool ComputerUseTrustModesEnabled,
    bool ComputerUsePolishEnabled,
    bool ComputerUseKillSwitch,
    bool ComputerUsePhoneControlRespectsDenyRegions,
    bool MediaKillSwitch)
{
    public const string ExpectedSchemaVersion = "openburnbar.windows.runtime-safety.v1";

    public static WindowsRuntimeSafetySnapshot SecureDefault(DateTimeOffset now) => new(
        IsResolved: false,
        FetchedAt: now,
        ExpiresAt: now,
        ComputerUseWatchEnabled: false,
        ComputerUseBrowserEnabled: false,
        ComputerUseSystemEnabled: false,
        ComputerUsePhoneControlEnabled: false,
        ComputerUsePhoneControlAttestationRequired: false,
        ComputerUseTrustModesEnabled: false,
        ComputerUsePolishEnabled: false,
        ComputerUseKillSwitch: true,
        ComputerUsePhoneControlRespectsDenyRegions: true,
        MediaKillSwitch: true);

    public bool IsFresh(DateTimeOffset now) => IsResolved && now <= ExpiresAt;

    public bool AllowsAnyComputerUse(DateTimeOffset now) =>
        IsFresh(now)
        && !ComputerUseKillSwitch
        && (ComputerUseWatchEnabled
            || ComputerUseBrowserEnabled
            || ComputerUseSystemEnabled
            || ComputerUsePhoneControlEnabled);

    public bool AllowsSystemComputerUse(DateTimeOffset now) =>
        IsFresh(now) && !ComputerUseKillSwitch && ComputerUseSystemEnabled;

    public static bool TryCreate(
        WindowsRuntimeSafetyConfigResponse response,
        DateTimeOffset now,
        out WindowsRuntimeSafetySnapshot snapshot)
    {
        snapshot = SecureDefault(now);
        if (!string.Equals(response.SchemaVersion, ExpectedSchemaVersion, StringComparison.Ordinal)
            || response.FetchedAtEpochMillis is not { } fetchedAtMillis
            || response.MaxAgeSeconds is not (>= 30 and <= 300)
            || response.ComputerUseWatchEnabled is not { } watch
            || response.ComputerUseBrowserEnabled is not { } browser
            || response.ComputerUseSystemEnabled is not { } system
            || response.ComputerUsePhoneControlEnabled is not { } phone
            || response.ComputerUsePhoneControlAttestationRequired is not { } phoneAttestation
            || response.ComputerUseTrustModesEnabled is not { } trustModes
            || response.ComputerUsePolishEnabled is not { } polish
            || response.ComputerUseKillSwitch is not { } computerKill
            || response.ComputerUsePhoneControlRespectsDenyRegions is not { } respectsDenyRegions
            || response.MediaKillSwitch is not { } mediaKill)
        {
            return false;
        }

        DateTimeOffset fetchedAt;
        try
        {
            fetchedAt = DateTimeOffset.FromUnixTimeMilliseconds(fetchedAtMillis);
        }
        catch (ArgumentOutOfRangeException)
        {
            return false;
        }

        DateTimeOffset expiresAt = fetchedAt.AddSeconds(response.MaxAgeSeconds.Value);
        if (fetchedAt > now.AddMinutes(5) || now > expiresAt)
        {
            return false;
        }

        snapshot = new WindowsRuntimeSafetySnapshot(
            IsResolved: true,
            FetchedAt: fetchedAt,
            ExpiresAt: expiresAt,
            ComputerUseWatchEnabled: watch,
            ComputerUseBrowserEnabled: browser,
            ComputerUseSystemEnabled: system,
            ComputerUsePhoneControlEnabled: phone,
            ComputerUsePhoneControlAttestationRequired: phoneAttestation,
            ComputerUseTrustModesEnabled: trustModes,
            ComputerUsePolishEnabled: polish,
            ComputerUseKillSwitch: computerKill,
            ComputerUsePhoneControlRespectsDenyRegions: respectsDenyRegions,
            MediaKillSwitch: mediaKill);
        return true;
    }
}

public sealed class WindowsRuntimeSafetyState
{
    private readonly object _gate = new();
    private WindowsRuntimeSafetySnapshot _current = WindowsRuntimeSafetySnapshot.SecureDefault(DateTimeOffset.UtcNow);

    public static WindowsRuntimeSafetyState Shared { get; } = new();

    public event EventHandler<WindowsRuntimeSafetySnapshot>? SnapshotChanged;

    public WindowsRuntimeSafetySnapshot Current
    {
        get
        {
            lock (_gate)
            {
                return _current;
            }
        }
    }

    public void Publish(WindowsRuntimeSafetySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        lock (_gate)
        {
            _current = snapshot;
        }
        SnapshotChanged?.Invoke(this, snapshot);
    }
}

public sealed class WindowsRuntimeSafetyConfigMonitor : IAsyncDisposable
{
    public const string FunctionName = "getWindowsRuntimeSafetyConfig";
    public static readonly TimeSpan DefaultPollInterval = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan DefaultFetchTimeout = TimeSpan.FromSeconds(15);

    private readonly Func<CancellationToken, Task<WindowsRuntimeSafetyConfigResponse>> _fetch;
    private readonly WindowsRuntimeSafetyState _state;
    private readonly TimeProvider _timeProvider;
    private readonly TimeSpan _pollInterval;
    private readonly TimeSpan _fetchTimeout;
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private readonly object _gate = new();
    private Task? _loop;
    private long _generation;

    public WindowsRuntimeSafetyConfigMonitor(
        Func<CancellationToken, Task<WindowsRuntimeSafetyConfigResponse>> fetch,
        WindowsRuntimeSafetyState? state = null,
        TimeProvider? timeProvider = null,
        TimeSpan? pollInterval = null,
        TimeSpan? fetchTimeout = null)
    {
        _fetch = fetch ?? throw new ArgumentNullException(nameof(fetch));
        _state = state ?? WindowsRuntimeSafetyState.Shared;
        _timeProvider = timeProvider ?? TimeProvider.System;
        _pollInterval = pollInterval ?? DefaultPollInterval;
        _fetchTimeout = fetchTimeout ?? DefaultFetchTimeout;
        if (_pollInterval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(pollInterval));
        if (_fetchTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(fetchTimeout));
    }

    public void Start()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_stop.IsCancellationRequested, this);
            _loop ??= Task.Run(() => RunAsync(_stop.Token));
        }
    }

    public async Task RefreshOnceAsync(CancellationToken cancellationToken = default)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            _stop.Token);
        await _refreshGate.WaitAsync(lifetime.Token).ConfigureAwait(false);
        try
        {
            long generation = Interlocked.Read(ref _generation);
            DateTimeOffset now = _timeProvider.GetUtcNow();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            timeout.CancelAfter(_fetchTimeout);
            try
            {
                WindowsRuntimeSafetyConfigResponse response = await _fetch(timeout.Token).ConfigureAwait(false);
                if (generation == Interlocked.Read(ref _generation)
                    && WindowsRuntimeSafetySnapshot.TryCreate(response, now, out WindowsRuntimeSafetySnapshot snapshot))
                {
                    _state.Publish(snapshot);
                    return;
                }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
            }
            catch (Exception)
            {
            }

            if (generation == Interlocked.Read(ref _generation))
            {
                _state.Publish(WindowsRuntimeSafetySnapshot.SecureDefault(now));
            }
        }
        finally
        {
            _refreshGate.Release();
        }
    }

    /// <summary>
    /// Immediately closes the shared state and invalidates every in-flight
    /// response. Used on sign-out so a request carrying the prior session token
    /// cannot re-authorize the process after local credentials are removed.
    /// </summary>
    public void Invalidate()
    {
        Interlocked.Increment(ref _generation);
        _state.Publish(WindowsRuntimeSafetySnapshot.SecureDefault(_timeProvider.GetUtcNow()));
    }

    public static Task<WindowsRuntimeSafetyConfigResponse> FetchFromCallableAsync(
        Func<CallableClient?> callableProvider,
        CancellationToken cancellationToken)
    {
        CallableClient callable = callableProvider()
            ?? throw new InvalidOperationException("Authenticated cloud sync is unavailable.");
        return callable.InvokeAsync<WindowsRuntimeSafetyConfigRequest, WindowsRuntimeSafetyConfigResponse>(
            FunctionName,
            new WindowsRuntimeSafetyConfigRequest(),
            cancellationToken);
    }

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        Task? loop;
        lock (_gate)
        {
            loop = _loop;
        }
        if (loop is not null)
        {
            try
            {
                await loop.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
        _stop.Dispose();
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            await RefreshOnceAsync(cancellationToken).ConfigureAwait(false);
            await Task.Delay(_pollInterval, _timeProvider, cancellationToken).ConfigureAwait(false);
        }
    }
}

public sealed record WindowsRuntimeSafetyConfigRequest;

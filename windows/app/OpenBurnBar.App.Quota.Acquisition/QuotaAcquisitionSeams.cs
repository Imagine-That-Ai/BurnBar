using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;

namespace OpenBurnBar.App.Quota.Acquisition;

// The acquisition seams every mechanism plugs into. Portable on purpose: the
// coordinator, the sources, and the tests all run on the macOS authoring host;
// only the FileSystemWatcher + %APPDATA% defaults live in the .Windows sibling.

/// <summary>
/// Injectable time for the acquisition layer (the repo's injectable-clock
/// discipline: view-models take <c>Func&lt;DateTimeOffset&gt;? now = null</c>; the
/// coordinator also awaits, so it needs a delayable clock like appcheck's
/// <c>IClock</c>).
/// </summary>
public interface IQuotaAcquisitionClock
{
    /// <summary>The current instant.</summary>
    DateTimeOffset UtcNow { get; }

    /// <summary>Awaitable delay — deterministic fakes complete it on demand.</summary>
    Task Delay(TimeSpan delay, CancellationToken cancellationToken);
}

/// <summary>Wall-clock implementation.</summary>
public sealed class SystemQuotaAcquisitionClock : IQuotaAcquisitionClock
{
    /// <summary>Shared instance.</summary>
    public static readonly SystemQuotaAcquisitionClock Instance = new();

    /// <inheritdoc />
    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;

    /// <inheritdoc />
    public Task Delay(TimeSpan delay, CancellationToken cancellationToken) =>
        Task.Delay(delay, cancellationToken);
}

/// <summary>
/// One acquisition mechanism: statusline file, Cursor state.vscdb + HTTP, Codex
/// wham/usage, Anthropic header probe. Returns <c>null</c> when the mechanism has
/// no data right now (missing file, missing credential, stale payload, auth
/// rejection) — the coordinator treats <c>null</c> as "no signal", not an error.
/// </summary>
public interface IQuotaPayloadSource
{
    /// <summary>Stable identifier the coordinator keys snapshots and change signals by.</summary>
    string SourceId { get; }

    /// <summary>Attempt one acquisition. Throwing counts as an error and is retried.</summary>
    Task<ProviderQuotaSnapshot?> TryAcquireAsync(CancellationToken cancellationToken);
}

/// <summary>
/// File-change seam (Swift peer: ClaudeStatuslineWatcher's DispatchSource). The
/// portable coordinator consumes the event; the .Windows sibling provides the
/// FileSystemWatcher implementation. Contract tests fake this seam.
/// </summary>
public interface IQuotaFileWatcher : IDisposable
{
    /// <summary>Raised (already debounced) when the watched path changes.</summary>
    event Action<string>? Changed;

    /// <summary>Begin watching. Idempotent.</summary>
    void Start();
}

/// <summary>
/// The Mac pacing constants the acquisition layer mirrors, with their sources:
/// AgentLens/Services/ProviderQuota/ClaudeStatuslineWatcher.swift,
/// ClaudeQuotaAdapter.swift (StatuslinePolicy), ProviderQuotaService.swift
/// (startAutomaticRefresh), QuotaRefreshActor.swift, CodexQuotaAdapter.swift,
/// CursorQuotaAdapter.swift.
/// </summary>
public static class QuotaAcquisitionPolicy
{
    /// <summary>ClaudeStatuslineWatcher.debounceNanoseconds = 250 ms.</summary>
    public static readonly TimeSpan ChangeDebounce = TimeSpan.FromMilliseconds(250);

    /// <summary>StatuslinePolicy.maxSnapshotAge = 15 minutes.</summary>
    public static readonly TimeSpan StatuslineMaxSnapshotAge = TimeSpan.FromMinutes(15);

    /// <summary>ProviderQuotaService.startAutomaticRefresh initialDelay = 5 minutes.</summary>
    public static readonly TimeSpan AutoRefreshInitialDelay = TimeSpan.FromMinutes(5);

    /// <summary>ProviderQuotaService.startAutomaticRefresh interval = 15 minutes.</summary>
    public static readonly TimeSpan AutoRefreshInterval = TimeSpan.FromMinutes(15);

    /// <summary>QuotaRefreshActor.maxConcurrentQuotaFetches = 4.</summary>
    public const int MaxConcurrentFetches = 4;

    /// <summary>CodexQuotaAdapter.authRefreshGrace = 8 days.</summary>
    public static readonly TimeSpan CodexAuthRefreshGrace = TimeSpan.FromDays(8);

    /// <summary>CursorQuotaAdapter request timeout = 15 s.</summary>
    public static readonly TimeSpan HttpTimeout = TimeSpan.FromSeconds(15);
}

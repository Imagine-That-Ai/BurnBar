using System;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.SharedUi;

// MARK: - Backing planes
//
// The dispatcher is transport- and platform-agnostic. The WinUI app supplies
// REAL implementations of these seams (over WindowsStorageDevHost, the
// SqlCipher session-log read source, ElderWand gateway routes, the quota
// acquisition host, LocalHttpGatewayHost, WindowsUpdateService, and process
// actions); the tests supply fakes. A null plane means the corresponding
// command group answers "not implemented on Windows" — the frontend's
// isCapabilityAbsentError maps that to the graceful-degrade path, identical to
// the Linux shell when the daemon lacks a capability.

/// <summary>
/// Read-side data plane. Every method returns RAW, daemon-shaped JSON exactly
/// as the frontend mappers in apps/linux-desktop/src/tauriBridge.ts expect
/// (they are deliberately tolerant pick() readers; keep the emitted key names
/// on the canonical daemon casing: providerId/modelId/costUsd/recordedAt...).
/// </summary>
public interface ISharedUiDataPlane
{
    /// <summary>{ usage: [ BurnBarUsageEvent... ] } — the daemon.usage.recent shape.</summary>
    Task<JsonObject> GetRecentUsageAsync(int limit, CancellationToken ct);

    /// <summary>{ sessions: [...], nextCursor: string|null } — real session-log rows.</summary>
    Task<JsonObject> ListSessionsAsync(int limit, CancellationToken ct);

    /// <summary>{ sessions: [...], nextCursor: string|null } — FTS search results.</summary>
    Task<JsonObject> SearchSessionsAsync(string query, CancellationToken ct);

    /// <summary>daemon.config.get-shaped snapshot (paths, telemetry/privacy/cloudSync, providers[], routerMode).</summary>
    Task<JsonObject> GetConfigSnapshotAsync(CancellationToken ct);

    /// <summary>{ providers: [ { id, label, accountLabel, quotaBuckets: [...] } ] }.</summary>
    Task<JsonObject> GetProviderCatalogAsync(CancellationToken ct);

    /// <summary>
    /// Apply the settings-surface snapshot mutation. The Windows v1 contract
    /// persists the privacy/telemetry/cloudSync booleans only; provider
    /// sub-objects round-trip unchanged (provider edits use the dedicated
    /// provider_* commands). Returns the fresh config snapshot.
    /// </summary>
    Task<JsonObject> ApplyConfigUpdateAsync(JsonObject snapshot, CancellationToken ct);

    /// <summary>{ sqlcipherOk, migrationVersion, sizeBytes, walMode }.</summary>
    Task<JsonObject> GetDatabaseStatusAsync(CancellationToken ct);

    /// <summary>
    /// { state, signedIn, identityLabel?, syncState?, cloudSyncEnabled } — the
    /// fields live at the TOP LEVEL because the renderer's mapAccountStatus
    /// (tauriBridgeSystemDecoders.ts) reads them there (or under a top-level
    /// `status` object); nesting them under `cloud` decodes as signed out.
    /// </summary>
    Task<JsonObject> GetAccountStatusAsync(CancellationToken ct);

    /// <summary>
    /// LinuxUpdateStatus shape: { state: current|available|unavailable|invalid,
    /// currentVersion, latestVersion?, channel?, publishedAt?, notes?, reason? }.
    /// NEVER emit `artifact` — the frontend validates artifact metadata against
    /// the Linux package enums (appimage/deb/rpm/daemon + aarch64/x86_64) and
    /// would throw on a Windows artifact descriptor.
    /// </summary>
    Task<JsonObject> GetUpdateStatusAsync(CancellationToken ct);

    /// <summary>{ shellVersion, daemonVersion, packageChannel }.</summary>
    Task<JsonObject> GetAppVersionInfoAsync(CancellationToken ct);

    /// <summary>{ entries: [ ProxyRouteLogEntry... ] } — model-proxy route telemetry.</summary>
    Task<JsonObject> GetProxyRouteLogAsync(int limit, CancellationToken ct);

    /// <summary>{ cleared: bool }.</summary>
    Task<JsonObject> ClearProxyRouteLogAsync(CancellationToken ct);

    /// <summary>
    /// The never-reject 4-report bundle: { indexStatus, explore, diagnostics,
    /// opsDiagnostics }, each { ok: bool, result|error }. Windows v1 reports
    /// honest per-report "not implemented on Windows" errors.
    /// </summary>
    Task<JsonObject> GetDatabaseWorkspaceStatusAsync(string? projectPath, CancellationToken ct);
}

/// <summary>
/// The local OpenAI-compatible chat gateway (LocalHttpGatewayHost on Windows,
/// loopback only). Implementations throw <see cref="SharedUiCommandException"/>
/// with the gateway_* error taxonomy (mirroring apps/linux-desktop/src-tauri/
/// src/lib.rs) so the frontend's nativeGatewayError mapper renders the right copy.
/// </summary>
public interface ISharedUiGatewayPlane
{
    /// <summary>True when the loopback gateway answers /health with the configured bearer.</summary>
    Task<bool> ProbeAsync(CancellationToken ct);

    /// <summary>
    /// Stream one chat completion. Raw SSE text chunks are forwarded via
    /// <paramref name="onChunk"/> (UTF-8 boundary-safe, never mid-codepoint);
    /// returning normally ends the stream. Throws SharedUiCommandException with
    /// gateway_aborted/gateway_http:.../gateway_stream_interrupted:... etc.
    /// </summary>
    Task StreamChatAsync(JsonObject request, Func<string, CancellationToken, Task> onChunk, CancellationToken ct);

    /// <summary>Cancel an in-flight stream by requestId (gateway_chat_cancel).</summary>
    void CancelChat(string requestId);
}

/// <summary>Process/OS actions the shell can request.</summary>
public interface ISharedUiSystemPlane
{
    /// <summary>tray_degraded — true when the tray/backend plane is in a degraded state.</summary>
    bool TrayDegraded { get; }

    /// <summary>open_dashboard — show/focus the main shell window.</summary>
    void OpenDashboard();

    /// <summary>quit_app — begin graceful process shutdown.</summary>
    void Quit();

    /// <summary>Open an already-validated Stripe checkout/billing URL in the system browser.</summary>
    void OpenExternalUrl(string validatedUrl);

    /// <summary>Open an already-validated update download URL in the system browser.</summary>
    void OpenUpdateUrl(string validatedUrl);

    /// <summary>Write a redacted diagnostics bundle; returns the file path.</summary>
    string ExportDiagnostics();
}

/// <summary>
/// Live capability probes used to synthesize the runtime_capability manifest.
/// Filled by the app at composition time (and refreshed per invoke — it is a
/// value snapshot, cheap to rebuild).
/// </summary>
public sealed record SharedUiCapabilityStatus
{
    /// <summary>Local SQLCipher store provisioned and readable.</summary>
    public bool StorageReady { get; init; }

    /// <summary>Session-log read source available (FTS over the shared index).</summary>
    public bool SessionLogsReady { get; init; }

    /// <summary>The in-process loopback chat gateway is running.</summary>
    public bool GatewayRunning { get; init; }

    /// <summary>The loopback gateway port when running (for daemon_health display).</summary>
    public int? GatewayPort { get; init; }

    /// <summary>Signed-in cloud identity present (DesktopOAuthCredentialsProvider).</summary>
    public bool CloudSignedIn { get; init; }

    /// <summary>Shell tray icon installed.</summary>
    public bool TrayReady { get; init; } = true;

    /// <summary>OS notification plane available.</summary>
    public bool NotificationsReady { get; init; } = true;

    /// <summary>Updater feed configured (WinSparkle/appcast).</summary>
    public bool UpdatesConfigured { get; init; } = true;
}

/// <summary>Dispatcher composition.</summary>
public sealed record SharedUiDispatcherOptions
{
    /// <summary>Shell version string reported in the manifest + app_version_info fallback.</summary>
    public required string ShellVersion { get; init; }

    public ISharedUiDataPlane? Data { get; init; }

    public ISharedUiGatewayPlane? Gateway { get; init; }

    public ISharedUiSystemPlane? System { get; init; }

    /// <summary>Live probe snapshot for the capability manifest. Re-read per invoke.</summary>
    public Func<SharedUiCapabilityStatus>? CapabilityStatus { get; init; }

    /// <summary>Optional persistent store for onboarding privacy choices (settings.json on Windows).</summary>
    public ISharedUiOnboardingStateStore? OnboardingStore { get; init; }
}

/// <summary>Persistence seam for the onboarding privacy choices + revision.</summary>
public interface ISharedUiOnboardingStateStore
{
    (bool TelemetryEnabled, bool CloudSyncEnabled, int Revision) Load();

    void Save(bool telemetryEnabled, bool cloudSyncEnabled, int revision);
}

/// <summary>
/// A command failure whose message is delivered verbatim as the invoke-result
/// error string. Use for taxonomy-pinned errors (gateway_*, external_url_*,
/// "not implemented on Windows", validation failures) — the frontend maps
/// specific substrings to UX, so messages here are a contract.
/// </summary>
public sealed class SharedUiCommandException : Exception
{
    public SharedUiCommandException(string wireError)
        : base(wireError)
    {
    }
}

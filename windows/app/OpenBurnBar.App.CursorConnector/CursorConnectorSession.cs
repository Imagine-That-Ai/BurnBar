using System;

namespace OpenBurnBar.App.CursorConnector;

// ── Session state machine ────────────────────────────────────────────────────
//
// Faithful Windows peer of the connect()/disconnect() orchestration in
// CursorConnectorManager. The Mac runs a fixed, ordered sequence of side-effecting
// steps and — critically — on ANY failure tears the half-built session back down
// (stop broker, stop tunnel, stop proxy) and rolls the user's Cursor editor
// settings back to their pre-connect snapshot, surfacing (never swallowing) a
// failed rollback. The individual steps (spawning python3/cloudflared, binding the
// broker listener, reading state.vscdb) are the deferred .Windows half; this
// portable core owns the STATE MACHINE — the exact step ordering, the terminal
// status/lastError strings, and the rollback contract — behind
// IConnectorSessionSteps so the ordering and rollback are provable with a fake.

/// <summary>The connector session lifecycle state.</summary>
public enum ConnectorSessionState
{
    /// <summary>Never connected (or reset).</summary>
    Idle,

    /// <summary>A connect attempt is in flight.</summary>
    Connecting,

    /// <summary>Connected and verified.</summary>
    Connected,

    /// <summary>A connect attempt failed and was rolled back.</summary>
    Failed,

    /// <summary>Cleanly disconnected.</summary>
    Disconnected,
}

/// <summary>
/// The ordered, side-effecting steps of a connect/disconnect. The runtime
/// (.Windows) implements these against real processes/sockets/state.vscdb; tests
/// implement a recording fake to assert ordering + rollback.
/// </summary>
public interface IConnectorSessionSteps
{
    /// <summary>Validates enabled providers, exposed models, and per-provider keys.</summary>
    void ValidateConfiguration();

    /// <summary>Ensures the private support directory exists.</summary>
    void EnsureSupportDirectory();

    /// <summary>Refreshes cloudflared/package-manager health.</summary>
    void RefreshSystemHealth();

    /// <summary>Generates the fresh per-session tunnel rotation token.</summary>
    void GenerateRotationToken();

    /// <summary>Starts the loopback secret broker.</summary>
    void StartSecretBroker();

    /// <summary>Writes the proxy script.</summary>
    void WriteProxyScript();

    /// <summary>Writes the proxy config (routes, tokens, broker URL).</summary>
    void WriteProxyConfig();

    /// <summary>Starts the local proxy.</summary>
    void StartProxy();

    /// <summary>Starts the tunnel and captures its public URL.</summary>
    void StartTunnel();

    /// <summary>Snapshots and rewrites Cursor's editor settings to the gateway.</summary>
    void ApplyCursorSettings();

    /// <summary>Verifies the public endpoint enforces auth and exposes the models.</summary>
    void VerifyPublicEndpoint();

    /// <summary>Stops the secret broker.</summary>
    void StopSecretBroker();

    /// <summary>Stops the proxy.</summary>
    void StopProxy();

    /// <summary>Stops the tunnel.</summary>
    void StopTunnel();

    /// <summary>Restores Cursor's pre-connect editor settings from the snapshot.</summary>
    void RestoreCursorSettings();
}

/// <summary>Drives the connector connect/disconnect state machine.</summary>
public sealed class CursorConnectorSession
{
    private readonly IConnectorSessionSteps _steps;
    private readonly CursorConnectorConfig _config;
    private readonly ConnectorHealthSnapshot _health;
    private readonly IConnectorClock _clock;

    /// <summary>Creates a session over the given steps, config, and health.</summary>
    public CursorConnectorSession(
        IConnectorSessionSteps steps,
        CursorConnectorConfig config,
        ConnectorHealthSnapshot health,
        IConnectorClock? clock = null)
    {
        _steps = steps ?? throw new ArgumentNullException(nameof(steps));
        _config = config ?? throw new ArgumentNullException(nameof(config));
        _health = health ?? throw new ArgumentNullException(nameof(health));
        _clock = clock ?? SystemConnectorClock.Instance;
    }

    /// <summary>The current lifecycle state.</summary>
    public ConnectorSessionState State { get; private set; } = ConnectorSessionState.Idle;

    /// <summary>The last user-facing error, or <c>null</c>.</summary>
    public string? LastError { get; private set; }

    /// <summary>Swift <c>connect()</c> — the ordered build with full rollback on failure.</summary>
    public ConnectorSessionState Connect()
    {
        State = ConnectorSessionState.Connecting;
        LastError = null;

        try
        {
            _steps.ValidateConfiguration();
            _steps.EnsureSupportDirectory();
            _steps.RefreshSystemHealth();
            _steps.GenerateRotationToken();
            _steps.StartSecretBroker();
            _steps.WriteProxyScript();
            _steps.WriteProxyConfig();
            _steps.StartProxy();
            _steps.StartTunnel();
            _steps.ApplyCursorSettings();
            _steps.VerifyPublicEndpoint();

            _config.IsEnabled = true;
            _config.LastAppliedAt = _clock.UtcNow;
            _config.StatusMessage = "Connected to Cursor";
            State = ConnectorSessionState.Connected;
            return State;
        }
        catch (Exception error)
        {
            RollBackAfterFailedConnect(error);
            State = ConnectorSessionState.Failed;
            return State;
        }
    }

    private void RollBackAfterFailedConnect(Exception error)
    {
        // Swift teardown order: broker, tunnel, proxy — then restore Cursor settings.
        _steps.StopSecretBroker();
        _steps.StopTunnel();
        _steps.StopProxy();

        try
        {
            _steps.RestoreCursorSettings();
            _config.StatusMessage = "Connection failed";
            LastError = error.Message;
        }
        catch (Exception restoreError)
        {
            // A failed rollback leaves Cursor pointing at the now-dead endpoint —
            // surface it (never swallow), exactly as the Mac does.
            _config.StatusMessage = "Connection failed (Cursor settings may need a manual reset)";
            LastError = $"{error.Message} — and Cursor settings could not be rolled back: {restoreError.Message}";
        }
    }

    /// <summary>Swift <c>disconnect()</c> — stop everything and restore, clearing tunnel state.</summary>
    public ConnectorSessionState Disconnect()
    {
        try
        {
            _steps.StopTunnel();
            _steps.StopProxy();
            _steps.StopSecretBroker();
            _steps.RestoreCursorSettings();

            _config.IsEnabled = false;
            _config.Tunnel.PublicBaseURL = null;
            _config.Tunnel.StatusMessage = "Disconnected";
            _health.PublicBaseURLReachable = false;
            _config.StatusMessage = "Disconnected";
            State = ConnectorSessionState.Disconnected;
        }
        catch (Exception error)
        {
            LastError = error.Message;
        }

        return State;
    }
}

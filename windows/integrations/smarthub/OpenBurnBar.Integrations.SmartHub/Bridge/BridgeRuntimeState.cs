using System;

namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// The bridge's observable runtime state + version-bump state machine.
//
// Parity: AgentLens/Services/SmartHub/SmartHubBridgeServer.swift
//   refreshVersion / lastRefreshedAt / isRefreshing / timePeriod / snapshot /
//   displayConfig / lastClientPollAt / bridgeAccessToken +
//   updateTimePeriod / updateDisplayConfig / updateSnapshot / bumpRefresh /
//   setRefreshing.
//
// Every mutation that changes what a Nest Hub should render bumps the wrapping
// version counter and stamps lastRefreshedAt, so a polling client sees the
// transition on its next /state.json read. The clock is injectable for
// deterministic tests. This is the pure state half of the server; the socket
// lives in the Net adapter.

public sealed class BridgeRuntimeState
{
    private readonly Func<DateTimeOffset> _now;

    public ulong RefreshVersion { get; private set; }
    public DateTimeOffset LastRefreshedAt { get; private set; }
    public bool IsRefreshing { get; private set; }
    public SmartHubTimePeriod TimePeriod { get; private set; }
    public SmartHubBridgeSnapshot Snapshot { get; private set; }
    public SmartHubDisplayConfig DisplayConfig { get; private set; }

    /// Wall-clock of the last /state.json poll; distant-past until the first.
    /// The cast watchdog uses this to tell "actively rendering" from "stuck".
    public DateTimeOffset LastClientPollAt { get; private set; }

    public string BridgeAccessToken { get; private set; }

    public BridgeRuntimeState(Func<DateTimeOffset>? now = null, string? bridgeAccessToken = null)
    {
        _now = now ?? (() => DateTimeOffset.UtcNow);
        RefreshVersion = 0;
        LastRefreshedAt = _now();
        IsRefreshing = false;
        TimePeriod = SmartHubTimePeriod.Rolling5h;
        Snapshot = SmartHubBridgeSnapshot.Empty;
        DisplayConfig = SmartHubDisplayConfig.Default;
        LastClientPollAt = DateTimeOffset.MinValue;
        BridgeAccessToken = bridgeAccessToken ?? BridgeAccessControl.MakeBridgeAccessToken();
    }

    /// Parity: Swift `updateTimePeriod(_:)` — no-op when unchanged.
    public void UpdateTimePeriod(SmartHubTimePeriod period)
    {
        if (period == TimePeriod)
        {
            return;
        }
        TimePeriod = period;
        BumpVersion();
    }

    /// Parity: Swift `updateDisplayConfig(_:)` — no-op when unchanged.
    public void UpdateDisplayConfig(SmartHubDisplayConfig config)
    {
        if (config.Equals(DisplayConfig))
        {
            return;
        }
        DisplayConfig = config;
        BumpVersion();
    }

    /// Parity: Swift `updateSnapshot(_:)`.
    public void UpdateSnapshot(SmartHubBridgeSnapshot snapshot)
    {
        Snapshot = snapshot;
        BumpVersion();
    }

    /// Parity: Swift `bumpRefresh()`.
    public void BumpRefresh() => BumpVersion();

    /// Parity: Swift `setRefreshing(_:)` — no-op when unchanged; otherwise bumps.
    public void SetRefreshing(bool refreshing)
    {
        if (refreshing == IsRefreshing)
        {
            return;
        }
        IsRefreshing = refreshing;
        BumpVersion();
    }

    /// Parity: Swift `lastClientPollAt = Date()` on each /state.json GET.
    public void RecordClientPoll() => LastClientPollAt = _now();

    /// Parity: Swift `start()` mints a fresh token per session.
    public void RegenerateToken() => BridgeAccessToken = BridgeAccessControl.MakeBridgeAccessToken();

    private void BumpVersion()
    {
        // Parity: Swift `refreshVersion &+= 1` (wrapping add).
        RefreshVersion = unchecked(RefreshVersion + 1);
        LastRefreshedAt = _now();
    }

    /// Renders the current /state.json contract for this state.
    public string RenderStateJson() =>
        BridgeStateJson.Render(RefreshVersion, LastRefreshedAt, IsRefreshing, TimePeriod, Snapshot, DisplayConfig);
}

// Triple kill-switch (R17 / G4): each of the three panic paths engages independently, and
// the switch is fail-closed on a Remote Config read error and on a stale/absent watchdog
// heartbeat.

using System;
using OpenBurnBar.Pal.Input;
using Xunit;

namespace OpenBurnBar.Pal.Input.Tests;

public sealed class InputKillSwitchTests
{
    private static readonly DateTimeOffset Now = InputTestClock.Now;
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    private static InputKillSwitchInputs Inputs(
        bool rcHalt = false,
        bool rcReadFailed = false,
        bool localHalt = false,
        DateTimeOffset? heartbeat = null)
    {
        return new InputKillSwitchInputs(rcHalt, rcReadFailed, localHalt, heartbeat, Timeout);
    }

    [Fact]
    public void Fresh_heartbeat_and_no_halt_is_open()
    {
        var state = InputKillSwitchState.Evaluate(Inputs(heartbeat: Now.AddSeconds(-1)), Now);
        Assert.False(state.IsEngaged);
        Assert.Empty(state.EngagedSources);
    }

    [Fact]
    public void Remote_config_halt_engages()
    {
        var state = InputKillSwitchState.Evaluate(Inputs(rcHalt: true, heartbeat: Now), Now);
        Assert.True(state.IsEngaged);
        Assert.Contains(InputKillSwitchSource.RemoteConfigHalt, state.EngagedSources);
    }

    [Fact]
    public void Signed_local_channel_halt_engages_independently_of_remote_config()
    {
        var state = InputKillSwitchState.Evaluate(Inputs(localHalt: true, heartbeat: Now), Now);
        Assert.True(state.IsEngaged);
        Assert.Contains(InputKillSwitchSource.SignedLocalChannelHalt, state.EngagedSources);
    }

    [Fact]
    public void Remote_config_read_failure_fails_closed()
    {
        var state = InputKillSwitchState.Evaluate(Inputs(rcReadFailed: true, heartbeat: Now), Now);
        Assert.True(state.IsEngaged);
        Assert.Contains(InputKillSwitchSource.RemoteConfigReadFailed, state.EngagedSources);
    }

    [Fact]
    public void Stale_watchdog_heartbeat_fails_closed()
    {
        var state = InputKillSwitchState.Evaluate(Inputs(heartbeat: Now.AddSeconds(-10)), Now);
        Assert.True(state.IsEngaged);
        Assert.Contains(InputKillSwitchSource.WatchdogHeartbeatStale, state.EngagedSources);
    }

    [Fact]
    public void Absent_watchdog_heartbeat_fails_closed()
    {
        var state = InputKillSwitchState.Evaluate(Inputs(heartbeat: null), Now);
        Assert.True(state.IsEngaged);
        Assert.Contains(InputKillSwitchSource.WatchdogHeartbeatStale, state.EngagedSources);
    }

    [Fact]
    public void All_three_panic_paths_can_engage_at_once()
    {
        var state = InputKillSwitchState.Evaluate(
            Inputs(rcHalt: true, localHalt: true, heartbeat: Now.AddSeconds(-30)), Now);
        Assert.True(state.IsEngaged);
        Assert.Contains(InputKillSwitchSource.RemoteConfigHalt, state.EngagedSources);
        Assert.Contains(InputKillSwitchSource.SignedLocalChannelHalt, state.EngagedSources);
        Assert.Contains(InputKillSwitchSource.WatchdogHeartbeatStale, state.EngagedSources);
    }

    [Fact]
    public void Static_and_open_helpers_behave()
    {
        Assert.True(StaticInputKillSwitch.Engaged.IsEngaged);
        Assert.False(StaticInputKillSwitch.Open.IsEngaged);
        Assert.False(InputKillSwitchState.Open.IsEngaged);
    }
}

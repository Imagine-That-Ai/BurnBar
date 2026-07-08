// Triple kill-switch for the privileged input path (R17 / master plan §9.5, G4).
//
// The macOS app carries a single leaf-reaching PrivilegedInputKillSwitch flag file. The
// Windows port preserves this as a SEPARATE watchdog process with THREE independent panic
// paths (G4: "kill-switch halts mid-action within a stated bound across all three panic
// paths"):
//
//   1. Remote Config halt   — the attestation-gated `computer_use_kill_switch` flag.
//   2. Signed local channel  — a signed local kill message, independent of Remote Config
//                              (so an App-Check-undeliverable RC cannot strand the kill).
//   3. Watchdog heartbeat    — a separate watchdog process; a stale/missed heartbeat halts.
//
// FAIL-CLOSED-ON-RC-ERROR (R17): if the Remote Config value cannot be read, the switch is
// ENGAGED, not open. The gate additionally treats any exception while reading the switch as
// engaged (belt-and-suspenders), so a throwing source can never open the path.

using System;
using System.Collections.Generic;

namespace OpenBurnBar.Pal.Input;

/// <summary>The kill-switch the input gate consults before every dispatch.</summary>
public interface IInputKillSwitch
{
    /// <summary>True when input synthesis must stop. Implementations must be fail-closed:
    /// any ambiguity resolves to engaged.</summary>
    bool IsEngaged { get; }
}

/// <summary>Which panic path engaged the kill switch (for the audit record).</summary>
public enum InputKillSwitchSource
{
    RemoteConfigHalt,
    RemoteConfigReadFailed,
    SignedLocalChannelHalt,
    WatchdogHeartbeatStale,
}

/// <summary>Raw inputs to a kill-switch evaluation.</summary>
public sealed class InputKillSwitchInputs
{
    public InputKillSwitchInputs(
        bool remoteConfigHalt,
        bool remoteConfigReadFailed,
        bool signedLocalChannelHalt,
        DateTimeOffset? lastWatchdogHeartbeat,
        TimeSpan watchdogHeartbeatTimeout)
    {
        RemoteConfigHalt = remoteConfigHalt;
        RemoteConfigReadFailed = remoteConfigReadFailed;
        SignedLocalChannelHalt = signedLocalChannelHalt;
        LastWatchdogHeartbeat = lastWatchdogHeartbeat;
        WatchdogHeartbeatTimeout = watchdogHeartbeatTimeout;
    }

    public bool RemoteConfigHalt { get; }
    public bool RemoteConfigReadFailed { get; }
    public bool SignedLocalChannelHalt { get; }
    public DateTimeOffset? LastWatchdogHeartbeat { get; }
    public TimeSpan WatchdogHeartbeatTimeout { get; }
}

/// <summary>
/// Immutable evaluated kill-switch state. Engaged if ANY panic path fired OR the Remote
/// Config read failed (fail-closed) OR the watchdog heartbeat is stale/absent.
/// </summary>
public sealed class InputKillSwitchState : IInputKillSwitch
{
    private readonly IReadOnlyList<InputKillSwitchSource> _engagedSources;

    private InputKillSwitchState(IReadOnlyList<InputKillSwitchSource> engagedSources)
    {
        _engagedSources = engagedSources;
    }

    public bool IsEngaged => _engagedSources.Count > 0;

    /// <summary>The panic paths that are currently engaged (empty when open).</summary>
    public IReadOnlyList<InputKillSwitchSource> EngagedSources => _engagedSources;

    /// <summary>An open (not engaged) state.</summary>
    public static InputKillSwitchState Open { get; } = new(Array.Empty<InputKillSwitchSource>());

    /// <summary>Evaluate the three panic paths against raw inputs at <paramref name="now"/>.
    /// A null last-heartbeat is treated as stale (fail-closed): a watchdog that never
    /// reported cannot vouch that the path is safe.</summary>
    public static InputKillSwitchState Evaluate(InputKillSwitchInputs inputs, DateTimeOffset now)
    {
        if (inputs is null)
        {
            throw new ArgumentNullException(nameof(inputs));
        }

        var engaged = new List<InputKillSwitchSource>(4);
        if (inputs.RemoteConfigHalt)
        {
            engaged.Add(InputKillSwitchSource.RemoteConfigHalt);
        }
        if (inputs.RemoteConfigReadFailed)
        {
            engaged.Add(InputKillSwitchSource.RemoteConfigReadFailed);
        }
        if (inputs.SignedLocalChannelHalt)
        {
            engaged.Add(InputKillSwitchSource.SignedLocalChannelHalt);
        }
        var heartbeatStale = inputs.LastWatchdogHeartbeat is null
            || (now - inputs.LastWatchdogHeartbeat.Value) > inputs.WatchdogHeartbeatTimeout;
        if (heartbeatStale)
        {
            engaged.Add(InputKillSwitchSource.WatchdogHeartbeatStale);
        }
        return new InputKillSwitchState(engaged);
    }
}

/// <summary>A constant kill switch for tests / simple wiring.</summary>
public sealed class StaticInputKillSwitch : IInputKillSwitch
{
    public StaticInputKillSwitch(bool engaged) => IsEngaged = engaged;

    public bool IsEngaged { get; }

    public static StaticInputKillSwitch Open { get; } = new(false);
    public static StaticInputKillSwitch Engaged { get; } = new(true);
}

/// <summary>A kill switch that reads a delegate on each access. Used to bind a live
/// watchdog/RC source. If the delegate throws, the consuming gate treats it as engaged
/// (fail-closed) — this type does not swallow the exception itself so misconfiguration
/// stays visible in tests.</summary>
public sealed class DelegatingInputKillSwitch : IInputKillSwitch
{
    private readonly Func<bool> _engaged;

    public DelegatingInputKillSwitch(Func<bool> engaged) =>
        _engaged = engaged ?? throw new ArgumentNullException(nameof(engaged));

    public bool IsEngaged => _engaged();
}

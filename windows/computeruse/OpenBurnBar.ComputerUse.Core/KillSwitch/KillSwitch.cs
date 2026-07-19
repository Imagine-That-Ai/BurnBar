// Triple-independent kill-switch state machine + durable leaf-reaching flag.
//
// Ports the SECURITY INVARIANT of ComputerUsePanicHaltCoordinator.swift (Mac
// glue) + PrivilegedInputKillSwitch.swift (daemon flag), carried verbatim per
// master plan R17 ("Preserve the triple kill-switch … carrying fail-closed-on-
// RC-error"):
//
//   * THREE independent kill paths — a global panic hotkey (WH_KEYBOARD_LL on
//     Windows), a workspace/secure-desktop lock (WTS session / LogonUI / UAC),
//     and a Remote-Config flag flip — plus a UIA-trust revocation poll, all
//     CONVERGE on a single halt carrying the originating PanicSource. Any one
//     path halts the whole session; no path can be disarmed by another.
//   * FAIL-CLOSED-ON-RC-ERROR: a Remote-Config fetch/parse error is treated as
//     the kill switch being ACTIVE, never as "assume off".
//   * A DURABLE flag (IKillSwitchFlag) that every input leaf re-checks on each
//     dispatch, so synthesis stops even if the app process crashes after a
//     panic (the watchdog process — see Watchdog/ — sets the same flag when the
//     app cannot).
//
// Halt bound: a panic signal sets the durable flag SYNCHRONOUSLY inside the
// signalling call, so ShouldBlockDispatch() returns true on the very next
// dispatch check — no action dispatches after a panic source is observed
// (bound = one dispatch-check, zero additional synthesized actions).

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using OpenBurnBar.ComputerUse.Core.Gate;

namespace OpenBurnBar.ComputerUse.Core.KillSwitch;

/// <summary>
/// The durable, leaf-reaching kill flag. Presence means "stop synthesizing
/// input NOW"; every privileged leaf checks it on every dispatch. The watchdog
/// process sets it independently of the app.
/// </summary>
public interface IKillSwitchFlag
{
    /// <summary>True iff the flag is set — input synthesis must stop.</summary>
    bool IsActive { get; }

    /// <summary>Sets the flag with an optional reason string.</summary>
    void Activate(string? reason = null);

    /// <summary>Clears the flag (a fresh, operator-initiated session start).</summary>
    void Clear();
}

/// <summary>In-memory flag for tests and single-process coordinators.</summary>
public sealed class InMemoryKillSwitchFlag : IKillSwitchFlag
{
    private readonly object _gate = new();
    private bool _active;

    public bool IsActive
    {
        get
        {
            lock (_gate)
            {
                return _active;
            }
        }
    }

    public string? Reason { get; private set; }

    public void Activate(string? reason = null)
    {
        lock (_gate)
        {
            _active = true;
            Reason = reason ?? "panic";
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            _active = false;
            Reason = null;
        }
    }
}

/// <summary>
/// File-backed flag. Presence of the file = active; the file body carries the
/// reason. This is the cross-process contract the watchdog and every leaf share
/// (the Windows analog of /var/run/openburnbar-privileged-input-kill).
/// </summary>
public sealed class FileKillSwitchFlag : IKillSwitchFlag
{
    private readonly string _path;

    public FileKillSwitchFlag(string path)
    {
        _path = path ?? throw new ArgumentNullException(nameof(path));
    }

    public bool IsActive => File.Exists(_path);

    public void Activate(string? reason = null)
    {
        var directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var temp = _path + ".tmp";
        File.WriteAllText(temp, reason ?? "panic");
        if (File.Exists(_path))
        {
            File.Replace(temp, _path, destinationBackupFileName: null);
        }
        else
        {
            File.Move(temp, _path);
        }
    }

    public void Clear()
    {
        if (File.Exists(_path))
        {
            File.Delete(_path);
        }
    }

    /// <summary>
    /// Atomically creates the flag only when no owner already holds it. This is
    /// used for startup interlocks so an unresolved remote-config marker cannot
    /// overwrite the reason from an earlier manual or watchdog panic.
    /// </summary>
    public bool TryActivateIfInactive(string reason)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(reason);
        var directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        try
        {
            using var stream = new FileStream(_path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            using var writer = new StreamWriter(stream);
            writer.Write(reason);
            return true;
        }
        catch (IOException) when (File.Exists(_path))
        {
            return false;
        }
    }
}

/// <summary>
/// A writable primary kill flag combined with independent read-only interlocks.
/// Activate/Clear only mutate the primary panic latch; every dispatch observes
/// all layers, and an unreadable layer fails closed.
/// </summary>
public sealed class LayeredKillSwitchFlag : IKillSwitchFlag
{
    private readonly IKillSwitchFlag _primary;
    private readonly IReadOnlyList<IKillSwitchFlag> _interlocks;

    public LayeredKillSwitchFlag(IKillSwitchFlag primary, params IKillSwitchFlag[] interlocks)
    {
        _primary = primary ?? throw new ArgumentNullException(nameof(primary));
        _interlocks = interlocks?.ToArray() ?? throw new ArgumentNullException(nameof(interlocks));
        if (_interlocks.Any(static flag => flag is null))
        {
            throw new ArgumentException("Interlock flags cannot contain null.", nameof(interlocks));
        }
    }

    public bool IsActive
    {
        get
        {
            try
            {
                return _primary.IsActive || _interlocks.Any(static flag => flag.IsActive);
            }
            catch (Exception)
            {
                return true;
            }
        }
    }

    public void Activate(string? reason = null) => _primary.Activate(reason);

    public void Clear() => _primary.Clear();
}

/// <summary>
/// Cross-process remote-safety lease. Missing, malformed, explicitly blocked,
/// or expired content all mean active. Only a fresh authenticated config poll
/// may write an allow lease, so a crashed app automatically re-closes the
/// privileged broker without relying on process-lifetime coupling.
/// </summary>
public sealed class RemoteSafetyLeaseKillSwitchFlag : IKillSwitchFlag
{
    private const string AllowPrefix = "openburnbar-remote-safety-v1:allow-until:";
    private const string BlockPrefix = "openburnbar-remote-safety-v1:blocked:";

    private readonly string _path;
    private readonly TimeProvider _timeProvider;

    public RemoteSafetyLeaseKillSwitchFlag(string path, TimeProvider? timeProvider = null)
    {
        _path = path ?? throw new ArgumentNullException(nameof(path));
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public bool IsActive
    {
        get
        {
            try
            {
                if (!File.Exists(_path)) return true;
                string value = File.ReadAllText(_path).Trim();
                if (!value.StartsWith(AllowPrefix, StringComparison.Ordinal)
                    || !long.TryParse(
                        value.AsSpan(AllowPrefix.Length),
                        NumberStyles.None,
                        CultureInfo.InvariantCulture,
                        out long expiresAtMillis))
                {
                    return true;
                }
                return _timeProvider.GetUtcNow().ToUnixTimeMilliseconds() >= expiresAtMillis;
            }
            catch (Exception)
            {
                return true;
            }
        }
    }

    public void Activate(string? reason = null) => Write(BlockPrefix + NormalizeReason(reason));

    /// <summary>A generic clear cannot authorize execution without a bounded lease.</summary>
    public void Clear() => Activate("clear_requires_authenticated_lease");

    public void AuthorizeUntil(DateTimeOffset expiresAt)
    {
        DateTimeOffset now = _timeProvider.GetUtcNow();
        if (expiresAt <= now || expiresAt > now.AddMinutes(5))
        {
            throw new ArgumentOutOfRangeException(nameof(expiresAt), "Remote safety leases must expire within five minutes.");
        }
        Write(AllowPrefix + expiresAt.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture));
    }

    private void Write(string value)
    {
        string? directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        string temporary = _path + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(temporary, value);
        File.Move(temporary, _path, overwrite: true);
    }

    private static string NormalizeReason(string? reason)
    {
        string value = string.IsNullOrWhiteSpace(reason) ? "remote_config" : reason.Trim();
        return value.Length <= 64 ? value : value[..64];
    }
}

/// <summary>
/// A Remote-Config kill-switch reading. A fetch/parse ERROR is a distinct state
/// from "kill switch off" so the state machine can fail closed on it.
/// </summary>
public readonly struct RemoteConfigKillSwitchState
{
    private RemoteConfigKillSwitchState(bool killSwitchActive, bool hasError)
    {
        KillSwitchActive = killSwitchActive;
        HasError = hasError;
    }

    /// <summary>The RC value: kill switch explicitly on.</summary>
    public bool KillSwitchActive { get; }

    /// <summary>The RC fetch/parse failed — the value could not be read.</summary>
    public bool HasError { get; }

    /// <summary>RC read cleanly as "kill switch off".</summary>
    public static RemoteConfigKillSwitchState Off { get; } = new(killSwitchActive: false, hasError: false);

    /// <summary>RC read cleanly as "kill switch on".</summary>
    public static RemoteConfigKillSwitchState On { get; } = new(killSwitchActive: true, hasError: false);

    /// <summary>RC could not be read — fail closed and treat as ON.</summary>
    public static RemoteConfigKillSwitchState Error { get; } = new(killSwitchActive: false, hasError: true);

    /// <summary>Whether this reading must halt the session (kill-on OR fail-closed error).</summary>
    public bool RequiresHalt => KillSwitchActive || HasError;
}

/// <summary>
/// The state machine that all three independent kill paths converge on. Once
/// halted it stays halted (the operator restarts a session to clear it), and it
/// records the FIRST panic source so disputes can trace which path fired.
/// </summary>
public sealed class KillSwitchStateMachine
{
    private readonly IKillSwitchFlag _flag;
    private readonly Action<ComputerUsePanicSource>? _onHalt;
    private readonly object _gate = new();
    private bool _halted;
    private bool _lastAccessibilityTrusted = true;

    public KillSwitchStateMachine(IKillSwitchFlag flag, Action<ComputerUsePanicSource>? onHalt = null)
    {
        _flag = flag ?? throw new ArgumentNullException(nameof(flag));
        _onHalt = onHalt;
    }

    /// <summary>True once any kill path has fired.</summary>
    public bool IsHalted
    {
        get
        {
            lock (_gate)
            {
                return _halted;
            }
        }
    }

    /// <summary>The first panic source that fired, or null if not yet halted.</summary>
    public ComputerUsePanicSource? HaltSource { get; private set; }

    /// <summary>
    /// The leaf's per-dispatch check. True iff the session is halted OR the
    /// durable flag is set (e.g. by the watchdog after an app crash). A leaf
    /// that gets true here MUST NOT synthesize the pending action.
    /// </summary>
    public bool ShouldBlockDispatch() => IsHalted || _flag.IsActive;

    /// <summary>Global panic hotkey fired (Path 1).</summary>
    public void SignalHotkey() => Halt(ComputerUsePanicSource.Hotkey);

    /// <summary>Workspace / secure-desktop lock or login/UAC surface activated (Path 2).</summary>
    public void SignalWorkspaceLock() => Halt(ComputerUsePanicSource.MacLock);

    /// <summary>A phone panic gesture fired.</summary>
    public void SignalPhoneGesture() => Halt(ComputerUsePanicSource.PhoneGesture);

    /// <summary>Device/session trust was revoked.</summary>
    public void SignalRevoked() => Halt(ComputerUsePanicSource.Revoked);

    /// <summary>
    /// Applies a Remote-Config reading (Path 3). Halts on an explicit kill-on
    /// value AND on a fetch/parse error (fail-closed-on-RC-error).
    /// </summary>
    public void ApplyRemoteConfig(RemoteConfigKillSwitchState state)
    {
        if (state.RequiresHalt)
        {
            Halt(ComputerUsePanicSource.RemoteConfig);
        }
    }

    /// <summary>
    /// Feeds a UIA-trust reading. A transition from trusted → not-trusted halts
    /// (permission revoked mid-session). Returns the trust value it observed.
    /// </summary>
    public bool ObserveAccessibilityTrust(bool trusted)
    {
        bool wasTrusted;
        lock (_gate)
        {
            wasTrusted = _lastAccessibilityTrusted;
            _lastAccessibilityTrusted = trusted;
        }

        if (wasTrusted && !trusted)
        {
            Halt(ComputerUsePanicSource.AccessibilityRevoked);
        }

        return trusted;
    }

    /// <summary>Clears the halt + durable flag for a fresh session start.</summary>
    public void Reset()
    {
        lock (_gate)
        {
            _halted = false;
            _lastAccessibilityTrusted = true;
            HaltSource = null;
        }

        _flag.Clear();
    }

    private void Halt(ComputerUsePanicSource source)
    {
        bool firstHalt;
        lock (_gate)
        {
            firstHalt = !_halted;
            if (firstHalt)
            {
                _halted = true;
                HaltSource = source;
            }
        }

        // Set the durable flag SYNCHRONOUSLY so the next dispatch check blocks,
        // even on a repeat signal (idempotent). This is the halt bound.
        _flag.Activate(source.ToWire());

        if (firstHalt)
        {
            _onHalt?.Invoke(source);
        }
    }
}

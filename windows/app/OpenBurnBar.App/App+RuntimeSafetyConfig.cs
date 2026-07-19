using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.CloudSync.RuntimeSafety;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;

namespace OpenBurnBar.App;

public partial class App
{
    private readonly object _runtimeSafetyGate = new();
    private WindowsRuntimeSafetyConfigMonitor? _runtimeSafetyMonitor;
    private RemoteSafetyLeaseKillSwitchFlag? _remoteSafetyLease;
    private WindowsRuntimeSafetySnapshot _lastRuntimeSafetySnapshot =
        WindowsRuntimeSafetySnapshot.SecureDefault(DateTimeOffset.UtcNow);

    private void StartWindowsRuntimeSafetyConfig()
    {
        if (!OperatingSystem.IsWindows() || _runtimeSafetyMonitor is not null)
        {
            return;
        }

        string localRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenBurnBar");
        var localPanic = new FileKillSwitchFlag(Path.Combine(localRoot, "privileged-input-kill.flag"));
        localPanic.TryActivateIfInactive("startup_remote_config_unresolved");

        _remoteSafetyLease = new RemoteSafetyLeaseKillSwitchFlag(
            Path.Combine(localRoot, "privileged-input-remote-safety.flag"));
        _remoteSafetyLease.Activate("remote_config_unresolved");

        WindowsRuntimeSafetyState state = WindowsRuntimeSafetyState.Shared;
        state.SnapshotChanged += OnRuntimeSafetySnapshotChanged;
        state.Publish(WindowsRuntimeSafetySnapshot.SecureDefault(DateTimeOffset.UtcNow));

        _runtimeSafetyMonitor = new WindowsRuntimeSafetyConfigMonitor(
            cancellationToken => WindowsRuntimeSafetyConfigMonitor.FetchFromCallableAsync(
                () => WinAppCloudSyncHost.Root?.Callable,
                cancellationToken),
            state);
        _runtimeSafetyMonitor.Start();
        AppDiagnostics.LogEvent("runtime-safety.started", "fail_closed");
    }

    internal Task RefreshWindowsRuntimeSafetyConfigAsync(CancellationToken cancellationToken = default) =>
        _runtimeSafetyMonitor?.RefreshOnceAsync(cancellationToken) ?? Task.CompletedTask;

    private void OnRuntimeSafetySnapshotChanged(object? sender, WindowsRuntimeSafetySnapshot snapshot)
    {
        WindowsRuntimeSafetySnapshot previous;
        lock (_runtimeSafetyGate)
        {
            previous = _lastRuntimeSafetySnapshot;
            _lastRuntimeSafetySnapshot = snapshot;
        }

        DateTimeOffset now = DateTimeOffset.UtcNow;
        try
        {
            RemoteSafetyLeaseKillSwitchFlag lease = _remoteSafetyLease
                ?? throw new InvalidOperationException("The remote safety lease is unavailable.");
            if (snapshot.AllowsSystemComputerUse(now))
            {
                lease.AuthorizeUntil(snapshot.ExpiresAt);
            }
            else
            {
                lease.Activate(snapshot.IsResolved ? "remote_system_disabled" : "remote_config_unresolved");
            }
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("runtime-safety.interlock", error);
            try
            {
                ActivateDurableKillFlag("remote_safety_interlock_failure");
            }
            catch (Exception durableError)
            {
                AppDiagnostics.LogException("runtime-safety.interlock-durable", durableError);
            }
        }

        AppDiagnostics.LogEvent(
            "runtime-safety.refresh",
            snapshot.IsResolved
                ? $"computer_kill={snapshot.ComputerUseKillSwitch};media_kill={snapshot.MediaKillSwitch}"
                : "fail_closed");

        if (RevokedComputerUseCapability(previous, snapshot, now))
        {
            _ = HaltForRuntimeSafetyRevocationAsync();
        }
    }

    private static bool RevokedComputerUseCapability(
        WindowsRuntimeSafetySnapshot previous,
        WindowsRuntimeSafetySnapshot current,
        DateTimeOffset now)
    {
        if (!previous.IsFresh(now) || previous.ComputerUseKillSwitch)
        {
            return false;
        }
        return !current.IsFresh(now)
            || current.ComputerUseKillSwitch
            || (previous.ComputerUseWatchEnabled && !current.ComputerUseWatchEnabled)
            || (previous.ComputerUseBrowserEnabled && !current.ComputerUseBrowserEnabled)
            || (previous.ComputerUseSystemEnabled && !current.ComputerUseSystemEnabled)
            || (previous.ComputerUsePhoneControlEnabled && !current.ComputerUsePhoneControlEnabled);
    }

    private async Task HaltForRuntimeSafetyRevocationAsync()
    {
        try
        {
            await ActivateComputerUsePanicAsync(
                "remote_config",
                ComputerUsePanicSource.RemoteConfig).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("runtime-safety.panic", error);
        }
    }

    private async Task StopWindowsRuntimeSafetyConfigAsync()
    {
        WindowsRuntimeSafetyState.Shared.SnapshotChanged -= OnRuntimeSafetySnapshotChanged;
        try
        {
            _remoteSafetyLease?.Activate("app_exit");
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("runtime-safety.exit-interlock", error);
            ActivateDurableKillFlag("app_exit_remote_safety_failure");
        }

        WindowsRuntimeSafetyConfigMonitor? monitor = _runtimeSafetyMonitor;
        _runtimeSafetyMonitor = null;
        if (monitor is not null)
        {
            await monitor.DisposeAsync();
        }
        _remoteSafetyLease = null;
    }
}

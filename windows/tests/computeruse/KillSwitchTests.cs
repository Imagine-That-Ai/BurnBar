using System;
using System.Collections.Generic;
using System.IO;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class KillSwitchTests
{
    private static (KillSwitchStateMachine machine, InMemoryKillSwitchFlag flag, List<ComputerUsePanicSource> halts)
        Build()
    {
        var flag = new InMemoryKillSwitchFlag();
        var halts = new List<ComputerUsePanicSource>();
        var machine = new KillSwitchStateMachine(flag, halts.Add);
        return (machine, flag, halts);
    }

    [Fact]
    public void HotkeyPathHalts()
    {
        var (machine, flag, _) = Build();
        machine.SignalHotkey();

        Assert.True(machine.IsHalted);
        Assert.Equal(ComputerUsePanicSource.Hotkey, machine.HaltSource);
        Assert.True(machine.ShouldBlockDispatch());
        Assert.True(flag.IsActive);
        Assert.Equal("hotkey", flag.Reason);
    }

    [Fact]
    public void WorkspaceLockPathHalts()
    {
        var (machine, _, halts) = Build();
        machine.SignalWorkspaceLock();

        Assert.True(machine.ShouldBlockDispatch());
        Assert.Equal(ComputerUsePanicSource.MacLock, machine.HaltSource);
        Assert.Single(halts, ComputerUsePanicSource.MacLock);
    }

    [Fact]
    public void RemoteConfigOnPathHalts()
    {
        var (machine, _, _) = Build();
        machine.ApplyRemoteConfig(RemoteConfigKillSwitchState.On);

        Assert.True(machine.ShouldBlockDispatch());
        Assert.Equal(ComputerUsePanicSource.RemoteConfig, machine.HaltSource);
    }

    [Fact]
    public void RemoteConfigOffDoesNotHalt()
    {
        var (machine, flag, _) = Build();
        machine.ApplyRemoteConfig(RemoteConfigKillSwitchState.Off);

        Assert.False(machine.IsHalted);
        Assert.False(machine.ShouldBlockDispatch());
        Assert.False(flag.IsActive);
    }

    [Fact]
    public void RemoteConfigErrorFailsClosedAndHalts()
    {
        var (machine, _, _) = Build();

        // A fetch/parse error must be treated as the kill switch being ACTIVE.
        Assert.True(RemoteConfigKillSwitchState.Error.RequiresHalt);
        machine.ApplyRemoteConfig(RemoteConfigKillSwitchState.Error);

        Assert.True(machine.ShouldBlockDispatch());
        Assert.Equal(ComputerUsePanicSource.RemoteConfig, machine.HaltSource);
    }

    [Fact]
    public void AccessibilityRevocationHaltsOnTrueToFalseTransition()
    {
        var (machine, _, _) = Build();

        machine.ObserveAccessibilityTrust(trusted: true);
        Assert.False(machine.IsHalted);

        machine.ObserveAccessibilityTrust(trusted: false);
        Assert.True(machine.ShouldBlockDispatch());
        Assert.Equal(ComputerUsePanicSource.AccessibilityRevoked, machine.HaltSource);
    }

    [Fact]
    public void WatchdogSetFlagBlocksDispatchEvenWhenTheMachineIsNotHalted()
    {
        var (machine, flag, _) = Build();

        // The watchdog process sets the durable flag when the app cannot; a leaf
        // that checks ShouldBlockDispatch() must stop even though the in-process
        // state machine never observed a panic.
        Assert.False(machine.ShouldBlockDispatch());
        flag.Activate("watchdog");

        Assert.True(machine.ShouldBlockDispatch());
        Assert.False(machine.IsHalted);
    }

    [Fact]
    public void HaltBound_NoDispatchPassesAfterThePanicSignalIsObserved()
    {
        var (machine, _, _) = Build();
        var dispatched = 0;

        for (var i = 0; i < 5; i++)
        {
            if (machine.ShouldBlockDispatch())
            {
                break;
            }

            dispatched++;
            if (i == 1)
            {
                machine.SignalHotkey(); // panic mid-loop
            }
        }

        // Dispatches on i=0 and i=1 (the panic fires AFTER the i=1 dispatch);
        // i=2's check blocks. No action dispatches after the panic is observed.
        Assert.Equal(2, dispatched);
    }

    [Fact]
    public void FirstHaltSourceWinsAndCallbackFiresOnce()
    {
        var (machine, _, halts) = Build();
        machine.SignalHotkey();
        machine.SignalWorkspaceLock();
        machine.ApplyRemoteConfig(RemoteConfigKillSwitchState.On);

        Assert.Equal(ComputerUsePanicSource.Hotkey, machine.HaltSource);
        Assert.Single(halts);
    }

    [Fact]
    public void ResetClearsHaltAndFlagAndAllowsHaltingAgain()
    {
        var (machine, flag, _) = Build();
        machine.SignalHotkey();
        Assert.True(machine.ShouldBlockDispatch());

        machine.Reset();
        Assert.False(machine.IsHalted);
        Assert.False(machine.ShouldBlockDispatch());
        Assert.False(flag.IsActive);
        Assert.Null(machine.HaltSource);

        machine.ApplyRemoteConfig(RemoteConfigKillSwitchState.On);
        Assert.True(machine.ShouldBlockDispatch());
    }

    [Fact]
    public void FileKillSwitchFlagIsCrossProcessDurable()
    {
        var path = Path.Combine(Path.GetTempPath(), "cu-kill-" + Guid.NewGuid().ToString("N") + ".flag");
        try
        {
            var writer = new FileKillSwitchFlag(path);
            Assert.False(writer.IsActive);
            writer.Activate("remote_config");

            // A separate instance (e.g. an input leaf) sees the same flag.
            var reader = new FileKillSwitchFlag(path);
            Assert.True(reader.IsActive);
            Assert.Equal("remote_config", File.ReadAllText(path));

            reader.Clear();
            Assert.False(writer.IsActive);
        }
        finally
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }
}

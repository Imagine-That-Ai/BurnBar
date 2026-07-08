using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Cast.Discovery;
using OpenBurnBar.Integrations.Cast.Model;
using OpenBurnBar.Integrations.Cast.Session;
using OpenBurnBar.Integrations.Cast.Wizard;
using Xunit;

namespace OpenBurnBar.Integrations.Cast.Tests;

public sealed class CastWizardTests
{
    private static CastDevice Hub(string name = "Living Room Hub")
        => new()
        {
            ServiceName = name.Replace(' ', '-'),
            FriendlyName = name,
            Host = "192.168.1.42",
            Port = 8009,
            Model = "Google Nest Hub",
            Identifier = "uuid-1",
        };

    // ---- state machine ----

    [Fact]
    public void Start_MovesToDiscoverAndClearsDevices()
    {
        var sm = new CastWizardStateMachine();
        sm.DevicesDiscovered(new[] { Hub() });
        sm.Start();
        Assert.IsType<CastWizardStep.Discover>(sm.Step);
        Assert.Empty(sm.Devices);
    }

    [Fact]
    public void DiscoveryTimeout_WithNoDevices_ShowsNoDevices()
    {
        var sm = new CastWizardStateMachine();
        sm.Start();
        sm.DiscoveryTimedOut();
        Assert.IsType<CastWizardStep.NoDevices>(sm.Step);
    }

    [Fact]
    public void DevicesDiscovered_FromDiscover_AdvancesToPick()
    {
        var sm = new CastWizardStateMachine();
        sm.Start();
        sm.DevicesDiscovered(new[] { Hub() });
        Assert.IsType<CastWizardStep.Pick>(sm.Step);
        Assert.Single(sm.Devices);
    }

    [Fact]
    public void DevicesDiscovered_FromNoDevices_RecoversToPick()
    {
        var sm = new CastWizardStateMachine();
        sm.Start();
        sm.DiscoveryTimedOut();
        sm.DevicesDiscovered(new[] { Hub() });
        Assert.IsType<CastWizardStep.Pick>(sm.Step);
    }

    [Fact]
    public void BeginTest_WithoutBridgeUrl_Fails()
    {
        var sm = new CastWizardStateMachine();
        sm.Start();
        sm.DevicesDiscovered(new[] { Hub() });
        sm.BeginTest(Hub(), bridgeUrlConfigured: false);
        var failed = Assert.IsType<CastWizardStep.Failed>(sm.Step);
        Assert.Contains("bridge URL", failed.Reason);
    }

    [Fact]
    public void BeginTest_WithBridge_EntersTesting()
    {
        var sm = new CastWizardStateMachine();
        sm.Start();
        sm.BeginTest(Hub(), bridgeUrlConfigured: true);
        Assert.IsType<CastWizardStep.Testing>(sm.Step);
    }

    [Fact]
    public void ApplyCastResult_Success_MovesToConfirm()
    {
        var sm = new CastWizardStateMachine();
        sm.BeginTest(Hub(), true);
        sm.ApplyCastResult(new CastRecoveryResult { Kind = CastRecoveryResultKind.Success, SessionId = "s" });
        Assert.IsType<CastWizardStep.Confirm>(sm.Step);
    }

    [Fact]
    public void ApplyCastResult_Recovered_MovesToConfirm()
    {
        var sm = new CastWizardStateMachine();
        sm.BeginTest(Hub(), true);
        sm.ApplyCastResult(new CastRecoveryResult
        {
            Kind = CastRecoveryResultKind.RecoveredViaHomeAssistant,
            Message = "recovered",
        });
        Assert.IsType<CastWizardStep.Confirm>(sm.Step);
    }

    [Fact]
    public void ApplyCastResult_Failure_MovesToRecoverWithAttemptAndError()
    {
        var sm = new CastWizardStateMachine();
        sm.BeginTest(Hub(), true);
        sm.ApplyCastResult(new CastRecoveryResult
        {
            Kind = CastRecoveryResultKind.Failure,
            Message = "hub offline",
            AttemptsMade = 4,
        });
        var recover = Assert.IsType<CastWizardStep.Recover>(sm.Step);
        Assert.Equal(4, recover.Attempt);
        Assert.Equal("hub offline", recover.LastError);
    }

    [Fact]
    public void RetryDevice_FromRecover_ReentersTesting()
    {
        var sm = new CastWizardStateMachine();
        sm.BeginTest(Hub(), true);
        sm.ApplyCastResult(new CastRecoveryResult { Kind = CastRecoveryResultKind.Failure, Message = "x" });
        var device = sm.RetryDevice();
        Assert.NotNull(device);
        Assert.IsType<CastWizardStep.Testing>(sm.Step);
    }

    [Fact]
    public void ConfirmTestPattern_ProducesSelectionAndDone()
    {
        var sm = new CastWizardStateMachine();
        sm.BeginTest(Hub(), true);
        sm.ApplyCastResult(new CastRecoveryResult { Kind = CastRecoveryResultKind.Success });
        var selection = sm.ConfirmTestPattern("https://bridge.test/dashboard");
        Assert.NotNull(selection);
        Assert.Equal("Living Room Hub", selection!.Device.FriendlyName);
        Assert.Equal("https://bridge.test/dashboard", selection.DashboardUrl);
        Assert.IsType<CastWizardStep.Done>(sm.Step);
    }

    [Fact]
    public void ConfirmTestPattern_OutsideConfirm_ReturnsNull()
    {
        var sm = new CastWizardStateMachine();
        sm.Start();
        Assert.Null(sm.ConfirmTestPattern(null));
    }

    [Fact]
    public void TryAnother_ReturnsToPick()
    {
        var sm = new CastWizardStateMachine();
        sm.BeginTest(Hub(), true);
        sm.TryAnother();
        Assert.IsType<CastWizardStep.Pick>(sm.Step);
    }

    [Fact]
    public void Cancel_ReturnsToWelcome()
    {
        var sm = new CastWizardStateMachine();
        sm.BeginTest(Hub(), true);
        sm.Cancel();
        Assert.IsType<CastWizardStep.Welcome>(sm.Step);
    }

    // ---- view-model (reactive, with fakes) ----

    private sealed class FakeBrowser : ICastServiceBrowser
    {
        public event Action<IReadOnlyList<CastDevice>>? DevicesChanged;

        public int StartCount { get; private set; }

        public bool Stopped { get; private set; }

        public void Start() => StartCount++;

        public void Stop() => Stopped = true;

        public void Dispose()
        {
        }

        public void Publish(IReadOnlyList<CastDevice> devices) => DevicesChanged?.Invoke(devices);
    }

    [Fact]
    public async Task ViewModel_DriveHappyPath_DiscoverPickConfirm()
    {
        var browser = new FakeBrowser();
        CastSelection? confirmed = null;
        var env = new CastWizardEnvironment
        {
            Browser = browser,
            CastAsync = _ => Task.FromResult(new CastRecoveryResult
            {
                Kind = CastRecoveryResultKind.Success,
                SessionId = "sess",
            }),
            BridgeUrlConfigured = () => true,
            DashboardUrl = () => "https://bridge.test/board",
            OnSelectionConfirmed = s => confirmed = s,
        };

        using var vm = new CastWizardViewModel(env);
        var changeCount = 0;
        vm.PropertyChanged += (_, _) => changeCount++;

        vm.Start();
        Assert.Equal(1, browser.StartCount);
        Assert.IsType<CastWizardStep.Discover>(vm.Step);

        browser.Publish(new[] { Hub() });
        Assert.IsType<CastWizardStep.Pick>(vm.Step);
        Assert.Single(vm.Devices);

        await vm.PickDeviceAsync(Hub());
        Assert.IsType<CastWizardStep.Confirm>(vm.Step);
        Assert.Equal("Living Room Hub", vm.SelectedDevice!.FriendlyName);

        vm.ConfirmTestPattern();
        Assert.IsType<CastWizardStep.Done>(vm.Step);
        Assert.NotNull(confirmed);
        Assert.Equal("https://bridge.test/board", confirmed!.DashboardUrl);
        Assert.True(changeCount > 0);
    }

    [Fact]
    public async Task ViewModel_FailedCast_MovesToRecoverThenRetryRunsAgain()
    {
        var browser = new FakeBrowser();
        var calls = 0;
        var env = new CastWizardEnvironment
        {
            Browser = browser,
            CastAsync = _ =>
            {
                calls++;
                return Task.FromResult(calls == 1
                    ? new CastRecoveryResult { Kind = CastRecoveryResultKind.Failure, Message = "offline", AttemptsMade = 4 }
                    : new CastRecoveryResult { Kind = CastRecoveryResultKind.Success, SessionId = "s" });
            },
            BridgeUrlConfigured = () => true,
            DashboardUrl = () => null,
        };

        using var vm = new CastWizardViewModel(env);
        vm.Start();
        browser.Publish(new[] { Hub() });

        await vm.PickDeviceAsync(Hub());
        Assert.IsType<CastWizardStep.Recover>(vm.Step);

        await vm.RetryDeviceAsync();
        Assert.IsType<CastWizardStep.Confirm>(vm.Step);
        Assert.Equal(2, calls);
    }

    [Fact]
    public void ViewModel_Cancel_StopsTheBrowser()
    {
        var browser = new FakeBrowser();
        var env = new CastWizardEnvironment
        {
            Browser = browser,
            CastAsync = _ => Task.FromResult(new CastRecoveryResult { Kind = CastRecoveryResultKind.Success }),
            BridgeUrlConfigured = () => true,
            DashboardUrl = () => null,
        };
        using var vm = new CastWizardViewModel(env);
        vm.Start();
        vm.Cancel();
        Assert.True(browser.Stopped);
        Assert.IsType<CastWizardStep.Welcome>(vm.Step);
    }
}

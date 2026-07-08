// Parity source: AgentLens/Services/Cast/CastWizardModel.swift (@Observable model)
// Portable, WinUI-free reactive wrapper the XAML Setup Cast Wizard binds to. The
// same view-model is unit-tested off-Windows with a fake browser + cast runner.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.Cast.Discovery;
using OpenBurnBar.Integrations.Cast.Model;
using OpenBurnBar.Integrations.Cast.Session;

namespace OpenBurnBar.Integrations.Cast.Wizard;

/// <summary>The IO seams the wizard view-model needs, injected so it stays testable.</summary>
public sealed class CastWizardEnvironment
{
    /// <summary>The live device browser.</summary>
    public required ICastServiceBrowser Browser { get; init; }

    /// <summary>Runs the cast + auto-recovery flow for a device.</summary>
    public required Func<CastDevice, Task<CastRecoveryResult>> CastAsync { get; init; }

    /// <summary>Whether the Smart Display bridge URL is configured.</summary>
    public required Func<bool> BridgeUrlConfigured { get; init; }

    /// <summary>The dashboard URL to persist on confirm (or <see langword="null"/>).</summary>
    public required Func<string?> DashboardUrl { get; init; }

    /// <summary>Invoked with the selection when the user confirms a device.</summary>
    public Action<CastSelection>? OnSelectionConfirmed { get; init; }
}

/// <summary>
/// Reactive view-model for the Setup Cast Wizard. Owns a
/// <see cref="CastWizardStateMachine"/> and mediates the browser + cast IO,
/// raising <see cref="PropertyChanged"/> so XAML <c>x:Bind</c> updates.
/// </summary>
public sealed class CastWizardViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly CastWizardStateMachine _machine = new();
    private readonly CastWizardEnvironment _env;
    private bool _browsing;

    /// <summary>Raised when a bound property changes.</summary>
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Create the view-model over an injected environment.</summary>
    public CastWizardViewModel(CastWizardEnvironment environment)
    {
        _env = environment ?? throw new ArgumentNullException(nameof(environment));
    }

    /// <summary>Current wizard step.</summary>
    public CastWizardStep Step => _machine.Step;

    /// <summary>The current device list.</summary>
    public IReadOnlyList<CastDevice> Devices => _machine.Devices;

    /// <summary>The device currently being tested / confirmed, if any.</summary>
    public CastDevice? SelectedDevice => _machine.Step switch
    {
        CastWizardStep.Testing testing => testing.Device,
        CastWizardStep.Recover recover => recover.Device,
        CastWizardStep.Confirm confirm => confirm.Device,
        CastWizardStep.Done done => done.Device,
        _ => null,
    };

    /// <summary>Begin discovery and subscribe to the browser.</summary>
    public void Start()
    {
        _machine.Start();
        if (!_browsing)
        {
            _env.Browser.DevicesChanged += OnDevicesChanged;
            _browsing = true;
        }

        _env.Browser.Start();
        RaiseAll();
    }

    /// <summary>Restart discovery.</summary>
    public void RetryDiscovery()
    {
        _machine.RetryDiscovery();
        _env.Browser.Start();
        RaiseAll();
    }

    /// <summary>The 10s discovery timeout elapsed.</summary>
    public void HandleDiscoveryTimeout()
    {
        _machine.DiscoveryTimedOut();
        RaiseAll();
    }

    /// <summary>Choose a device and run the test cast + recovery.</summary>
    public async Task PickDeviceAsync(CastDevice device)
    {
        _machine.BeginTest(device, _env.BridgeUrlConfigured());
        RaiseAll();
        if (_machine.Step is CastWizardStep.Testing)
        {
            var result = await _env.CastAsync(device).ConfigureAwait(false);
            _machine.ApplyCastResult(result);
            RaiseAll();
        }
    }

    /// <summary>Retry the device currently in the Recover step.</summary>
    public async Task RetryDeviceAsync()
    {
        var device = _machine.RetryDevice();
        RaiseAll();
        if (device is not null)
        {
            var result = await _env.CastAsync(device).ConfigureAwait(false);
            _machine.ApplyCastResult(result);
            RaiseAll();
        }
    }

    /// <summary>Return to the device picker.</summary>
    public void TryAnother()
    {
        _machine.TryAnother();
        RaiseAll();
    }

    /// <summary>Confirm the test pattern and persist the selection.</summary>
    public void ConfirmTestPattern()
    {
        var selection = _machine.ConfirmTestPattern(_env.DashboardUrl());
        if (selection is not null)
        {
            _env.OnSelectionConfirmed?.Invoke(selection);
        }

        RaiseAll();
    }

    /// <summary>Cancel and tear down discovery.</summary>
    public void Cancel()
    {
        StopBrowsing();
        _machine.Cancel();
        RaiseAll();
    }

    private void OnDevicesChanged(IReadOnlyList<CastDevice> devices)
    {
        _machine.DevicesDiscovered(devices);
        RaiseAll();
    }

    private void StopBrowsing()
    {
        if (_browsing)
        {
            _env.Browser.DevicesChanged -= OnDevicesChanged;
            _browsing = false;
        }

        _env.Browser.Stop();
    }

    private void RaiseAll()
    {
        Raise(nameof(Step));
        Raise(nameof(Devices));
        Raise(nameof(SelectedDevice));
    }

    private void Raise([CallerMemberName] string? propertyName = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));

    /// <summary>Unsubscribe from the browser.</summary>
    public void Dispose() => StopBrowsing();
}

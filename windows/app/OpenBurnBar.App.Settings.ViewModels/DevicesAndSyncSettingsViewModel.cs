// View-model for the Devices & Sync settings tab.
//
// Faithful port of AgentLens/Views/Settings/DevicesAndSyncSettingsView.swift — a
// device-trust / credential-transfer surface. Device state is server/keychain-backed
// (not UserDefaults), so it comes through the IDeviceTrustHost seam; the cloud-sync +
// smart-display toggles persist through IDevicesSyncStore. Device management is data-
// gated on a signed-in session (#1304 OAuth, Wave 2).
//
// The Swift flow requires a safety-number comparison before a device is approved
// (DeviceTrustSafetyCompareSheet.didCompare gates the Approve button); this view-model
// reproduces that two-step gate.

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>A trusted (or pending) device row.</summary>
public sealed record TrustedDeviceInfo(string Id, string Name, string Platform, bool IsApproved);

/// <summary>Lists + mutates the trusted-device set (WinUI: DeviceTrustViewModel). Data/OS-bound.</summary>
public interface IDeviceTrustHost
{
    /// <summary>Current trusted + pending devices.</summary>
    IReadOnlyList<TrustedDeviceInfo> LoadDevices();

    /// <summary>Approve the device with <paramref name="id"/>.</summary>
    bool Approve(string id);

    /// <summary>Revoke the device with <paramref name="id"/>.</summary>
    bool Revoke(string id);
}

/// <summary>An in-memory device host (default for tests).</summary>
public sealed class InMemoryDeviceTrustHost : IDeviceTrustHost
{
    private readonly List<TrustedDeviceInfo> _devices;

    public InMemoryDeviceTrustHost(IEnumerable<TrustedDeviceInfo>? seed = null) =>
        _devices = seed?.ToList() ?? new List<TrustedDeviceInfo>();

    public IReadOnlyList<TrustedDeviceInfo> LoadDevices() => _devices.ToArray();

    public bool Approve(string id) => Mutate(id, approved: true);

    public bool Revoke(string id)
    {
        int removed = _devices.RemoveAll(d => d.Id == id);
        return removed > 0;
    }

    private bool Mutate(string id, bool approved)
    {
        int index = _devices.FindIndex(d => d.Id == id);
        if (index < 0)
        {
            return false;
        }

        _devices[index] = _devices[index] with { IsApproved = approved };
        return true;
    }
}

/// <summary>Persists the cloud-sync + smart-display toggles.</summary>
public interface IDevicesSyncStore
{
    bool CloudSyncEnabled { get; set; }

    bool SmartDisplaysEnabled { get; set; }
}

/// <summary>In-memory devices/sync store (default for tests).</summary>
public sealed class InMemoryDevicesSyncStore : IDevicesSyncStore
{
    public bool CloudSyncEnabled { get; set; }

    public bool SmartDisplaysEnabled { get; set; }
}

/// <summary>Backs the Devices &amp; Sync tab (cloud sync, trusted devices, smart displays).</summary>
public sealed class DevicesAndSyncSettingsViewModel : ObservableSettingsViewModel
{
    private readonly IDeviceTrustHost _deviceHost;
    private readonly IDevicesSyncStore _store;
    private readonly IAccountSessionGate _session;

    private string? _deviceAwaitingApprovalId;
    private bool _safetyCompareConfirmed;

    public DevicesAndSyncSettingsViewModel(
        IDeviceTrustHost? deviceHost = null,
        IDevicesSyncStore? store = null,
        IAccountSessionGate? session = null)
    {
        _deviceHost = deviceHost ?? new InMemoryDeviceTrustHost();
        _store = store ?? new InMemoryDevicesSyncStore();
        _session = session ?? FakeAccountSessionGate.SignedOut;
        LoadDevices();
    }

    /// <summary>The current device rows.</summary>
    public ObservableCollection<TrustedDeviceInfo> Devices { get; } = new();

    /// <summary>Whether device management is available (needs a signed-in session).</summary>
    public bool CanManageDevices => _session.IsSignedIn;

    /// <summary>Sync usage + conversations to OpenBurnBar Cloud.</summary>
    public bool CloudSyncEnabled
    {
        get => _store.CloudSyncEnabled;
        set { if (value != _store.CloudSyncEnabled) { _store.CloudSyncEnabled = value; OnPropertyChanged(); } }
    }

    /// <summary>Cast cost glances to smart displays.</summary>
    public bool SmartDisplaysEnabled
    {
        get => _store.SmartDisplaysEnabled;
        set { if (value != _store.SmartDisplaysEnabled) { _store.SmartDisplaysEnabled = value; OnPropertyChanged(); } }
    }

    /// <summary>Reload the device list from the host.</summary>
    public void LoadDevices()
    {
        Devices.Clear();
        foreach (var device in _deviceHost.LoadDevices())
        {
            Devices.Add(device);
        }

        OnPropertyChanged(nameof(DeviceCount));
    }

    /// <summary>Number of devices.</summary>
    public int DeviceCount => Devices.Count;

    /// <summary>Id of the device awaiting safety-compare approval (null when none).</summary>
    public string? DeviceAwaitingApprovalId
    {
        get => _deviceAwaitingApprovalId;
        private set { if (Set(ref _deviceAwaitingApprovalId, value)) { OnPropertyChanged(nameof(IsAwaitingApproval)); } }
    }

    /// <summary>Whether a device is awaiting the safety comparison.</summary>
    public bool IsAwaitingApproval => _deviceAwaitingApprovalId is not null;

    /// <summary>Whether the operator confirmed the safety-number comparison.</summary>
    public bool SafetyCompareConfirmed
    {
        get => _safetyCompareConfirmed;
        private set { if (Set(ref _safetyCompareConfirmed, value)) { OnPropertyChanged(nameof(CanApprovePendingDevice)); } }
    }

    /// <summary>Whether the pending device can be approved (compare confirmed + still signed in).</summary>
    public bool CanApprovePendingDevice =>
        IsAwaitingApproval && _safetyCompareConfirmed && CanManageDevices;

    /// <summary>Begin approving a device — opens the safety-compare gate.</summary>
    public bool BeginApproval(string id)
    {
        if (!CanManageDevices || Devices.All(d => d.Id != id))
        {
            return false;
        }

        DeviceAwaitingApprovalId = id;
        SafetyCompareConfirmed = false;
        return true;
    }

    /// <summary>Confirm the safety-number comparison (Swift <c>didCompare = true</c>).</summary>
    public void ConfirmSafetyCompare()
    {
        if (IsAwaitingApproval)
        {
            SafetyCompareConfirmed = true;
        }
    }

    /// <summary>Approve the pending device once the safety compare is confirmed.</summary>
    public bool ApprovePendingDevice()
    {
        if (!CanApprovePendingDevice || _deviceAwaitingApprovalId is not { } id)
        {
            return false;
        }

        bool ok = _deviceHost.Approve(id);
        CancelApproval();
        LoadDevices();
        return ok;
    }

    /// <summary>Cancel a pending approval.</summary>
    public void CancelApproval()
    {
        DeviceAwaitingApprovalId = null;
        SafetyCompareConfirmed = false;
    }

    /// <summary>Revoke a device's trust.</summary>
    public bool Revoke(string id)
    {
        if (!CanManageDevices)
        {
            return false;
        }

        bool ok = _deviceHost.Revoke(id);
        if (_deviceAwaitingApprovalId == id)
        {
            CancelApproval();
        }

        LoadDevices();
        return ok;
    }
}

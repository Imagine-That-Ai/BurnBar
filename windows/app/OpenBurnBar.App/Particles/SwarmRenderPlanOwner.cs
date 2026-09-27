// WINDOWS-ONLY / CI-DEFERRED (WinRT sensors + WinUI). See Win2DSubstrateDrawingSession.cs header.

using System;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.Particles.Policy;
using Windows.Devices.Power;
using Windows.Networking.Connectivity;
using Windows.System.Power;
using Windows.UI.ViewManagement;

namespace OpenBurnBar.App.Particles;

/// <summary>
/// The prefs/sensors owner for a <see cref="SwarmCanvasHost"/> — the Windows
/// analog of the iOS <c>ConstellationBackgroundView</c> gate block and the
/// Android <c>SwarmBackground</c> composable. It loads the persisted
/// <see cref="SwarmBackgroundPreferences"/>, reads the live platform
/// sensors, and resolves <see cref="SwarmBackgroundPowerPolicy"/> into
/// <see cref="SwarmCanvasHost.RenderPlan"/>, re-resolving on every sensor
/// transition (plug/unplug, network, battery-saver).
/// </summary>
/// <remarks>
/// A thin caller over the tested portable core: every gating decision lives
/// in <see cref="SwarmPlanResolver"/> (unit-tested on macOS); this class
/// only owns the WinRT sensor reads + change subscriptions, which only
/// Windows/CI exercises live. Each sensor is best-effort with a documented
/// fallback direction, mirroring the Android monitor's keep-snapshot
/// posture. The static network/battery-saver subscriptions root the owner
/// until <see cref="Dispose"/> — hosts dispose it with the canvas.
/// </remarks>
public sealed class SwarmRenderPlanOwner : IDisposable
{
    private readonly SwarmCanvasHost _host;
    private readonly SwarmPreferencesStore _store;
    private readonly UISettings _uiSettings = new();
    private readonly Battery? _battery;
    private bool _disposed;
    private MobileBackgroundVisibility _requestedVisibility = MobileBackgroundVisibility.Prominent;
    private MobileBackgroundVisibility _inheritedVisibility = MobileBackgroundVisibility.Prominent;
    private bool _sceneActive = true;

    /// <summary>
    /// Attach to <paramref name="host"/>, loading prefs from
    /// <paramref name="preferencesPath"/> (defaults to
    /// <see cref="DefaultPreferencesPath"/>) and resolving the initial plan.
    /// </summary>
    public SwarmRenderPlanOwner(SwarmCanvasHost host, string? preferencesPath = null)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
        _store = new SwarmPreferencesStore(preferencesPath ?? DefaultPreferencesPath());
        _battery = TryGetBattery();
        Subscribe();
        Refresh();
    }

    /// <summary>
    /// The default prefs path: <c>%LOCALAPPDATA%\OpenBurnBar\swarm-background.json</c>
    /// (or the automation profile root when set).
    /// </summary>
    public static string DefaultPreferencesPath() =>
        RuntimePaths.AppDataFile(SwarmPreferencesStore.FileName);

    /// <summary>The current persisted prefs (a settings surface edits these).</summary>
    public SwarmBackgroundPreferences Preferences => _store.Preferences;

    /// <summary>Persist new prefs and re-resolve (a settings surface calls this).</summary>
    public void UpdatePreferences(SwarmBackgroundPreferences preferences)
    {
        _store.Update(preferences);
        Refresh();
    }

    /// <summary>The view's own visibility ask (prominent while no producer exists).</summary>
    public MobileBackgroundVisibility RequestedVisibility
    {
        get => _requestedVisibility;
        set
        {
            _requestedVisibility = value;
            Refresh();
        }
    }

    /// <summary>The surrounding surface's visibility ask (constrains the request).</summary>
    public MobileBackgroundVisibility InheritedVisibility
    {
        get => _inheritedVisibility;
        set
        {
            _inheritedVisibility = value;
            Refresh();
        }
    }

    /// <summary>Whether the scene is active (the <c>scenePhase == .active</c> analog).</summary>
    public bool SceneActive
    {
        get => _sceneActive;
        set
        {
            _sceneActive = value;
            Refresh();
        }
    }

    /// <summary>Re-snapshot the sensors and re-resolve the host's plan.</summary>
    public void Refresh()
    {
        if (_disposed)
        {
            return;
        }

        var snapshot = new SwarmEnvironmentSnapshot(
            IsPowerConnected: ReadPowerConnected(),
            IsWifiConnected: ReadWifiConnected(),
            ScenePhaseActive: _sceneActive,
            IsLowPowerModeEnabled: ReadBatterySaverOn(),
            ReduceMotion: ReadReduceMotion());
        _host.RenderPlan = SwarmPlanResolver.Resolve(
            _store.Preferences, snapshot, _requestedVisibility, _inheritedVisibility);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_battery is not null)
        {
            _battery.ReportUpdated -= OnBatteryReportUpdated;
        }

        NetworkInformation.NetworkStatusChanged -= OnNetworkStatusChanged;
        PowerManager.EnergySaverStatusChanged -= OnEnergySaverStatusChanged;
    }

    private void Subscribe()
    {
        TrySubscribe(() =>
        {
            if (_battery is not null)
            {
                _battery.ReportUpdated += OnBatteryReportUpdated;
            }
        });
        TrySubscribe(() => NetworkInformation.NetworkStatusChanged += OnNetworkStatusChanged);
        TrySubscribe(() => PowerManager.EnergySaverStatusChanged += OnEnergySaverStatusChanged);
    }

    private static void TrySubscribe(Action subscribe)
    {
        try
        {
            subscribe();
        }
        catch (Exception)
        {
            // Sensor unavailable; Refresh still snapshots the rest.
        }
    }

    private static Battery? TryGetBattery()
    {
        try
        {
            return Battery.AggregateBattery;
        }
        catch (Exception)
        {
            return null;
        }
    }

    // Only actively-discharging counts as unplugged: desktops without a
    // battery (NotPresent / missing API) run on mains, and Idle means the
    // charger is holding the pack. Fail direction: connected.
    private bool ReadPowerConnected()
    {
        try
        {
            BatteryReport? report = _battery?.GetReport();
            if (report is null)
            {
                return true;
            }

            return report.Status != BatteryStatus.Discharging;
        }
        catch (Exception)
        {
            return true;
        }
    }

    // iOS parity: Wi-Fi or wired Ethernet counts (cellular does not). Fail
    // direction: not connected, so a Wi-Fi-Only gate holds a static frame.
    private static bool ReadWifiConnected()
    {
        try
        {
            ConnectionProfile? profile = NetworkInformation.GetInternetConnectionProfile();
            if (profile is null)
            {
                return false;
            }

            if (profile.IsWlanConnectionProfile)
            {
                return true;
            }

            // IANA ifType 6 = ethernetCsmacd (wired Ethernet).
            return profile.NetworkAdapter?.IanaInterfaceType == 6;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool ReadBatterySaverOn()
    {
        try
        {
            return PowerManager.EnergySaverStatus == EnergySaverStatus.On;
        }
        catch (Exception)
        {
            return false;
        }
    }

    // The same signal DashboardBackdrop already uses for its reduced field.
    private bool ReadReduceMotion()
    {
        try
        {
            return !_uiSettings.AnimationsEnabled;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private void OnBatteryReportUpdated(Battery sender, object args) => Refresh();

    private void OnNetworkStatusChanged(object sender) => Refresh();

    private void OnEnergySaverStatusChanged(object sender, object args) => Refresh();
}

// View-model for the Alerts settings tab.
//
// Faithful port of the Alerts portion of
// AgentLens/Views/Settings/AlertsAndNotificationsViews.swift + the backing AlertSettings
// store (AgentLens/Services/Settings/Stores/AlertSettings.swift):
//   costAlertThreshold : Double?  = nil        (nil == Off; paired with hasCostAlertThreshold)
//   dailyDigestEnabled : Bool     = false
//   dailyDigestHour    : Int      = 18         (load-clamped to 0..23)
// View rules: enabling the cost alert seeds max(existing ?? 25, 1); the threshold binding
// writes nil for any value <= 0 ("Off"); the hour picker is 0..23.

using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>The three persisted alert fields (AlertSettings).</summary>
public sealed record AlertSettingsSnapshot(
    double? CostAlertThreshold,
    bool DailyDigestEnabled,
    int DailyDigestHour)
{
    /// <summary>The macOS defaults (cost alert off, digest off, 18:00).</summary>
    public static readonly AlertSettingsSnapshot Default = new(
        CostAlertThreshold: null,
        DailyDigestEnabled: false,
        DailyDigestHour: 18);
}

/// <summary>Loads + persists the alert settings.</summary>
public interface IAlertSettingsStore
{
    /// <summary>Read the current settings.</summary>
    AlertSettingsSnapshot Load();

    /// <summary>Persist the settings.</summary>
    void Save(AlertSettingsSnapshot settings);
}

/// <summary>In-memory alert store (default for tests).</summary>
public sealed class InMemoryAlertSettingsStore : IAlertSettingsStore
{
    private AlertSettingsSnapshot _settings;

    public InMemoryAlertSettingsStore(AlertSettingsSnapshot? seed = null) =>
        _settings = seed ?? AlertSettingsSnapshot.Default;

    /// <inheritdoc />
    public AlertSettingsSnapshot Load() => _settings;

    /// <inheritdoc />
    public void Save(AlertSettingsSnapshot settings) => _settings = settings;
}

/// <summary>Backs the Alerts tab (daily-spend threshold + daily digest).</summary>
public sealed class AlertsSettingsViewModel : ObservableSettingsViewModel
{
    /// <summary>Seed threshold when a user first enables the cost alert (Swift default 25).</summary>
    public const double DefaultThresholdSeed = 25;

    /// <summary>Floor applied to the seeded threshold (Swift <c>max(..., 1)</c>).</summary>
    public const double MinimumThreshold = 1;

    public const int MinHour = 0;
    public const int MaxHour = 23;

    private readonly IAlertSettingsStore _store;

    private double? _costAlertThreshold;
    private bool _dailyDigestEnabled;
    private int _dailyDigestHour = AlertSettingsSnapshot.Default.DailyDigestHour;

    public AlertsSettingsViewModel(IAlertSettingsStore? store = null)
    {
        _store = store ?? new InMemoryAlertSettingsStore();
        Load();
    }

    /// <summary>Load persisted settings into the view-model (applying the hour clamp).</summary>
    public void Load()
    {
        var s = _store.Load();
        _costAlertThreshold = NormalizeThreshold(s.CostAlertThreshold);
        _dailyDigestEnabled = s.DailyDigestEnabled;
        _dailyDigestHour = ClampHour(s.DailyDigestHour);
        RaiseAll();
    }

    /// <summary>The daily-spend threshold in USD; <c>null</c> means Off.</summary>
    public double? CostAlertThreshold
    {
        get => _costAlertThreshold;
        set
        {
            // Swift costAlertBinding: any value <= 0 clears to Off (nil).
            var normalized = NormalizeThreshold(value);
            if (Set(ref _costAlertThreshold, normalized))
            {
                Persist();
                OnPropertyChanged(nameof(CostAlertEnabled));
                OnPropertyChanged(nameof(ThresholdDisplay));
            }
        }
    }

    /// <summary>Whether a cost alert threshold is set.</summary>
    public bool CostAlertEnabled
    {
        get => _costAlertThreshold is not null;
        set
        {
            if (value == CostAlertEnabled)
            {
                return;
            }

            // Enabling seeds max(existing ?? 25, 1); disabling clears to Off.
            CostAlertThreshold = value
                ? Math.Max(_costAlertThreshold ?? DefaultThresholdSeed, MinimumThreshold)
                : null;
        }
    }

    /// <summary>The threshold rendered for display (e.g. "$25" or "Off").</summary>
    public string ThresholdDisplay =>
        _costAlertThreshold is { } t ? $"${t:0.##}" : "Off";

    /// <summary>Whether the daily digest is enabled.</summary>
    public bool DailyDigestEnabled
    {
        get => _dailyDigestEnabled;
        set { if (Set(ref _dailyDigestEnabled, value)) { Persist(); } }
    }

    /// <summary>Hour of day (0..23) the digest fires.</summary>
    public int DailyDigestHour
    {
        get => _dailyDigestHour;
        set
        {
            var clamped = ClampHour(value);
            if (Set(ref _dailyDigestHour, clamped))
            {
                Persist();
                OnPropertyChanged(nameof(DailyDigestHourDisplay));
            }
        }
    }

    /// <summary>The digest hour rendered as <c>HH:00</c> (Swift <c>%02d:00</c>).</summary>
    public string DailyDigestHourDisplay => $"{_dailyDigestHour:D2}:00";

    /// <summary>The 0..23 hour choices the picker offers.</summary>
    public IReadOnlyList<int> HourChoices { get; } = Enumerable.Range(MinHour, MaxHour - MinHour + 1).ToArray();

    private static double? NormalizeThreshold(double? value) =>
        value is { } v && v > 0 ? v : null;

    private static int ClampHour(int hour) =>
        hour >= MinHour && hour <= MaxHour ? hour : AlertSettingsSnapshot.Default.DailyDigestHour;

    private void Persist() =>
        _store.Save(new AlertSettingsSnapshot(_costAlertThreshold, _dailyDigestEnabled, _dailyDigestHour));

    private void RaiseAll()
    {
        OnPropertyChanged(nameof(CostAlertThreshold));
        OnPropertyChanged(nameof(CostAlertEnabled));
        OnPropertyChanged(nameof(ThresholdDisplay));
        OnPropertyChanged(nameof(DailyDigestEnabled));
        OnPropertyChanged(nameof(DailyDigestHour));
        OnPropertyChanged(nameof(DailyDigestHourDisplay));
    }
}

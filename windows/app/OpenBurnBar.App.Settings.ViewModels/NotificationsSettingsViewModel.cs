// View-model for the Notifications settings tab.
//
// Faithful port of the Notifications portion of
// AgentLens/Views/Settings/AlertsAndNotificationsViews.swift + the backing
// ControllerSettings store (AgentLens/Services/Settings/Stores/ControllerSettings.swift):
//   controllerLocalNotificationsEnabled   : Bool   = true
//   controllerTelegramEnabled             : Bool   = false
//   controllerTelegramBotToken            : String = ""    (secret)
//   controllerTelegramChatID              : String = ""
//   controllerCalendarIntegrationEnabled  : Bool   = true
//   controllerCalendarDefaultMinutes      : Int    = 30    (load-floor >= 15 else 30; choices 15/30/45/60/90)
//   controllerDefaultSnoozeMinutes        : Int    = 180   (load-floor >= 15 else 180; choices 30/60/90/120/180/240)
//
// The Windows Telegram bridge is live through the protected settings + local Mission
// Control runtime. The EventKit calendar bridge remains N/A on Windows (row 17).

using System.Collections.Generic;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>The seven persisted notification fields (ControllerSettings).</summary>
public sealed record NotificationSettingsSnapshot(
    bool LocalEnabled,
    bool TelegramEnabled,
    string TelegramBotToken,
    string TelegramChatId,
    bool CalendarEnabled,
    int CalendarDefaultMinutes,
    int DefaultSnoozeMinutes)
{
    /// <summary>The macOS defaults.</summary>
    public static readonly NotificationSettingsSnapshot Default = new(
        LocalEnabled: true,
        TelegramEnabled: false,
        TelegramBotToken: string.Empty,
        TelegramChatId: string.Empty,
        CalendarEnabled: true,
        CalendarDefaultMinutes: 30,
        DefaultSnoozeMinutes: 180);
}

/// <summary>Loads + persists the notification settings.</summary>
public interface INotificationSettingsStore
{
    /// <summary>Read the current settings.</summary>
    NotificationSettingsSnapshot Load();

    /// <summary>Persist the settings.</summary>
    void Save(NotificationSettingsSnapshot settings);
}

/// <summary>In-memory notification store (default for tests).</summary>
public sealed class InMemoryNotificationSettingsStore : INotificationSettingsStore
{
    private NotificationSettingsSnapshot _settings;

    public InMemoryNotificationSettingsStore(NotificationSettingsSnapshot? seed = null) =>
        _settings = seed ?? NotificationSettingsSnapshot.Default;

    /// <inheritdoc />
    public NotificationSettingsSnapshot Load() => _settings;

    /// <inheritdoc />
    public void Save(NotificationSettingsSnapshot settings) => _settings = settings;
}

/// <summary>Backs the Notifications tab (local pings, Telegram, calendar reminders).</summary>
public sealed class NotificationsSettingsViewModel : ObservableSettingsViewModel
{
    /// <summary>Reminder-lead minutes floor (Swift <c>stored &gt;= 15 ? stored : default</c>).</summary>
    public const int MinutesFloor = 15;

    private readonly INotificationSettingsStore _store;

    private bool _localEnabled = NotificationSettingsSnapshot.Default.LocalEnabled;
    private bool _telegramEnabled;
    private string _telegramBotToken = string.Empty;
    private string _telegramChatId = string.Empty;
    private bool _calendarEnabled = NotificationSettingsSnapshot.Default.CalendarEnabled;
    private int _calendarDefaultMinutes = NotificationSettingsSnapshot.Default.CalendarDefaultMinutes;
    private int _defaultSnoozeMinutes = NotificationSettingsSnapshot.Default.DefaultSnoozeMinutes;

    public NotificationsSettingsViewModel(INotificationSettingsStore? store = null)
    {
        _store = store ?? new InMemoryNotificationSettingsStore();
        Load();
    }

    /// <summary>Load persisted settings into the view-model (applying the minute floors).</summary>
    public void Load()
    {
        var s = _store.Load();
        _localEnabled = s.LocalEnabled;
        _telegramEnabled = s.TelegramEnabled;
        _telegramBotToken = s.TelegramBotToken;
        _telegramChatId = s.TelegramChatId;
        _calendarEnabled = s.CalendarEnabled;
        _calendarDefaultMinutes = FloorMinutes(s.CalendarDefaultMinutes, NotificationSettingsSnapshot.Default.CalendarDefaultMinutes);
        _defaultSnoozeMinutes = FloorMinutes(s.DefaultSnoozeMinutes, NotificationSettingsSnapshot.Default.DefaultSnoozeMinutes);
        RaiseAll();
    }

    /// <summary>Banner alerts on this device.</summary>
    public bool LocalEnabled
    {
        get => _localEnabled;
        set { if (Set(ref _localEnabled, value)) { Persist(); } }
    }

    /// <summary>Whether Telegram alerts are enabled.</summary>
    public bool TelegramEnabled
    {
        get => _telegramEnabled;
        set
        {
            if (Set(ref _telegramEnabled, value))
            {
                Persist();
                OnPropertyChanged(nameof(ShowTelegramFields));
                OnPropertyChanged(nameof(IsTelegramConfigured));
            }
        }
    }

    /// <summary>Telegram bot token (secret).</summary>
    public string TelegramBotToken
    {
        get => _telegramBotToken;
        set
        {
            if (Set(ref _telegramBotToken, value ?? string.Empty))
            {
                Persist();
                OnPropertyChanged(nameof(IsTelegramConfigured));
            }
        }
    }

    /// <summary>Telegram chat id.</summary>
    public string TelegramChatId
    {
        get => _telegramChatId;
        set
        {
            if (Set(ref _telegramChatId, value ?? string.Empty))
            {
                Persist();
                OnPropertyChanged(nameof(IsTelegramConfigured));
            }
        }
    }

    /// <summary>Whether the Telegram token + chat-id fields should render (only when enabled).</summary>
    public bool ShowTelegramFields => _telegramEnabled;

    /// <summary>Whether Telegram has both a token and a chat id.</summary>
    public bool IsTelegramConfigured =>
        !string.IsNullOrWhiteSpace(_telegramBotToken) && !string.IsNullOrWhiteSpace(_telegramChatId);

    /// <summary>Windows Telegram delivery and commands are live through the local runtime.</summary>
    public string TelegramCapabilityNote =>
        "Telegram delivery and Mission Control commands are live on Windows (WPD-0006 row 16).";

    /// <summary>Whether calendar reminders are enabled.</summary>
    public bool CalendarEnabled
    {
        get => _calendarEnabled;
        set { if (Set(ref _calendarEnabled, value)) { Persist(); } }
    }

    /// <summary>Windows-v1 capability note: EventKit calendar has no Windows analog (WPD-0006 row 17).</summary>
    public string CalendarCapabilityNote =>
        "Calendar reminders have no Windows analog in v1 (WPD-0006 row 17); preferences are saved.";

    /// <summary>Default reminder-lead minutes before an event.</summary>
    public int CalendarDefaultMinutes
    {
        get => _calendarDefaultMinutes;
        set
        {
            var floored = FloorMinutes(value, NotificationSettingsSnapshot.Default.CalendarDefaultMinutes);
            if (Set(ref _calendarDefaultMinutes, floored))
            {
                Persist();
            }
        }
    }

    /// <summary>Default snooze minutes.</summary>
    public int DefaultSnoozeMinutes
    {
        get => _defaultSnoozeMinutes;
        set
        {
            var floored = FloorMinutes(value, NotificationSettingsSnapshot.Default.DefaultSnoozeMinutes);
            if (Set(ref _defaultSnoozeMinutes, floored))
            {
                Persist();
            }
        }
    }

    /// <summary>Reminder-lead choices the picker offers (Swift <c>[15,30,45,60,90]</c>).</summary>
    public IReadOnlyList<int> CalendarMinutesChoices { get; } = new[] { 15, 30, 45, 60, 90 };

    /// <summary>Snooze choices the picker offers (Swift <c>[30,60,90,120,180,240]</c>).</summary>
    public IReadOnlyList<int> SnoozeMinutesChoices { get; } = new[] { 30, 60, 90, 120, 180, 240 };

    private static int FloorMinutes(int value, int fallback) => value >= MinutesFloor ? value : fallback;

    private void Persist() =>
        _store.Save(new NotificationSettingsSnapshot(
            _localEnabled,
            _telegramEnabled,
            _telegramBotToken,
            _telegramChatId,
            _calendarEnabled,
            _calendarDefaultMinutes,
            _defaultSnoozeMinutes));

    private void RaiseAll()
    {
        OnPropertyChanged(nameof(LocalEnabled));
        OnPropertyChanged(nameof(TelegramEnabled));
        OnPropertyChanged(nameof(TelegramBotToken));
        OnPropertyChanged(nameof(TelegramChatId));
        OnPropertyChanged(nameof(ShowTelegramFields));
        OnPropertyChanged(nameof(IsTelegramConfigured));
        OnPropertyChanged(nameof(CalendarEnabled));
        OnPropertyChanged(nameof(CalendarDefaultMinutes));
        OnPropertyChanged(nameof(DefaultSnoozeMinutes));
    }
}

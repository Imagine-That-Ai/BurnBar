// View-model for the Cloud settings tab.
//
// Faithful port of AgentLens/Views/Settings/CloudStoreSettingsView.swift + the backing
// CloudSyncSettings store:
//   conversationBackupEnabled          : Bool = false  (SET writes sessionLog + conversation;
//                                                        also flips sessionLogCloudBackupConsentShown)
//   iCloudSessionMirrorEnabled         : Bool = false
//   chatThreadContentCloudBackupEnabled: Bool = false  (enabling flips chatThread...ConsentShown)
//   sessionLogCloudBackupConsentShown  : Bool = false
//   chatThreadContentCloudBackupConsentShown : Bool = false
// The sub-toggles only render when conversation backup is on. "Back up now" requires a
// signed-in session (data-gated on #1304 OAuth, Wave 2).

using System;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>The persisted cloud-backup fields (CloudSyncSettings subset).</summary>
public sealed record CloudSettingsSnapshot(
    bool ConversationBackupEnabled,
    bool ICloudMirrorEnabled,
    bool ChatThreadBackupEnabled,
    bool SessionLogConsentShown,
    bool ChatThreadConsentShown)
{
    /// <summary>The macOS defaults (all backup off, no consent shown yet).</summary>
    public static readonly CloudSettingsSnapshot Default = new(
        ConversationBackupEnabled: false,
        ICloudMirrorEnabled: false,
        ChatThreadBackupEnabled: false,
        SessionLogConsentShown: false,
        ChatThreadConsentShown: false);
}

/// <summary>Loads + persists the cloud-backup settings.</summary>
public interface ICloudSettingsStore
{
    CloudSettingsSnapshot Load();

    void Save(CloudSettingsSnapshot settings);
}

/// <summary>In-memory cloud store (default for tests).</summary>
public sealed class InMemoryCloudSettingsStore : ICloudSettingsStore
{
    private CloudSettingsSnapshot _settings;

    public InMemoryCloudSettingsStore(CloudSettingsSnapshot? seed = null) =>
        _settings = seed ?? CloudSettingsSnapshot.Default;

    public CloudSettingsSnapshot Load() => _settings;

    public void Save(CloudSettingsSnapshot settings) => _settings = settings;
}

/// <summary>Kicks off an immediate cloud backup (WinUI: CloudSyncCoordinator). Data/OS-bound.</summary>
public interface ICloudBackupHost
{
    /// <summary>Upload any pending items now. Returns whether the upload was started.</summary>
    bool TriggerBackup();
}

/// <summary>A recording backup host (default for tests).</summary>
public sealed class RecordingCloudBackupHost : ICloudBackupHost
{
    public int TriggerCount { get; private set; }

    public bool TriggerBackup()
    {
        TriggerCount++;
        return true;
    }
}

/// <summary>Backs the Cloud tab (OpenBurnBar Cloud hosted refresh + backup).</summary>
public sealed class CloudSettingsViewModel : ObservableSettingsViewModel
{
    private readonly ICloudSettingsStore _store;
    private readonly IAccountSessionGate _session;
    private readonly ICloudBackupHost _backupHost;

    private bool _conversationBackupEnabled;
    private bool _iCloudMirrorEnabled;
    private bool _chatThreadBackupEnabled;
    private bool _sessionLogConsentShown;
    private bool _chatThreadConsentShown;

    public CloudSettingsViewModel(
        ICloudSettingsStore? store = null,
        IAccountSessionGate? session = null,
        ICloudBackupHost? backupHost = null)
    {
        _store = store ?? new InMemoryCloudSettingsStore();
        _session = session ?? FakeAccountSessionGate.SignedOut;
        _backupHost = backupHost ?? new RecordingCloudBackupHost();
        Load();
    }

    /// <summary>Load persisted settings.</summary>
    public void Load()
    {
        var s = _store.Load();
        _conversationBackupEnabled = s.ConversationBackupEnabled;
        _iCloudMirrorEnabled = s.ICloudMirrorEnabled;
        _chatThreadBackupEnabled = s.ChatThreadBackupEnabled;
        _sessionLogConsentShown = s.SessionLogConsentShown;
        _chatThreadConsentShown = s.ChatThreadConsentShown;
        RaiseAll();
    }

    /// <summary>Whether a session is signed in (gates "Back up now").</summary>
    public bool IsSignedIn => _session.IsSignedIn;

    /// <summary>Master conversation-backup toggle (writes both session-log + conversation flags).</summary>
    public bool ConversationBackupEnabled
    {
        get => _conversationBackupEnabled;
        set
        {
            if (Set(ref _conversationBackupEnabled, value))
            {
                // Swift backupBinding: any change flips the consent-shown flag.
                _sessionLogConsentShown = true;
                Persist();
                OnPropertyChanged(nameof(ShowSubToggles));
                OnPropertyChanged(nameof(SessionLogConsentShown));
                OnPropertyChanged(nameof(CanTriggerBackup));
            }
        }
    }

    /// <summary>Mirror sessions to iCloud (macOS-specific pref; retained for parity).</summary>
    public bool ICloudMirrorEnabled
    {
        get => _iCloudMirrorEnabled;
        set { if (Set(ref _iCloudMirrorEnabled, value)) { Persist(); } }
    }

    /// <summary>Back up chat-thread content (enabling flips its consent flag).</summary>
    public bool ChatThreadBackupEnabled
    {
        get => _chatThreadBackupEnabled;
        set
        {
            if (Set(ref _chatThreadBackupEnabled, value))
            {
                if (value)
                {
                    _chatThreadConsentShown = true;
                    OnPropertyChanged(nameof(ChatThreadConsentShown));
                }

                Persist();
            }
        }
    }

    /// <summary>Whether the session-log backup consent has been shown.</summary>
    public bool SessionLogConsentShown => _sessionLogConsentShown;

    /// <summary>Whether the chat-thread backup consent has been shown.</summary>
    public bool ChatThreadConsentShown => _chatThreadConsentShown;

    /// <summary>The sub-toggles only render once the master backup toggle is on.</summary>
    public bool ShowSubToggles => _conversationBackupEnabled;

    /// <summary>Whether "Back up now" is available (signed in + backup enabled).</summary>
    public bool CanTriggerBackup => _session.IsSignedIn && _conversationBackupEnabled;

    /// <summary>Trigger an immediate backup. Returns false when not available.</summary>
    public bool TriggerBackup()
    {
        if (!CanTriggerBackup)
        {
            return false;
        }

        return _backupHost.TriggerBackup();
    }

    private void Persist() =>
        _store.Save(new CloudSettingsSnapshot(
            _conversationBackupEnabled,
            _iCloudMirrorEnabled,
            _chatThreadBackupEnabled,
            _sessionLogConsentShown,
            _chatThreadConsentShown));

    private void RaiseAll()
    {
        OnPropertyChanged(nameof(IsSignedIn));
        OnPropertyChanged(nameof(ConversationBackupEnabled));
        OnPropertyChanged(nameof(ICloudMirrorEnabled));
        OnPropertyChanged(nameof(ChatThreadBackupEnabled));
        OnPropertyChanged(nameof(SessionLogConsentShown));
        OnPropertyChanged(nameof(ChatThreadConsentShown));
        OnPropertyChanged(nameof(ShowSubToggles));
        OnPropertyChanged(nameof(CanTriggerBackup));
    }
}

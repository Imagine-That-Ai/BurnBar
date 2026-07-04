using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Presentation.Switcher;

// PORTED (faithful) from the state machine in
// AgentLens/Views/Settings/AccountSwitcherSettingsView.swift +
// AccountSwitcherSettingsView+DataOperations.swift +
// AccountSwitcherSettingsView+Rendering.swift (grouping/mode filter).
//
// This is the view-model behind the WinUI account-switcher surface: it owns the profile
// list, the resolved active selection, the per-provider drain targets, the grouped
// sections, and every mutation (create / save / delete / set-active / make-primary /
// reorder / swap / toggle-paused / set-drain-target). The store is injected, so the whole
// machine runs against the in-memory store under `dotnet test` on macOS — the platform
// discovery/quota/auth side effects are the only Windows-deferred parts.

/// <summary>Which slice of the switcher a host renders. Swift: <c>AccountSwitcherSettingsView.Mode</c>.</summary>
public enum SwitcherViewMode
{
    All,
    CliOnly,
    BrowserOnly,
}

/// <summary>View-model backing the Windows account-switcher surface.</summary>
public sealed class SwitcherSettingsViewModel : INotifyPropertyChanged
{
    private readonly ISwitcherProfileStore _store;
    private readonly Func<DateTimeOffset> _now;
    private readonly Func<string> _idFactory;
    private readonly Func<SwitcherProfileRecord, bool> _isConnected;

    private IReadOnlyList<SwitcherProfileRecord> _profiles = Array.Empty<SwitcherProfileRecord>();
    private IReadOnlyList<ProfileGroup> _allGroups = Array.Empty<ProfileGroup>();
    private Dictionary<string, string> _drainTargets = new(StringComparer.Ordinal);
    private string? _activeProfileId;
    private string? _errorMessage;
    private SwitcherViewMode _mode = SwitcherViewMode.All;

    public SwitcherSettingsViewModel(
        ISwitcherProfileStore store,
        Func<DateTimeOffset>? now = null,
        Func<string>? idFactory = null,
        Func<SwitcherProfileRecord, bool>? isConnected = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _idFactory = idFactory ?? (() => Guid.NewGuid().ToString());
        _isConnected = isConnected ?? SwitcherProfileGrouping.DefaultIsConnected;
    }

    /// <summary>Provider sections for the visible <see cref="Mode"/>. Bound by the list.</summary>
    public ObservableCollection<ProfileGroup> Groups { get; } = new();

    /// <summary>CLI provider sections (group + rows) the WinUI list x:Binds. Swift: <c>cliProfileGroups</c>.</summary>
    public ObservableCollection<SwitcherGroupViewModel> CliSections { get; } = new();

    /// <summary>Browser provider sections (group + rows). Swift: <c>browserProfileGroups</c>.</summary>
    public ObservableCollection<SwitcherGroupViewModel> BrowserSections { get; } = new();

    public IReadOnlyList<SwitcherProfileRecord> Profiles => _profiles;

    public IReadOnlyList<ProfileGroup> AllGroups => _allGroups;

    public IReadOnlyList<ProfileGroup> CliGroups => SwitcherProfileGrouping.CliGroups(_allGroups);

    public IReadOnlyList<ProfileGroup> BrowserGroups => SwitcherProfileGrouping.BrowserGroups(_allGroups);

    public string? ActiveProfileId
    {
        get => _activeProfileId;
        private set { if (Set(ref _activeProfileId, value)) { OnPropertyChanged(nameof(HasActiveProfile)); } }
    }

    public bool HasActiveProfile => _activeProfileId is not null;

    public IReadOnlyDictionary<string, string> DrainTargets => _drainTargets;

    public string? ErrorMessage
    {
        get => _errorMessage;
        private set { if (Set(ref _errorMessage, value)) { OnPropertyChanged(nameof(HasError)); } }
    }

    /// <summary>Whether an error banner should render.</summary>
    public bool HasError => _errorMessage is not null;

    public int ProfileCount => _profiles.Count;

    /// <summary>Header count line. Swift: <c>"\(profiles.count) Account\(...)"</c>.</summary>
    public string CountLabel => $"{ProfileCount} Account{(ProfileCount == 1 ? string.Empty : "s")}";

    public SwitcherViewMode Mode
    {
        get => _mode;
        set { if (Set(ref _mode, value)) { RebuildVisibleGroups(); } }
    }

    /// <summary>Clear any surfaced error banner.</summary>
    public void ClearError() => ErrorMessage = null;

    /// <summary>
    /// Load profiles, resolve the active selection, and rebuild the grouped sections. Swift:
    /// <c>loadProfiles()</c> minus the platform enrichment (Chrome/CLI discovery) which the
    /// Windows host injects via <c>isConnected</c>.
    /// </summary>
    public void Load()
    {
        _profiles = _store.FetchAllProfiles();
        var state = _store.FetchActiveProfileState();
        ActiveProfileId = ResolveActiveProfileId(state, _profiles);
        _drainTargets = new Dictionary<string, string>(_store.FetchAllActiveDrainTargets(), StringComparer.Ordinal);
        OnPropertyChanged(nameof(DrainTargets));
        RebuildGroups();
        OnPropertyChanged(nameof(Profiles));
        OnPropertyChanged(nameof(ProfileCount));
        OnPropertyChanged(nameof(CountLabel));
    }

    /// <summary>
    /// Keep the active selection valid. Swift: <c>resolvedActiveProfileID(from:profiles:)</c> —
    /// keep the stored active id if it maps to an enabled profile, else the first enabled one.
    /// </summary>
    public static string? ResolveActiveProfileId(
        SwitcherActiveProfileState state,
        IReadOnlyList<SwitcherProfileRecord> profiles)
    {
        if (state.ActiveProfileId is { } id &&
            profiles.Any(p => p.Id == id && !p.IsDisabled))
        {
            return id;
        }

        return profiles.FirstOrDefault(p => !p.IsDisabled)?.Id;
    }

    /// <summary>Rows for a group with the current active selection + clock. Swift: the ForEach row build.</summary>
    public IReadOnlyList<SwitcherProfileRowViewModel> RowsFor(ProfileGroup group) =>
        SwitcherProfileRowViewModel.ForGroup(group, _activeProfileId, _now());

    /// <summary>
    /// Create a profile from the form. Swift: <c>createProfileAsync()</c> — validate (against
    /// ALL names), persist, and if this is the first profile establish it as active.
    /// </summary>
    public SwitcherFormValidationResult CreateProfile(SwitcherProfileForm form)
    {
        var result = form.Validate(_profiles.Select(p => p.DisplayName));
        if (!result.IsValid)
        {
            return result;
        }

        bool wasEmpty = _profiles.Count == 0;
        var record = form.BuildNewRecord(_idFactory(), _now());
        var created = _store.Create(record);
        if (wasEmpty)
        {
            _store.SetActiveProfile(created.Id);
        }

        Load();
        return SwitcherFormValidationResult.Valid;
    }

    /// <summary>
    /// Save edits to an existing profile. Swift: <c>saveProfileAsync(original:)</c> — validate
    /// (excluding the edited id) then persist a record that preserves untouched fields.
    /// </summary>
    public SwitcherFormValidationResult SaveProfile(SwitcherProfileRecord original, SwitcherProfileForm form)
    {
        var result = form.Validate(_profiles.Where(p => p.Id != original.Id).Select(p => p.DisplayName));
        if (!result.IsValid)
        {
            return result;
        }

        _store.Update(form.BuildUpdatedRecord(original, _now()));
        Load();
        return SwitcherFormValidationResult.Valid;
    }

    /// <summary>Delete a profile. Swift: <c>deleteProfile(_:)</c> (store picks the active fallback on reload).</summary>
    public void DeleteProfile(SwitcherProfileRecord profile)
    {
        _store.DeleteProfile(profile.Id);
        Load();
    }

    /// <summary>Set the global active profile. Swift: <c>setActiveProfile(_:)</c>.</summary>
    public void SetActiveProfile(SwitcherProfileRecord profile)
    {
        _store.SetActiveProfile(profile.Id);
        ActiveProfileId = profile.Id;
        RebuildSections();
    }

    /// <summary>
    /// Promote a profile to the drain target for its provider, leaving other providers alone.
    /// Swift: <c>setDrainTarget(_:provider:)</c>.
    /// </summary>
    public void SetDrainTarget(SwitcherProfileRecord profile, SwitcherCLIProfileType provider)
    {
        string key = provider.ProviderKey();
        if (_drainTargets.TryGetValue(key, out var existing) && existing == profile.Id)
        {
            return;
        }

        _store.SetActiveProfile(profile.Id, key);
        _drainTargets[key] = profile.Id;
        OnPropertyChanged(nameof(DrainTargets));
    }

    /// <summary>
    /// Pause / resume a profile. Swift: <c>toggleDisabled(_:in:)</c> — refuses to pause the last
    /// enabled account in a group, and reassigns the global active profile if the paused one held it.
    /// </summary>
    public void ToggleDisabled(SwitcherProfileRecord profile, ProfileGroup group)
    {
        bool nextDisabled = !profile.IsDisabled;
        if (nextDisabled && group.EnabledCount <= 1)
        {
            ErrorMessage = $"Keep at least one {group.Label} account enabled.";
            return;
        }

        _store.Update(WithDisabledState(profile, nextDisabled));

        if (nextDisabled && _activeProfileId == profile.Id)
        {
            var fallback = _profiles.FirstOrDefault(p => p.Id != profile.Id && !p.IsDisabled)?.Id;
            _store.SetActiveProfile(fallback);
        }

        Load();
    }

    /// <summary>Move a profile to the front of its group. Swift: <c>makePrimary(_:in:)</c>.</summary>
    public void MakePrimary(SwitcherProfileRecord profile, ProfileGroup group)
    {
        if (group.Profiles.Count == 0 || group.Profiles[0].Profile.Id == profile.Id)
        {
            return;
        }

        ReorderWithinGroup(profile.Id, group, targetIndex: 0);
    }

    /// <summary>Swap a profile with the other slot (primary ↔ first reserve). Swift: <c>swapProfileWithinGroup(_:in:)</c>.</summary>
    public void SwapWithinGroup(SwitcherProfileRecord profile, ProfileGroup group)
    {
        var groupProfiles = group.Profiles.Select(p => p.Profile).ToList();
        if (groupProfiles.Count <= 1)
        {
            return;
        }

        int sourceIndex = groupProfiles.FindIndex(p => p.Id == profile.Id);
        if (sourceIndex < 0)
        {
            return;
        }

        int targetIndex = sourceIndex == 0 ? 1 : 0;
        if (targetIndex < 0 || targetIndex >= groupProfiles.Count)
        {
            return;
        }

        PersistGroupOrder(group, current =>
        {
            var next = current.ToList();
            (next[sourceIndex], next[targetIndex]) = (next[targetIndex], next[sourceIndex]);
            return next;
        });
    }

    /// <summary>Nudge a profile up/down within its group. Swift: <c>moveProfileWithinGroup(_:in:direction:)</c>.</summary>
    public void MoveWithinGroup(SwitcherProfileRecord profile, ProfileGroup group, bool moveUp)
    {
        int currentIndex = -1;
        for (int i = 0; i < group.Profiles.Count; i++)
        {
            if (group.Profiles[i].Profile.Id == profile.Id)
            {
                currentIndex = i;
                break;
            }
        }

        if (currentIndex < 0)
        {
            return;
        }

        int targetIndex = moveUp ? currentIndex - 1 : currentIndex + 1;
        if (targetIndex < 0 || targetIndex >= group.Profiles.Count)
        {
            return;
        }

        ReorderWithinGroup(profile.Id, group, targetIndex);
    }

    // Swift: reorderWithinGroup(movingProfileID:in:targetIndex:)
    private void ReorderWithinGroup(string movingProfileId, ProfileGroup group, int targetIndex)
    {
        PersistGroupOrder(group, current =>
        {
            var next = current.ToList();
            int sourceIndex = next.FindIndex(p => p.Id == movingProfileId);
            if (sourceIndex < 0 || targetIndex < 0 || targetIndex >= next.Count)
            {
                return current;
            }

            var moved = next[sourceIndex];
            next.RemoveAt(sourceIndex);
            next.Insert(targetIndex, moved);
            return next;
        });
    }

    // Swift: persistGroupOrder(replacing:in:transform:) — reorder the group members in place
    // inside the full ordered list, then persist the whole order.
    private void PersistGroupOrder(
        ProfileGroup group,
        Func<IReadOnlyList<SwitcherProfileRecord>, IReadOnlyList<SwitcherProfileRecord>> transform)
    {
        var full = _profiles.ToList();
        var groupIds = new HashSet<string>(group.Profiles.Select(p => p.Profile.Id), StringComparer.Ordinal);
        var currentGroupOrder = full.Where(p => groupIds.Contains(p.Id)).ToList();
        var updatedGroupOrder = transform(currentGroupOrder).ToList();

        if (updatedGroupOrder.Select(p => p.Id).SequenceEqual(currentGroupOrder.Select(p => p.Id)))
        {
            return;
        }

        var queue = new Queue<SwitcherProfileRecord>(updatedGroupOrder);
        for (int i = 0; i < full.Count; i++)
        {
            if (groupIds.Contains(full[i].Id) && queue.Count > 0)
            {
                full[i] = queue.Dequeue();
            }
        }

        _store.ReorderProfiles(full.Select(p => p.Id).ToList());
        Load();
    }

    // Swift: profileWithDisabledState(_:isDisabled:)
    private static SwitcherProfileRecord WithDisabledState(SwitcherProfileRecord profile, bool isDisabled)
    {
        if (profile.TargetKind == SwitcherProfileTargetKind.Browser)
        {
            var meta = profile.BrowserMetadata ?? new SwitcherBrowserProfileMetadata("Default");
            return profile with { BrowserMetadata = meta with { IsDisabled = isDisabled } };
        }

        var cli = profile.CliMetadata ?? new SwitcherCLIProfileMetadata();
        return profile with { CliMetadata = cli with { IsDisabled = isDisabled } };
    }

    private void RebuildGroups()
    {
        _allGroups = SwitcherProfileGrouping.ComputeGroups(_profiles, _isConnected);
        OnPropertyChanged(nameof(AllGroups));
        OnPropertyChanged(nameof(CliGroups));
        OnPropertyChanged(nameof(BrowserGroups));
        RebuildVisibleGroups();
        RebuildSections();
    }

    private void RebuildSections()
    {
        var now = _now();

        CliSections.Clear();
        foreach (var group in SwitcherProfileGrouping.CliGroups(_allGroups))
        {
            CliSections.Add(SwitcherGroupViewModel.ForGroup(group, _activeProfileId, now));
        }

        BrowserSections.Clear();
        foreach (var group in SwitcherProfileGrouping.BrowserGroups(_allGroups))
        {
            BrowserSections.Add(SwitcherGroupViewModel.ForGroup(group, _activeProfileId, now));
        }
    }

    private void RebuildVisibleGroups()
    {
        var visible = _mode switch
        {
            SwitcherViewMode.CliOnly => _allGroups.Where(g => g.IsCli),
            SwitcherViewMode.BrowserOnly => _allGroups.Where(g => g.IsBrowser),
            _ => _allGroups,
        };

        Groups.Clear();
        foreach (var group in visible)
        {
            Groups.Add(group);
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(name);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

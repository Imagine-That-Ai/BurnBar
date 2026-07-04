using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Switcher;

// PORTED (seam) from the store surface the macOS switcher drives:
//   AgentLens/Views/Settings/AccountSwitcher/AccountSwitcherSupport.swift (SettingsSwitcherProfileAdapter)
//   + the SwitcherProfileStore calls in AccountSwitcherSettingsView+DataOperations.swift
//     (fetchAllProfiles / validateAndRecoverActiveProfile / setActiveProfile /
//      fetchAllActiveDrainTargets / create / update / deleteProfile / reorderProfiles /
//      existsProfileWithNormalizedName).
//
// The WinUI app backs this with the encrypted Windows profile store (lands with the
// storage seam); the tests + the view-model back it with the in-memory implementation
// below. Both obey the same contract, so the view-model logic is proven on macOS.

/// <summary>Persistence contract for switcher profiles + active-selection state.</summary>
public interface ISwitcherProfileStore
{
    /// <summary>All profiles in stable (sortKey, createdAt) order. Swift: <c>fetchAllProfiles()</c>.</summary>
    IReadOnlyList<SwitcherProfileRecord> FetchAllProfiles();

    /// <summary>Global active-profile selection. Swift: <c>fetchActiveProfileState()</c>.</summary>
    SwitcherActiveProfileState FetchActiveProfileState();

    /// <summary>Set (or clear) the global active profile. Swift: <c>setActiveProfile(_:)</c>.</summary>
    void SetActiveProfile(string? profileId);

    /// <summary>Per-provider drain targets: providerKey → profileId. Swift: <c>fetchAllActiveDrainTargets()</c>.</summary>
    IReadOnlyDictionary<string, string> FetchAllActiveDrainTargets();

    /// <summary>Active profile for a provider drain key. Swift: <c>fetchActiveProfileID(for:)</c>.</summary>
    string? FetchActiveProfileId(string providerKey);

    /// <summary>Set the drain target for a provider key. Swift: <c>setActiveProfile(_:for:)</c>.</summary>
    void SetActiveProfile(string? profileId, string providerKey);

    /// <summary>Insert a new profile (assigned the next sort position). Swift: <c>create(_:)</c>.</summary>
    SwitcherProfileRecord Create(SwitcherProfileRecord record);

    /// <summary>Replace an existing profile by id. Swift: <c>update(_:)</c>.</summary>
    SwitcherProfileRecord Update(SwitcherProfileRecord record);

    /// <summary>Delete a profile by id. Swift: <c>deleteProfile(id:)</c>.</summary>
    void DeleteProfile(string id);

    /// <summary>Reorder the whole list to match <paramref name="idsInOrder"/>. Swift: <c>reorderProfiles(idsInOrder:)</c>.</summary>
    void ReorderProfiles(IReadOnlyList<string> idsInOrder);

    /// <summary>Normalized-name existence check. Swift: <c>existsProfileWithNormalizedName(_:excludingID:)</c>.</summary>
    bool ExistsProfileWithNormalizedName(string name, string? excludingId);
}

/// <summary>
/// In-memory <see cref="ISwitcherProfileStore"/>. Maintains explicit list order (== sort
/// order) so reorder/make-primary behave exactly as the SQLite store's sortKey does. Used
/// by the view-model in tests and as a dev fixture.
/// </summary>
public sealed class InMemorySwitcherProfileStore : ISwitcherProfileStore
{
    private readonly List<SwitcherProfileRecord> _profiles = new();
    private readonly Dictionary<string, string> _drainTargets = new(StringComparer.Ordinal);
    private readonly Func<DateTimeOffset> _now;
    private string? _activeProfileId;
    private DateTimeOffset _activeUpdatedAt;

    public InMemorySwitcherProfileStore(
        IEnumerable<SwitcherProfileRecord>? seed = null,
        string? activeProfileId = null,
        Func<DateTimeOffset>? now = null)
    {
        _now = now ?? (() => DateTimeOffset.UtcNow);
        if (seed is not null)
        {
            foreach (var record in seed)
            {
                _profiles.Add(record);
            }
        }

        _activeProfileId = activeProfileId;
        _activeUpdatedAt = _now();
    }

    public IReadOnlyList<SwitcherProfileRecord> FetchAllProfiles() =>
        _profiles
            .Select((record, index) => record with { SortKey = index })
            .ToList();

    public SwitcherActiveProfileState FetchActiveProfileState() =>
        new(_activeProfileId, _activeUpdatedAt);

    public void SetActiveProfile(string? profileId)
    {
        _activeProfileId = profileId;
        _activeUpdatedAt = _now();
    }

    public IReadOnlyDictionary<string, string> FetchAllActiveDrainTargets() =>
        new Dictionary<string, string>(_drainTargets, StringComparer.Ordinal);

    public string? FetchActiveProfileId(string providerKey) =>
        _drainTargets.TryGetValue(providerKey, out var id) ? id : null;

    public void SetActiveProfile(string? profileId, string providerKey)
    {
        if (profileId is null)
        {
            _drainTargets.Remove(providerKey);
        }
        else
        {
            _drainTargets[providerKey] = profileId;
        }
    }

    public SwitcherProfileRecord Create(SwitcherProfileRecord record)
    {
        var now = _now();
        var stored = record with
        {
            SortKey = _profiles.Count,
            CreatedAt = record.CreatedAt == default ? now : record.CreatedAt,
            UpdatedAt = now,
        };
        _profiles.Add(stored);
        return stored;
    }

    public SwitcherProfileRecord Update(SwitcherProfileRecord record)
    {
        var index = _profiles.FindIndex(p => p.Id == record.Id);
        if (index < 0)
        {
            throw new InvalidOperationException($"No switcher profile with id '{record.Id}'.");
        }

        var stored = record with { UpdatedAt = _now() };
        _profiles[index] = stored;
        return stored;
    }

    public void DeleteProfile(string id)
    {
        _profiles.RemoveAll(p => p.Id == id);
        if (_activeProfileId == id)
        {
            _activeProfileId = null;
            _activeUpdatedAt = _now();
        }

        foreach (var key in _drainTargets.Where(kv => kv.Value == id).Select(kv => kv.Key).ToList())
        {
            _drainTargets.Remove(key);
        }
    }

    public void ReorderProfiles(IReadOnlyList<string> idsInOrder)
    {
        var byId = _profiles.ToDictionary(p => p.Id, StringComparer.Ordinal);
        var reordered = new List<SwitcherProfileRecord>(_profiles.Count);
        foreach (var id in idsInOrder)
        {
            if (byId.TryGetValue(id, out var record))
            {
                reordered.Add(record);
                byId.Remove(id);
            }
        }

        // Any ids not named keep their relative order at the tail.
        foreach (var record in _profiles.Where(p => byId.ContainsKey(p.Id)))
        {
            reordered.Add(record);
        }

        _profiles.Clear();
        _profiles.AddRange(reordered);
    }

    public bool ExistsProfileWithNormalizedName(string name, string? excludingId)
    {
        var normalized = SwitcherProfileRecord.NormalizeName(name);
        return _profiles.Any(p =>
            p.Id != excludingId &&
            SwitcherProfileRecord.NormalizeName(p.DisplayName) == normalized);
    }
}

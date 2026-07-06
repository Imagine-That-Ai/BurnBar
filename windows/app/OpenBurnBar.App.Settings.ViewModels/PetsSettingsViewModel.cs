// View-model for the Pets settings tab.
//
// Faithful port of the inline PetCompanionSettingsView in
// AgentLens/Views/Settings/SettingsView.swift + PetCompanionFeature's DefaultsKeys:
//   pet.companionEnabled  : Bool   = false
//   pet.activePetID       : String = "claudecode"   (defaultPetID)
//   pet.activeAgent       : String = "codex"        (ChatBackendID.codex)
//   pet.personaVoiceEnabled : Bool = true
// The activePetID resolves to the persisted id when it exists in the catalog, else the
// default; the active agent resolves to the persisted id when available, else the first.
//
// The desktop companion is driven on Windows by OpenBurnBar.App.Pet's
// PetCompanionController (Summon / ReleaseSummon); this view-model reaches it through the
// IPetCompanionHost seam so it stays testable without the WebView2 scene.

using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>A selectable desktop pet (id + display name).</summary>
public sealed record PetChoice(string Id, string DisplayName);

/// <summary>A selectable answering agent (id + display name).</summary>
public sealed record PetAgentChoice(string Id, string DisplayName);

/// <summary>The four persisted pet fields.</summary>
public sealed record PetSettingsSnapshot(
    bool Enabled,
    string ActivePetId,
    string ActiveAgent,
    bool PersonaVoiceEnabled)
{
    /// <summary>The default pet id (Swift <c>defaultPetID</c>).</summary>
    public const string DefaultPetId = "claudecode";

    /// <summary>The default answering agent (Swift <c>ChatBackendID.codex</c>).</summary>
    public const string DefaultAgentId = "codex";

    /// <summary>The macOS defaults.</summary>
    public static readonly PetSettingsSnapshot Default = new(
        Enabled: false,
        ActivePetId: DefaultPetId,
        ActiveAgent: DefaultAgentId,
        PersonaVoiceEnabled: true);
}

/// <summary>Loads + persists the pet settings.</summary>
public interface IPetSettingsStore
{
    /// <summary>Read the current settings.</summary>
    PetSettingsSnapshot Load();

    /// <summary>Persist the settings.</summary>
    void Save(PetSettingsSnapshot settings);
}

/// <summary>In-memory pet store (default for tests).</summary>
public sealed class InMemoryPetSettingsStore : IPetSettingsStore
{
    private PetSettingsSnapshot _settings;

    public InMemoryPetSettingsStore(PetSettingsSnapshot? seed = null) =>
        _settings = seed ?? PetSettingsSnapshot.Default;

    /// <inheritdoc />
    public PetSettingsSnapshot Load() => _settings;

    /// <inheritdoc />
    public void Save(PetSettingsSnapshot settings) => _settings = settings;
}

/// <summary>Drives the live desktop companion (WinUI: PetCompanionController). OS/scene-bound.</summary>
public interface IPetCompanionHost
{
    /// <summary>Show the desktop companion.</summary>
    void ShowCompanion();

    /// <summary>Hide the desktop companion.</summary>
    void HideCompanion();

    /// <summary>Summon the companion to the cursor / open its bubble.</summary>
    void Summon();

    /// <summary>Switch the displayed pet form.</summary>
    void SelectPet(string petId);

    /// <summary>Switch the answering agent backend.</summary>
    void SwitchAgent(string agentId);
}

/// <summary>A no-op companion host that records the last commands (default for tests).</summary>
public sealed class RecordingPetCompanionHost : IPetCompanionHost
{
    public int ShowCount { get; private set; }
    public int HideCount { get; private set; }
    public int SummonCount { get; private set; }
    public string? LastSelectedPet { get; private set; }
    public string? LastSwitchedAgent { get; private set; }

    public void ShowCompanion() => ShowCount++;

    public void HideCompanion() => HideCount++;

    public void Summon() => SummonCount++;

    public void SelectPet(string petId) => LastSelectedPet = petId;

    public void SwitchAgent(string agentId) => LastSwitchedAgent = agentId;
}

/// <summary>Backs the Pets tab (companion visibility, pet picker, agent brain, summon).</summary>
public sealed class PetsSettingsViewModel : ObservableSettingsViewModel
{
    private readonly IPetSettingsStore _store;
    private readonly IPetCompanionHost _host;

    private bool _enabled;
    private string _activePetId = PetSettingsSnapshot.DefaultPetId;
    private string _activeAgent = PetSettingsSnapshot.DefaultAgentId;
    private bool _personaVoiceEnabled = true;

    public PetsSettingsViewModel(
        IReadOnlyList<PetChoice>? availablePets = null,
        IReadOnlyList<PetAgentChoice>? availableAgents = null,
        IPetSettingsStore? store = null,
        IPetCompanionHost? host = null)
    {
        AvailablePets = availablePets ?? new[] { new PetChoice(PetSettingsSnapshot.DefaultPetId, "Claude Code") };
        AvailableAgents = availableAgents ?? new[] { new PetAgentChoice(PetSettingsSnapshot.DefaultAgentId, "Codex") };
        _store = store ?? new InMemoryPetSettingsStore();
        _host = host ?? new RecordingPetCompanionHost();
        Load();
    }

    /// <summary>The pets the picker offers.</summary>
    public IReadOnlyList<PetChoice> AvailablePets { get; }

    /// <summary>The answering agents the switcher offers.</summary>
    public IReadOnlyList<PetAgentChoice> AvailableAgents { get; }

    /// <summary>Load persisted settings, resolving the active pet + agent against the catalogs.</summary>
    public void Load()
    {
        var s = _store.Load();
        _enabled = s.Enabled;
        _activePetId = ResolvePetId(s.ActivePetId);
        _activeAgent = ResolveAgentId(s.ActiveAgent);
        _personaVoiceEnabled = s.PersonaVoiceEnabled;
        RaiseAll();
    }

    /// <summary>Whether the desktop pet is shown.</summary>
    public bool Enabled
    {
        get => _enabled;
        set
        {
            if (Set(ref _enabled, value))
            {
                Persist();
                if (value)
                {
                    _host.ShowCompanion();
                }
                else
                {
                    _host.HideCompanion();
                }
            }
        }
    }

    /// <summary>The active pet id (always resolves to a catalog entry).</summary>
    public string ActivePetId
    {
        get => _activePetId;
        set
        {
            var resolved = ResolvePetId(value);
            if (Set(ref _activePetId, resolved))
            {
                Persist();
                _host.SelectPet(resolved);
            }
        }
    }

    /// <summary>The active answering agent id (always resolves to an available agent).</summary>
    public string ActiveAgent
    {
        get => _activeAgent;
        set
        {
            var resolved = ResolveAgentId(value);
            if (Set(ref _activeAgent, resolved))
            {
                Persist();
                _host.SwitchAgent(resolved);
            }
        }
    }

    /// <summary>Whether the pet's persona voice is enabled.</summary>
    public bool PersonaVoiceEnabled
    {
        get => _personaVoiceEnabled;
        set { if (Set(ref _personaVoiceEnabled, value)) { Persist(); } }
    }

    /// <summary>Summon the companion (Swift Summon button): show it and open its bubble.</summary>
    public void Summon()
    {
        Enabled = true;
        _host.Summon();
    }

    /// <summary>Hide the companion (Swift Hide button).</summary>
    public void Hide() => Enabled = false;

    private string ResolvePetId(string candidate)
    {
        if (AvailablePets.Any(p => p.Id == candidate))
        {
            return candidate;
        }

        return AvailablePets.Any(p => p.Id == PetSettingsSnapshot.DefaultPetId)
            ? PetSettingsSnapshot.DefaultPetId
            : AvailablePets.FirstOrDefault()?.Id ?? PetSettingsSnapshot.DefaultPetId;
    }

    private string ResolveAgentId(string candidate) =>
        AvailableAgents.Any(a => a.Id == candidate)
            ? candidate
            : AvailableAgents.FirstOrDefault()?.Id ?? PetSettingsSnapshot.DefaultAgentId;

    private void Persist() =>
        _store.Save(new PetSettingsSnapshot(_enabled, _activePetId, _activeAgent, _personaVoiceEnabled));

    private void RaiseAll()
    {
        OnPropertyChanged(nameof(Enabled));
        OnPropertyChanged(nameof(ActivePetId));
        OnPropertyChanged(nameof(ActiveAgent));
        OnPropertyChanged(nameof(PersonaVoiceEnabled));
    }
}

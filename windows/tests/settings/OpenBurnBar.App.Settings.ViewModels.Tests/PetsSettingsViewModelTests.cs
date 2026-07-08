using System.Collections.Generic;
using OpenBurnBar.App.Settings.ViewModels;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class PetsSettingsViewModelTests
{
    private static readonly IReadOnlyList<PetChoice> Pets = new[]
    {
        new PetChoice("claudecode", "Claude Code"),
        new PetChoice("codex", "Codex"),
    };

    private static readonly IReadOnlyList<PetAgentChoice> Agents = new[]
    {
        new PetAgentChoice("codex", "Codex"),
        new PetAgentChoice("claude", "Claude"),
    };

    [Fact]
    public void Defaults_MatchPetCompanionFeature()
    {
        var vm = new PetsSettingsViewModel(Pets, Agents);
        Assert.False(vm.Enabled);
        Assert.Equal("claudecode", vm.ActivePetId);
        Assert.Equal("codex", vm.ActiveAgent);
        Assert.True(vm.PersonaVoiceEnabled);
    }

    [Fact]
    public void Enabling_ShowsCompanionThroughHost()
    {
        var host = new RecordingPetCompanionHost();
        var vm = new PetsSettingsViewModel(Pets, Agents, host: host);
        vm.Enabled = true;
        Assert.Equal(1, host.ShowCount);
        vm.Enabled = false;
        Assert.Equal(1, host.HideCount);
    }

    [Fact]
    public void SelectingPet_ResolvesAndCommandsHost()
    {
        var host = new RecordingPetCompanionHost();
        var vm = new PetsSettingsViewModel(Pets, Agents, host: host);
        vm.ActivePetId = "codex";
        Assert.Equal("codex", vm.ActivePetId);
        Assert.Equal("codex", host.LastSelectedPet);
    }

    [Fact]
    public void UnknownPet_FallsBackToDefault()
    {
        var vm = new PetsSettingsViewModel(Pets, Agents);
        vm.ActivePetId = "does-not-exist";
        Assert.Equal("claudecode", vm.ActivePetId);
    }

    [Fact]
    public void UnknownAgent_FallsBackToFirstAvailable()
    {
        var vm = new PetsSettingsViewModel(Pets, Agents);
        vm.ActiveAgent = "nope";
        Assert.Equal("codex", vm.ActiveAgent); // first available agent
    }

    [Fact]
    public void StoredPetOutsideCatalog_ResolvesOnLoad()
    {
        var store = new InMemoryPetSettingsStore(new PetSettingsSnapshot(true, "ghost", "ghost", false));
        var vm = new PetsSettingsViewModel(Pets, Agents, store: store);
        Assert.Equal("claudecode", vm.ActivePetId);
        Assert.Equal("codex", vm.ActiveAgent);
    }

    [Fact]
    public void Summon_EnablesAndCommandsHost()
    {
        var host = new RecordingPetCompanionHost();
        var vm = new PetsSettingsViewModel(Pets, Agents, host: host);
        vm.Summon();
        Assert.True(vm.Enabled);
        Assert.Equal(1, host.SummonCount);
    }

    [Fact]
    public void Mutations_PersistThroughStore()
    {
        var store = new InMemoryPetSettingsStore();
        var vm = new PetsSettingsViewModel(Pets, Agents, store: store);
        vm.Enabled = true;
        vm.ActivePetId = "codex";
        vm.ActiveAgent = "claude";
        vm.PersonaVoiceEnabled = false;

        var reloaded = new PetsSettingsViewModel(Pets, Agents, store: store);
        Assert.True(reloaded.Enabled);
        Assert.Equal("codex", reloaded.ActivePetId);
        Assert.Equal("claude", reloaded.ActiveAgent);
        Assert.False(reloaded.PersonaVoiceEnabled);
    }
}

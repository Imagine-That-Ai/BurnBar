using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real, macOS-runnable tests for the ported preset store
/// (windows/app/OpenBurnBar.App.Presentation/ElderWand/ElderWandSettingsModel.cs), parity
/// with AgentLens/Services/Settings/Stores/ElderWandSettings.swift. Drives the store
/// through an in-memory persistence fake — the analog of SettingsPersistenceCoordinator.
/// </summary>
public sealed class ElderWandSettingsModelTests
{
    private sealed class FakePersistence : IElderWandPresetPersistence
    {
        private readonly Dictionary<string, string> _store = new();

        public string? ReadString(string key) => _store.TryGetValue(key, out var v) ? v : null;

        public void WriteString(string key, string value) => _store[key] = value;

        public string? Raw(string key) => ReadString(key);

        public void Seed(string key, string value) => _store[key] = value;
    }

    private static ElderWandPreset Preset(string id, bool isDefault = false) =>
        new(id, $"Panel {id}", new[] { "a", "b" }, "judge", 8, isDefault);

    [Fact]
    public void Save_NewPreset_BecomesDefaultWhenFirst()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        store.Save(Preset("p1"));

        Assert.Single(store.Presets);
        Assert.True(store.Presets[0].IsDefault); // sanitizer promotes the only preset
        Assert.Equal("p1", store.ActivePreset!.Id);
        Assert.True(store.HasPresets);
    }

    [Fact]
    public void Save_ExistingId_ReplacesAndKeepsDefault()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        store.Save(Preset("p1"));
        Assert.True(store.Presets[0].IsDefault);

        // Update the same id with a non-default payload; its default status must survive.
        store.Save(new ElderWandPreset("p1", "Renamed", new[] { "x" }, "j2", 4, false));
        Assert.Single(store.Presets);
        Assert.Equal("Renamed", store.Presets[0].Name);
        Assert.True(store.Presets[0].IsDefault);
    }

    [Fact]
    public void Save_MarkedDefault_DemotesOthers()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        store.Save(Preset("p1"));
        store.Save(Preset("p2"));
        store.Save(Preset("p3", isDefault: true));

        Assert.Equal("p3", store.ActivePreset!.Id);
        Assert.Single(store.Presets, p => p.IsDefault);
    }

    [Fact]
    public void SetDefault_MovesTheDefault()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        store.Save(Preset("p1"));
        store.Save(Preset("p2"));
        Assert.Equal("p1", store.ActivePreset!.Id);

        store.SetDefault("p2");
        Assert.Equal("p2", store.ActivePreset!.Id);
        Assert.Single(store.Presets, p => p.IsDefault);

        store.SetDefault("unknown"); // no-op
        Assert.Equal("p2", store.ActivePreset!.Id);
    }

    [Fact]
    public void Rename_ChangesNameOnly()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        store.Save(Preset("p1"));
        store.Rename("p1", "Brand New Name");
        Assert.Equal("Brand New Name", store.Presets[0].Name);
        Assert.Equal(new[] { "a", "b" }, store.Presets[0].AnalysisModelIds);

        store.Rename("unknown", "ignored"); // no-op
        Assert.Single(store.Presets);
    }

    [Fact]
    public void Delete_PromotesNewDefault()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        store.Save(Preset("p1", isDefault: true));
        store.Save(Preset("p2"));

        store.Delete("p1");
        Assert.Single(store.Presets);
        Assert.Equal("p2", store.ActivePreset!.Id);
        Assert.True(store.Presets[0].IsDefault); // sanitizer promoted the survivor
    }

    [Fact]
    public void ReplaceAll_SanitizesToOneDefault()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        store.ReplaceAll(new[] { Preset("a"), Preset("b"), Preset("c") });
        Assert.Equal(3, store.Presets.Count);
        Assert.Single(store.Presets, p => p.IsDefault);
        Assert.True(store.Presets[0].IsDefault);
    }

    [Fact]
    public void Persistence_RoundTripsAcrossInstances()
    {
        var persistence = new FakePersistence();
        var store = new ElderWandSettingsModel(persistence);
        store.Save(Preset("p1"));
        store.Save(Preset("p2", isDefault: true));

        // A fresh store over the same backing store must decode the same sanitized list.
        var reopened = new ElderWandSettingsModel(persistence);
        Assert.Equal(2, reopened.Presets.Count);
        Assert.Equal("p2", reopened.ActivePreset!.Id);
        Assert.Equal(
            store.Presets.Select(p => p.Id),
            reopened.Presets.Select(p => p.Id));
    }

    [Fact]
    public void Persistence_UsesTheContractStorageKey()
    {
        var persistence = new FakePersistence();
        var store = new ElderWandSettingsModel(persistence);
        store.Save(Preset("p1"));
        Assert.NotNull(persistence.Raw(ElderWandSettingsModel.PresetsStorageKey));
        Assert.Equal("elderWand.presets.v1", ElderWandSettingsModel.PresetsStorageKey);
    }

    [Fact]
    public void CorruptStore_DecodesToEmpty()
    {
        var persistence = new FakePersistence();
        persistence.Seed(ElderWandSettingsModel.PresetsStorageKey, "{ not valid json ]");
        var store = new ElderWandSettingsModel(persistence);
        Assert.Empty(store.Presets);
        Assert.Null(store.ActivePreset);
        Assert.False(store.HasPresets);
    }

    [Fact]
    public void PluginsPayload_NullWhenNoPresets()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        Assert.Null(store.ElderWandPluginsPayload());
        Assert.Null(store.ElderWandPluginsPayloadJson());
    }

    [Fact]
    public void PluginsPayload_LowersActivePreset()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        store.Save(new ElderWandPreset("p1", "Fusion", new[] { "  m1 ", "m2" }, " judge ", 20, true));

        var payload = store.ElderWandPluginsPayload();
        Assert.NotNull(payload);
        var plugin = payload!.Single();
        Assert.Equal("fusion", plugin.Id);
        Assert.True(plugin.Enabled);
        Assert.Equal(new[] { "m1", "m2" }, plugin.AnalysisModels); // trimmed
        Assert.Equal("judge", plugin.Model);
        Assert.Equal(16, plugin.MaxToolCalls); // clamped into range
    }

    [Fact]
    public void PluginsPayloadJson_MatchesGatewayWireShape()
    {
        var store = new ElderWandSettingsModel(new FakePersistence());
        store.Save(new ElderWandPreset("p1", "Fusion", new[] { "m1", "m2" }, "judge", 8, true));

        string json = store.ElderWandPluginsPayloadJson()!;
        Assert.Equal(
            "[{\"id\":\"fusion\",\"enabled\":true,\"analysis_models\":[\"m1\",\"m2\"]," +
            "\"model\":\"judge\",\"max_tool_calls\":8}]",
            json);
    }
}

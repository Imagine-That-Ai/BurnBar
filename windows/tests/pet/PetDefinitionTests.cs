using System.Linq;
using OpenBurnBar.App.Pet.Behavior;
using OpenBurnBar.App.Pet.Definition;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests;

public sealed class PetDefinitionTests
{
    [Fact]
    public void ParsesRealClaudeCodeIdentity()
    {
        var def = PetTestData.LoadClaudeCode();
        Assert.Equal("claudecode", def.Id);
        Assert.Equal("Claude Code", def.Name);
        Assert.Equal("sweeper", def.Kind);
        Assert.Equal("petdef/1", def.Schema);
        Assert.Contains("#d97757", def.Palette);
    }

    [Fact]
    public void ParsesRealBehaviorGraph()
    {
        var def = PetTestData.LoadClaudeCode();
        var graph = def.Behavior;
        Assert.NotNull(graph);
        Assert.Equal("idle", graph!.Initial);
        Assert.Equal(15, graph.Transitions.Count);

        // A representative chat-driven edge is present and typed correctly.
        var listenThink = graph.TransitionsFrom("listen", PetBehaviorTrigger.SendPressed);
        Assert.Single(listenThink);
        Assert.Equal("think", listenThink[0].To);

        // A weighted ambient edge keeps its weight.
        var idleWander = graph.TransitionsFrom("idle", PetBehaviorTrigger.CooldownElapsed)
            .First(t => t.To == "wander");
        Assert.Equal(12, idleWander.EffectiveWeight);
    }

    [Fact]
    public void ParsesAtlasClipInventory()
    {
        var def = PetTestData.LoadClaudeCode();
        Assert.True(def.AtlasStates.ContainsKey("idle"));
        Assert.True(def.AtlasStates.ContainsKey("cheer"));
        Assert.True(def.AtlasStates.ContainsKey("sleep"));

        var clips = def.AvailableClips();
        Assert.Contains("idle", clips);
        Assert.Contains("cheer", clips);
        Assert.Equal(9, clips.Count); // the 9 atlas states (model3d.clips is empty)
    }

    [Fact]
    public void ParsesModel3DGlb()
    {
        var def = PetTestData.LoadClaudeCode();
        Assert.NotNull(def.Model3D);
        Assert.Equal("claudecode-crab", def.Model3D!.Glb);
        Assert.Equal("static", def.Model3D.Kind);
    }

    [Fact]
    public void MissingIdentity_Throws()
    {
        Assert.Throws<PetDefinitionParseException>(() => PetDefinition.Parse("{\"name\":\"x\"}"));
        Assert.Throws<PetDefinitionParseException>(() => PetDefinition.Parse("{\"id\":\"x\"}"));
    }

    [Fact]
    public void UnknownTriggerString_RoundTripsAsOther()
    {
        const string json = """
        {
          "id": "custom", "name": "Custom",
          "behavior": { "initial": "idle", "transitions": [
            { "from": "idle", "to": "dance", "when": "discoBeat" }
          ] }
        }
        """;
        var def = PetDefinition.Parse(json);
        var edge = def.Behavior!.Transitions.Single();
        Assert.Equal(PetBehaviorTriggerKind.Other, edge.When.Kind);
        Assert.Equal("discoBeat", edge.When.RawValue);
    }

    [Fact]
    public void LegacyTopLevelAtlasStates_AreNormalised()
    {
        const string json = """
        {
          "id": "legacy", "name": "Legacy",
          "grid": { "cols": 4, "rows": 2 },
          "cell": { "w": 64, "h": 64 },
          "states": { "idle": { "row": 0, "frames": 4, "fps": 8, "loop": true } }
        }
        """;
        var def = PetDefinition.Parse(json);
        Assert.True(def.AtlasStates.ContainsKey("idle"));
        Assert.Contains("idle", def.AvailableClips());
    }
}

using System;
using System.Collections.Generic;
using System.Text.Json;
using OpenBurnBar.App.Pet.Behavior;

namespace OpenBurnBar.App.Pet.Definition;

// MARK: - PetDefinition (desktop subset)
//
// C# peer of the desktop-relevant subset of
// `AgentLens/PetCompanion/Core/PetDefinition.swift` — itself the Swift mirror of
// the shared `@imaginethat/petcore` `PetDefinition` (`schema: "petdef/1"`). The
// SAME committed `petdef.json` files that drive the macOS companion + the web NPC
// decode here.
//
// This port carries exactly what the Windows pet runtime needs: identity, the
// behavior graph (the star of this lane), the 2D atlas state names, and the 3D
// model glb + clip inventory. It tolerates the legacy top-level `pet.json` atlas
// shape (grid/cell/states) exactly like the Swift decoder, and never throws on an
// unknown field so a newer petdef loads on an older desktop build.

/// One 2D atlas animation state (peer of `Atlas2D.State`). The desktop 3D runtime
/// keys clips off the same NAMES; this carries the sprite metadata for atlas pets.
public sealed record PetAtlasState(int Row, int Frames, int Fps, bool Loop, bool Hero);

/// The 3D model form (peer of `Model3D`).
public sealed record PetModel3D(string? Kind, string Glb, IReadOnlyDictionary<string, string> Clips, IReadOnlyList<string> ClipNames)
{
    /// The reaction brain's source of truth for what the model actually carries:
    /// clipNames ∪ clips.keys ∪ clips.values (peer of `availableSemanticClips`).
    public IReadOnlySet<string> AvailableSemanticClips()
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var n in ClipNames)
        {
            names.Add(n);
        }
        foreach (var kv in Clips)
        {
            names.Add(kv.Key);
            names.Add(kv.Value);
        }
        return names;
    }
}

/// The desktop-subset pet definition parsed from a `petdef.json`.
public sealed class PetDefinition
{
    public PetDefinition(
        string id,
        string name,
        string? schema,
        string? kind,
        string? displayName,
        string? description,
        IReadOnlyList<string> palette,
        IReadOnlyDictionary<string, PetAtlasState> atlasStates,
        PetModel3D? model3d,
        PetBehaviorGraph? behavior)
    {
        Id = id;
        Name = name;
        Schema = schema;
        Kind = kind;
        DisplayName = displayName;
        Description = description;
        Palette = palette;
        AtlasStates = atlasStates;
        Model3D = model3d;
        Behavior = behavior;
    }

    public string Id { get; }
    public string Name { get; }
    public string? Schema { get; }
    public string? Kind { get; }
    public string? DisplayName { get; }
    public string? Description { get; }
    public IReadOnlyList<string> Palette { get; }
    public IReadOnlyDictionary<string, PetAtlasState> AtlasStates { get; }
    public PetModel3D? Model3D { get; }
    public PetBehaviorGraph? Behavior { get; }

    /// The full clip/state inventory the reaction brain can choose from: the 3D
    /// model's semantic clips unioned with the 2D atlas state names.
    public IReadOnlySet<string> AvailableClips()
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        if (Model3D is not null)
        {
            foreach (var c in Model3D.AvailableSemanticClips())
            {
                names.Add(c);
            }
        }
        foreach (var key in AtlasStates.Keys)
        {
            names.Add(key);
        }
        return names;
    }

    /// Parse a `petdef.json` document. Throws <see cref="PetDefinitionParseException"/>
    /// only when the required identity (`id` + `name`) is missing/blank.
    public static PetDefinition Parse(string json)
    {
        if (json is null)
        {
            throw new ArgumentNullException(nameof(json));
        }
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new PetDefinitionParseException("petdef root is not a JSON object.");
        }

        var id = ReadString(root, "id");
        var name = ReadString(root, "name");
        if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(name))
        {
            throw new PetDefinitionParseException("petdef requires non-empty 'id' and 'name'.");
        }

        var palette = new List<string>();
        if (root.TryGetProperty("palette", out var pal) && pal.ValueKind == JsonValueKind.Array)
        {
            foreach (var swatch in pal.EnumerateArray())
            {
                if (swatch.ValueKind == JsonValueKind.String)
                {
                    palette.Add(swatch.GetString()!);
                }
            }
        }

        return new PetDefinition(
            id!,
            name!,
            ReadString(root, "schema"),
            ReadString(root, "kind"),
            ReadString(root, "displayName"),
            ReadString(root, "description"),
            palette,
            ParseAtlasStates(root),
            ParseModel3D(root),
            ParseBehavior(root));
    }

    // ── Behavior graph ─────────────────────────────────────────────────────────

    private static PetBehaviorGraph? ParseBehavior(JsonElement root)
    {
        if (!root.TryGetProperty("behavior", out var b) || b.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        var initial = ReadString(b, "initial") ?? "idle";
        var transitions = new List<PetBehaviorTransition>();
        if (b.TryGetProperty("transitions", out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var t in arr.EnumerateArray())
            {
                if (t.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }
                var from = ReadString(t, "from");
                var to = ReadString(t, "to");
                var when = ReadString(t, "when");
                if (from is null || to is null || when is null)
                {
                    continue; // skip malformed edges rather than fail the whole load.
                }
                int? weight = null;
                if (t.TryGetProperty("weight", out var w) && w.ValueKind == JsonValueKind.Number
                    && w.TryGetInt32(out var wv))
                {
                    weight = wv;
                }
                transitions.Add(new PetBehaviorTransition(from, to, PetBehaviorTrigger.FromRawValue(when), weight));
            }
        }
        return new PetBehaviorGraph(initial, transitions);
    }

    // ── Atlas 2D states (modern nested + legacy top-level) ──────────────────────

    private static IReadOnlyDictionary<string, PetAtlasState> ParseAtlasStates(JsonElement root)
    {
        var result = new Dictionary<string, PetAtlasState>(StringComparer.Ordinal);
        JsonElement states;
        if (root.TryGetProperty("atlas2d", out var atlas)
            && atlas.ValueKind == JsonValueKind.Object
            && atlas.TryGetProperty("states", out states)
            && states.ValueKind == JsonValueKind.Object)
        {
            // modern nested shape
        }
        else if (root.TryGetProperty("states", out states) && states.ValueKind == JsonValueKind.Object)
        {
            // legacy top-level pet.json shape
        }
        else
        {
            return result;
        }

        foreach (var prop in states.EnumerateObject())
        {
            var s = prop.Value;
            if (s.ValueKind != JsonValueKind.Object)
            {
                continue;
            }
            result[prop.Name] = new PetAtlasState(
                Row: ReadInt(s, "row") ?? 0,
                Frames: ReadInt(s, "frames") ?? 1,
                Fps: ReadInt(s, "fps") ?? 8,
                Loop: ReadBool(s, "loop") ?? false,
                Hero: ReadBool(s, "hero") ?? false);
        }
        return result;
    }

    // ── Model 3D ────────────────────────────────────────────────────────────────

    private static PetModel3D? ParseModel3D(JsonElement root)
    {
        if (!root.TryGetProperty("model3d", out var m) || m.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        var glb = ReadString(m, "glb");
        if (glb is null)
        {
            return null; // a model3d block without a glb is not renderable.
        }
        var clips = new Dictionary<string, string>(StringComparer.Ordinal);
        if (m.TryGetProperty("clips", out var c) && c.ValueKind == JsonValueKind.Object)
        {
            foreach (var kv in c.EnumerateObject())
            {
                if (kv.Value.ValueKind == JsonValueKind.String)
                {
                    clips[kv.Name] = kv.Value.GetString()!;
                }
            }
        }
        var clipNames = new List<string>();
        if (m.TryGetProperty("clipNames", out var cn) && cn.ValueKind == JsonValueKind.Array)
        {
            foreach (var n in cn.EnumerateArray())
            {
                if (n.ValueKind == JsonValueKind.String)
                {
                    clipNames.Add(n.GetString()!);
                }
            }
        }
        return new PetModel3D(ReadString(m, "kind"), glb, clips, clipNames);
    }

    // ── Primitives ───────────────────────────────────────────────────────────────

    private static string? ReadString(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static int? ReadInt(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : null;

    private static bool? ReadBool(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var v))
        {
            return null;
        }
        return v.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }
}

/// Thrown when a `petdef.json` is missing its required identity.
public sealed class PetDefinitionParseException : Exception
{
    public PetDefinitionParseException(string message) : base(message)
    {
    }
}

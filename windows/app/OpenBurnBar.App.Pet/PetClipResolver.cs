using System;
using System.Collections.Generic;
using OpenBurnBar.App.Pet.Definition;

namespace OpenBurnBar.App.Pet;

// MARK: - Logical-node -> clip resolver
//
// Maps a behavior-graph node name (idle / listen / think / speak / react / …) to a
// clip the loaded pet actually carries. Resolution order (peer of the renderer's
// clip lookup + the reaction brain fallback in
// AgentLens/PetCompanion/Core/PetRenderer.swift + PetReactionBrain.swift):
//
//   1. petdef `model3d.clips[node]`      — an explicit semantic->actual alias
//   2. the node name itself, if it is an available clip
//   3. PetReactionBrain.Choose-style fallback (node preferred, then "idle", then
//      the lexicographically smallest available clip)
//
// This keeps the WinUI three.js host dumb: the controller always hands it a real
// clip name.

/// Resolves logical-node names to concrete clip names for a loaded pet.
public sealed class PetClipResolver
{
    private readonly IReadOnlyDictionary<string, string> _semanticAliases;
    private readonly IReadOnlySet<string> _availableClips;

    public PetClipResolver(PetDefinition? definition)
    {
        _semanticAliases = definition?.Model3D?.Clips ?? EmptyAliases;
        _availableClips = definition?.AvailableClips() ?? EmptyClips;
    }

    public PetClipResolver(IReadOnlyDictionary<string, string> semanticAliases, IReadOnlySet<string> availableClips)
    {
        _semanticAliases = semanticAliases ?? EmptyAliases;
        _availableClips = availableClips ?? EmptyClips;
    }

    /// The clip inventory this resolver draws from.
    public IReadOnlySet<string> AvailableClips => _availableClips;

    /// Resolve a logical-node name to a clip, or null when the pet has no clips at
    /// all.
    public string? Resolve(string logicalNode)
    {
        if (logicalNode is null)
        {
            throw new ArgumentNullException(nameof(logicalNode));
        }

        // 1. explicit semantic->actual alias
        if (_semanticAliases.TryGetValue(logicalNode, out var aliased)
            && _availableClips.Contains(aliased))
        {
            return aliased;
        }
        // 2. the node name is itself a real clip
        if (_availableClips.Contains(logicalNode))
        {
            return logicalNode;
        }
        // 3. reaction-brain-style fallback: node preferred, then idle, then min
        if (_availableClips.Count == 0)
        {
            return null;
        }
        if (_availableClips.Contains("idle"))
        {
            return "idle";
        }
        string? smallest = null;
        foreach (var c in _availableClips)
        {
            if (smallest is null || string.CompareOrdinal(c, smallest) < 0)
            {
                smallest = c;
            }
        }
        return smallest;
    }

    /// Whether a clip should loop. Only the one-shot "react" beat is non-looping in
    /// this coarse model (peer of the atlas `loop:false` on react/cheer clips); every
    /// ambient/engaged state loops.
    public static bool ShouldLoop(string logicalNode) =>
        !string.Equals(logicalNode, "react", StringComparison.Ordinal);

    private static readonly IReadOnlyDictionary<string, string> EmptyAliases =
        new Dictionary<string, string>(StringComparer.Ordinal);

    private static readonly IReadOnlySet<string> EmptyClips = new HashSet<string>(StringComparer.Ordinal);
}

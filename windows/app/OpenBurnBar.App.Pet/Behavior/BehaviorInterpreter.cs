using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Pet.Behavior;

// MARK: - Behavior interpreter
//
// C# peer of `AgentLens/PetCompanion/Core/Behavior.swift` `BehaviorInterpreter`.
//
// Pure, deterministic interpreter over a PetBehaviorGraph. Holds the current
// logical node and advances it by feeding triggers; among equally-eligible
// transitions it picks one by weighted draw from a seeded Mulberry32.
//
// No host coupling: the renderer/controller observes Current and reacts.
// Determinism (same seed + same trigger stream → same node sequence) is the
// contract verified by the unit tests against the real committed petdef graphs.

/// A deterministic interpreter over a <see cref="PetBehaviorGraph"/>.
public sealed class BehaviorInterpreter
{
    private readonly PetBehaviorGraph _graph;
    private Mulberry32 _rng;

    public BehaviorInterpreter(PetBehaviorGraph graph, uint seed = 1)
    {
        _graph = graph ?? throw new ArgumentNullException(nameof(graph));
        Current = graph.Initial;
        _rng = new Mulberry32(seed);
    }

    /// The current node string (peer of `current`).
    public string Current { get; private set; }

    /// The current node mapped to a canonical <see cref="PetLogicalState"/>, or
    /// null when it is a bespoke node name (peer of `logicalState`).
    public PetLogicalState? LogicalState => PetLogicalStateExtensions.TryParse(Current);

    /// Raised after a fired trigger changes <see cref="Current"/>. Argument is the
    /// new node.
    public event Action<string>? StateChanged;

    /// Feed a trigger; if an eligible transition exists, move to its target and
    /// return the new node. Returns null when no transition matches (the pet stays
    /// put) — peer of `fire(_:)`.
    public string? Fire(PetBehaviorTrigger trigger)
    {
        var candidates = _graph.TransitionsFrom(Current, trigger);
        var chosen = Pick(candidates);
        if (chosen is null)
        {
            return null;
        }
        Current = chosen.To;
        StateChanged?.Invoke(Current);
        return Current;
    }

    /// Reset to the graph's initial node, optionally reseeding (peer of
    /// `reset(seed:)`, used on wake / restart).
    public void Reset(uint? seed = null)
    {
        Current = _graph.Initial;
        if (seed is { } s)
        {
            _rng = new Mulberry32(s);
        }
        StateChanged?.Invoke(Current);
    }

    // Weighted selection. With one candidate it is deterministic; with several it
    // draws a point in [0, totalWeight) from the RNG and walks the cumulative
    // weights — identical to the TS/Swift selection so golden vectors line up.
    private PetBehaviorTransition? Pick(IReadOnlyList<PetBehaviorTransition> candidates)
    {
        if (candidates.Count == 0)
        {
            return null;
        }
        if (candidates.Count == 1)
        {
            return candidates[0];
        }
        var total = 0;
        foreach (var c in candidates)
        {
            total += c.EffectiveWeight;
        }
        if (total <= 0)
        {
            return candidates[0];
        }
        var point = _rng.NextUnit() * total;
        foreach (var c in candidates)
        {
            point -= c.EffectiveWeight;
            if (point < 0)
            {
                return c;
            }
        }
        return candidates[candidates.Count - 1];
    }
}

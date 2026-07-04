using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Pet.Behavior;

// MARK: - Behavior graph (XState-shaped)
//
// C# peer of `AgentLens/PetCompanion/Core/Behavior.swift` `PetBehaviorGraph`.
//
// The `behavior` block of a `petdef.json`: an initial node plus a flat list of
// weighted transitions. Both the shared TS/Swift interpreters read this identical
// JSON; only the host action implementation differs. This is a pure domain type —
// JSON (de)serialisation lives in Definition/PetDefinition.cs so the domain never
// depends on a particular serialiser shape.

/// One weighted transition edge of a behavior graph.
public sealed class PetBehaviorTransition
{
    public PetBehaviorTransition(string from, string to, PetBehaviorTrigger when, int? weight = null)
    {
        From = from ?? throw new ArgumentNullException(nameof(from));
        To = to ?? throw new ArgumentNullException(nameof(to));
        When = when;
        Weight = weight;
    }

    public string From { get; }

    public string To { get; }

    public PetBehaviorTrigger When { get; }

    /// Selection weight among equally-eligible transitions (JSON `weight`; null ⇒
    /// default 1).
    public int? Weight { get; }

    /// Weight clamped to a non-negative value, defaulting to 1 (peer of the Swift
    /// `effectiveWeight`).
    public int EffectiveWeight => Math.Max(Weight ?? 1, 0);
}

/// A pet's behavior graph: an initial node and a flat weighted transition list.
public sealed class PetBehaviorGraph
{
    public PetBehaviorGraph(string initial, IReadOnlyList<PetBehaviorTransition> transitions)
    {
        Initial = initial ?? throw new ArgumentNullException(nameof(initial));
        Transitions = transitions ?? throw new ArgumentNullException(nameof(transitions));
    }

    public string Initial { get; }

    public IReadOnlyList<PetBehaviorTransition> Transitions { get; }

    /// Transitions leaving <paramref name="state"/> that match <paramref name="trigger"/>
    /// (peer of `transitions(from:on:)`). Order is preserved so weighted selection
    /// is deterministic.
    public IReadOnlyList<PetBehaviorTransition> TransitionsFrom(string state, PetBehaviorTrigger trigger)
    {
        var result = new List<PetBehaviorTransition>();
        foreach (var t in Transitions)
        {
            if (string.Equals(t.From, state, StringComparison.Ordinal) && t.When == trigger)
            {
                result.Add(t);
            }
        }
        return result;
    }

    /// All distinct triggers that can fire from <paramref name="state"/>, in first-
    /// seen order (peer of `triggers(from:)`, used by the time-driven tick).
    public IReadOnlyList<PetBehaviorTrigger> TriggersFrom(string state)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var ordered = new List<PetBehaviorTrigger>();
        foreach (var t in Transitions)
        {
            if (!string.Equals(t.From, state, StringComparison.Ordinal))
            {
                continue;
            }
            if (seen.Add(t.When.RawValue))
            {
                ordered.Add(t.When);
            }
        }
        return ordered;
    }

    /// Every distinct node name referenced by the graph (initial + all edge
    /// endpoints). Useful for validation and clip-coverage checks.
    public IReadOnlyCollection<string> States()
    {
        var set = new HashSet<string>(StringComparer.Ordinal) { Initial };
        foreach (var t in Transitions)
        {
            set.Add(t.From);
            set.Add(t.To);
        }
        return set;
    }
}

using System;

namespace OpenBurnBar.App.Pet.Behavior;

// MARK: - Coarse activity state
//
// The three high-level states the overlay + tray surface react to, distilled from
// the fine-grained logical node the behavior graph walks. The macOS companion
// makes the same coarse distinction implicitly (ambient wandering vs an engaged
// chat turn vs being explicitly summoned to the cursor); here it is an explicit,
// testable classification so the WinUI overlay can pick its window level, its
// hit-test policy, and its glow without knowing every bespoke node name.

/// The coarse activity a pet is in.
public enum PetActivityState
{
    /// Ambient / dormant: idle, sleep, wander, drag. The overlay stays click-through
    /// and low-key.
    Idle,

    /// Engaged in a chat turn: listen, think, speak, react. The overlay perks up
    /// (glow, bubble) but stays non-activating.
    Active,

    /// Explicitly summoned to the user (hotkey / cursor pull). A transient
    /// controller-level override that takes precedence over the logical node.
    Summon,
}

/// Maps a behavior-graph logical node to its coarse <see cref="PetActivityState"/>.
public static class PetActivity
{
    /// Classify a logical node string. Unknown / bespoke node names fall back to
    /// <see cref="PetActivityState.Idle"/> (ambient) — a newer petdef never forces
    /// the overlay into an engaged state it does not understand.
    public static PetActivityState Classify(string? logicalNode)
    {
        var state = PetLogicalStateExtensions.TryParse(logicalNode);
        return Classify(state);
    }

    /// Classify a canonical <see cref="PetLogicalState"/>. Null (bespoke node) is
    /// treated as ambient <see cref="PetActivityState.Idle"/>.
    public static PetActivityState Classify(PetLogicalState? state) => state switch
    {
        PetLogicalState.Listen => PetActivityState.Active,
        PetLogicalState.Think => PetActivityState.Active,
        PetLogicalState.Speak => PetActivityState.Active,
        PetLogicalState.React => PetActivityState.Active,
        PetLogicalState.Idle => PetActivityState.Idle,
        PetLogicalState.Wander => PetActivityState.Idle,
        PetLogicalState.Drag => PetActivityState.Idle,
        PetLogicalState.Sleep => PetActivityState.Idle,
        null => PetActivityState.Idle,
        _ => PetActivityState.Idle,
    };
}

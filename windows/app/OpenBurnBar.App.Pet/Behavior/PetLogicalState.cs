using System;

namespace OpenBurnBar.App.Pet.Behavior;

// MARK: - Logical states
//
// C# peer of `AgentLens/PetCompanion/Core/Behavior.swift` `PetLogicalState`.
//
// The one animation-state vocabulary shared across both renderers and both kinds
// (PLAN §2 "Animation states"). These are the logical names the behavior graph
// emits; `atlas2d.states` / `model3d.clips` key off the SAME names.

/// The canonical logical states a pet's behavior graph walks. Custom petdefs may
/// use bespoke node names too — <see cref="PetLogicalStateExtensions.TryParse"/>
/// only recognises these canonical eight.
public enum PetLogicalState
{
    Idle,
    Wander,
    Drag,
    Listen,
    Think,
    Speak,
    Sleep,
    React,
}

/// Round-trip helpers between the lowerCamel JSON node strings and the enum.
public static class PetLogicalStateExtensions
{
    /// The lowerCamel string used in the shared petdef schema (peer of the Swift
    /// `String` raw value).
    public static string ToRawValue(this PetLogicalState state) => state switch
    {
        PetLogicalState.Idle => "idle",
        PetLogicalState.Wander => "wander",
        PetLogicalState.Drag => "drag",
        PetLogicalState.Listen => "listen",
        PetLogicalState.Think => "think",
        PetLogicalState.Speak => "speak",
        PetLogicalState.Sleep => "sleep",
        PetLogicalState.React => "react",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, null),
    };

    /// Map a node string to a canonical state, or null when it is a bespoke node
    /// name (peer of `PetLogicalState(rawValue:)` returning nil).
    public static PetLogicalState? TryParse(string? rawValue) => rawValue switch
    {
        "idle" => PetLogicalState.Idle,
        "wander" => PetLogicalState.Wander,
        "drag" => PetLogicalState.Drag,
        "listen" => PetLogicalState.Listen,
        "think" => PetLogicalState.Think,
        "speak" => PetLogicalState.Speak,
        "sleep" => PetLogicalState.Sleep,
        "react" => PetLogicalState.React,
        _ => null,
    };
}

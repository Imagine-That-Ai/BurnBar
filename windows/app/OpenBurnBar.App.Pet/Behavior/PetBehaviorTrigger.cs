using System;

namespace OpenBurnBar.App.Pet.Behavior;

// MARK: - Behavior triggers
//
// C# peer of `AgentLens/PetCompanion/Core/Behavior.swift` `PetBehaviorTrigger`.
//
// The `when` guards a transition can fire on. The wire values are the lowerCamel
// strings used in the shared petdef schema (`cooldownElapsed`, `cursorNear`, …).
// Unknown strings round-trip through <see cref="OtherKind"/> so a newer petdef
// never fails to decode on an older desktop build — the exact forward-compat
// contract the Swift `.other(String)` case provides.

/// The kind of a behavior trigger. Canonical kinds have a fixed wire string;
/// <see cref="Other"/> carries an arbitrary future guard verbatim.
public enum PetBehaviorTriggerKind
{
    CooldownElapsed,
    CursorNear,
    Special,
    InputFocused,
    SendPressed,
    StreamStart,
    StreamToken,
    ResultLanded,
    FallbackFired,
    IdleElapsed,
    Other,
}

/// A behavior trigger — the `when` guard on a graph transition. Value type with
/// structural equality so it can key dictionaries / sets exactly like the Swift
/// `Hashable` enum.
public readonly struct PetBehaviorTrigger : IEquatable<PetBehaviorTrigger>
{
    /// The canonical kind, or <see cref="PetBehaviorTriggerKind.Other"/> for a
    /// preserved-verbatim future guard.
    public PetBehaviorTriggerKind Kind { get; }

    /// The exact wire string. For canonical kinds this is the fixed lowerCamel
    /// token; for <see cref="PetBehaviorTriggerKind.Other"/> it is the original
    /// unknown string.
    public string RawValue { get; }

    private PetBehaviorTrigger(PetBehaviorTriggerKind kind, string rawValue)
    {
        Kind = kind;
        RawValue = rawValue;
    }

    // Canonical singletons (peer of the enum cases).
    public static readonly PetBehaviorTrigger CooldownElapsed = new(PetBehaviorTriggerKind.CooldownElapsed, "cooldownElapsed");
    public static readonly PetBehaviorTrigger CursorNear = new(PetBehaviorTriggerKind.CursorNear, "cursorNear");
    public static readonly PetBehaviorTrigger Special = new(PetBehaviorTriggerKind.Special, "special");
    public static readonly PetBehaviorTrigger InputFocused = new(PetBehaviorTriggerKind.InputFocused, "inputFocused");
    public static readonly PetBehaviorTrigger SendPressed = new(PetBehaviorTriggerKind.SendPressed, "sendPressed");
    public static readonly PetBehaviorTrigger StreamStart = new(PetBehaviorTriggerKind.StreamStart, "streamStart");
    public static readonly PetBehaviorTrigger StreamToken = new(PetBehaviorTriggerKind.StreamToken, "streamToken");
    public static readonly PetBehaviorTrigger ResultLanded = new(PetBehaviorTriggerKind.ResultLanded, "resultLanded");
    public static readonly PetBehaviorTrigger FallbackFired = new(PetBehaviorTriggerKind.FallbackFired, "fallbackFired");
    public static readonly PetBehaviorTrigger IdleElapsed = new(PetBehaviorTriggerKind.IdleElapsed, "idleElapsed");

    /// Preserve an unrecognised guard verbatim (peer of `.other(_:)`).
    public static PetBehaviorTrigger OtherKind(string rawValue) =>
        new(PetBehaviorTriggerKind.Other, rawValue ?? string.Empty);

    /// Parse a wire string to a canonical trigger, falling back to
    /// <see cref="OtherKind"/> for anything unrecognised (peer of
    /// `init(rawValue:)`).
    public static PetBehaviorTrigger FromRawValue(string rawValue) => rawValue switch
    {
        "cooldownElapsed" => CooldownElapsed,
        "cursorNear" => CursorNear,
        "special" => Special,
        "inputFocused" => InputFocused,
        "sendPressed" => SendPressed,
        "streamStart" => StreamStart,
        "streamToken" => StreamToken,
        "resultLanded" => ResultLanded,
        "fallbackFired" => FallbackFired,
        "idleElapsed" => IdleElapsed,
        _ => OtherKind(rawValue),
    };

    public bool Equals(PetBehaviorTrigger other) =>
        string.Equals(RawValue, other.RawValue, StringComparison.Ordinal);

    public override bool Equals(object? obj) => obj is PetBehaviorTrigger other && Equals(other);

    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(RawValue);

    public override string ToString() => RawValue;

    public static bool operator ==(PetBehaviorTrigger left, PetBehaviorTrigger right) => left.Equals(right);

    public static bool operator !=(PetBehaviorTrigger left, PetBehaviorTrigger right) => !left.Equals(right);
}

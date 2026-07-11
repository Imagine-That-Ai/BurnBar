using System;

namespace OpenBurnBar.App.Dashboard.EasterEgg;

/// <summary>Which takeover a summon presents — port of <c>EasterEggEvent.Kind</c>.</summary>
public enum EasterEggKind
{
    /// <summary>Dark-appearance celebration: provider-logo + crest fireworks.</summary>
    LogoStorm,

    /// <summary>Light-appearance shower: cloud crests raining gold/silver coins.</summary>
    CloudTokenRain,

    /// <summary>Edge feedback at the top or bottom of the scroll view.</summary>
    Boundary,
}

/// <summary>Which edge a boundary pop fires from — port of <c>EasterEggEdge</c>.</summary>
public enum EasterEggEdge
{
    Top,
    Bottom,
}

/// <summary>
/// One in-flight easter egg — port of the <c>EasterEggEvent</c> struct in
/// <c>EasterEggOverlay.swift</c>. The controller mints exactly one per summon; the
/// canvas host renders it and reports back (by <see cref="Id"/>) when it has
/// played out. Immutable; identity is the <see cref="Id"/>.
/// </summary>
public sealed class EasterEggEvent : IEquatable<EasterEggEvent>
{
    public EasterEggEvent(EasterEggKind kind, double startedAtSeconds, EasterEggEdge edge = EasterEggEdge.Top)
    {
        Id = Guid.NewGuid();
        Kind = kind;
        Edge = edge;
        StartedAtSeconds = startedAtSeconds;
    }

    /// <summary>Stable identity so the host can report the right event finished.</summary>
    public Guid Id { get; }

    public EasterEggKind Kind { get; }

    /// <summary>The edge a <see cref="EasterEggKind.Boundary"/> fires from (ignored otherwise).</summary>
    public EasterEggEdge Edge { get; }

    /// <summary>Controller-clock start time (seconds), for the host's teardown timer.</summary>
    public double StartedAtSeconds { get; }

    /// <summary>
    /// Total lifetime of the effect — the 5s takeover plus each flavour's tail
    /// (storm +0.3s, rain +0.9s, boundary a single 1.0s ballistic arc). Matches
    /// the Swift <c>duration</c> switch exactly.
    /// </summary>
    public double DurationSeconds => Kind switch
    {
        EasterEggKind.LogoStorm => EasterEggFx.DurationSeconds + 0.3,
        EasterEggKind.CloudTokenRain => EasterEggFx.DurationSeconds + 0.9,
        EasterEggKind.Boundary => 1.0,
        _ => EasterEggFx.DurationSeconds,
    };

    public bool Equals(EasterEggEvent? other) => other is not null && other.Id == Id;

    public override bool Equals(object? obj) => Equals(obj as EasterEggEvent);

    public override int GetHashCode() => Id.GetHashCode();
}

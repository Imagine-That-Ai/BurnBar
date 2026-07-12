using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from MissionKindChooser
// (OpenBurnBarCore/.../MissionControl/MissionKindChooser.swift). A display-ready chip for one
// mission archetype in the kind chooser, carrying its glyph / tagline / selection state and a
// stable click tag. Pure so the chooser copy + selection is unit-testable on macOS.

/// <summary>One archetype chip in the mission-kind chooser.</summary>
public sealed class MissionKindChipItem
{
    public MissionKindChipItem(MissionKind kind, bool isSelected)
    {
        Kind = kind;
        Tag = MissionKindInfo.RawValue(kind);
        DisplayName = MissionKindInfo.DisplayName(kind);
        Glyph = MissionKindInfo.Glyph(kind);
        Tagline = MissionKindInfo.Tagline(kind);
        IsSelected = isSelected;
    }

    public MissionKind Kind { get; }

    /// <summary>Stable raw-value tag for click routing (e.g. "ui_improvement").</summary>
    public string Tag { get; }

    public string DisplayName { get; }
    public string Glyph { get; }
    public string Tagline { get; }
    public bool IsSelected { get; }

    /// <summary>Build the chip row for the current selection.</summary>
    public static IReadOnlyList<MissionKindChipItem> Build(MissionKind selected) =>
        MissionKindInfo.All.Select(k => new MissionKindChipItem(k, k == selected)).ToList();

    /// <summary>Resolve a chip tag back to its <see cref="MissionKind"/> (for click routing).</summary>
    public static MissionKind KindForTag(string tag) =>
        MissionKindInfo.All.FirstOrDefault(k => MissionKindInfo.RawValue(k) == tag);
}

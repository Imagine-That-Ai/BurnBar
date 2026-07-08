using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Switcher;

// View-facing bundle of a ProfileGroup with its rendered rows. Mirrors what the SwiftUI
// providerSection(_:) closure computes per group (header label + summary + connect/add
// affordance + the ForEach of ProfileRowViews). Keeping this in the portable lib lets the
// WinUI group template x:Bind straight to Rows without any code-behind row construction —
// and lets the section shape be unit-tested on macOS.

/// <summary>A provider section (group + its display state + its rows).</summary>
public sealed class SwitcherGroupViewModel
{
    public SwitcherGroupViewModel(
        ProfileGroup group,
        IReadOnlyList<SwitcherProfileRowViewModel> rows)
    {
        Group = group;
        Rows = rows;
    }

    public ProfileGroup Group { get; }

    public IReadOnlyList<SwitcherProfileRowViewModel> Rows { get; }

    public string Key => Group.Key;

    public string Label => Group.Label;

    public string Glyph => Group.Glyph;

    public string BrandColorHex => Group.BrandColorHex;

    public string Summary => Group.Summary();

    public int ConnectedCount => Group.ConnectedCount;

    public int ProfileCount => Group.Profiles.Count;

    public bool IsCli => Group.IsCli;

    public bool IsBrowser => Group.IsBrowser;

    public SwitcherCLIProfileType? CliType => Group.CliType;

    public SwitcherBrowserProfileType? BrowserType => Group.BrowserType;

    /// <summary>Connected-count pill, e.g. "1 connected". Swift: the header count.</summary>
    public string ConnectedBadge => $"{ConnectedCount} connected";

    /// <summary>Swift: <c>group.connectedCount == 0 ? "Connect" : "Add Account"</c>.</summary>
    public string AddButtonLabel => ConnectedCount == 0 ? "Connect" : "Add Account";

    /// <summary>Whether the expand/collapse control shows (Swift: <c>group.profiles.count > 1</c>).</summary>
    public bool CanCollapse => ProfileCount > 1;

    /// <summary>Build a section for a group with the active selection + clock injected.</summary>
    public static SwitcherGroupViewModel ForGroup(
        ProfileGroup group,
        string? activeProfileId,
        DateTimeOffset now)
        => new(group, SwitcherProfileRowViewModel.ForGroup(group, activeProfileId, now));
}

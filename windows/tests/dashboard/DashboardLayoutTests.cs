using System.Collections.Generic;
using System.ComponentModel;
using OpenBurnBar.App.Dashboard.Layout;
using Xunit;

namespace OpenBurnBar.App.Dashboard.Tests;

/// <summary>
/// Locks the shared <see cref="DashboardLayout"/> contract ported from
/// <c>ThemePrimitives.swift</c> — raw values + storage key are persisted strings
/// shared across platforms, so churning them orphans saved preferences.
/// </summary>
public sealed class DashboardLayoutTests
{
    [Fact]
    public void All_MatchesSwiftCaseOrder()
    {
        Assert.Equal(
            new[]
            {
                DashboardLayout.Classic,
                DashboardLayout.Aurora,
                DashboardLayout.Nebula,
                DashboardLayout.Constellation,
                DashboardLayout.Cockpit,
                DashboardLayout.Atelier,
                DashboardLayout.Stream,
                DashboardLayout.Atlas,
            },
            DashboardLayoutMeta.All);
    }

    [Theory]
    [InlineData(DashboardLayout.Classic, "classic")]
    [InlineData(DashboardLayout.Aurora, "aurora")]
    [InlineData(DashboardLayout.Nebula, "nebula")]
    [InlineData(DashboardLayout.Constellation, "constellation")]
    [InlineData(DashboardLayout.Cockpit, "cockpit")]
    [InlineData(DashboardLayout.Atelier, "atelier")]
    [InlineData(DashboardLayout.Stream, "stream")]
    [InlineData(DashboardLayout.Atlas, "atlas")]
    public void RawValues_AreStable(DashboardLayout layout, string raw)
    {
        Assert.Equal(raw, layout.RawValue());
    }

    /// <summary>
    /// The enum member names are frozen ids; these are what a user reads. Pinned
    /// so a Windows build cannot drift from the macOS switcher gallery.
    /// </summary>
    [Theory]
    [InlineData(DashboardLayout.Classic, "Ledger")]
    [InlineData(DashboardLayout.Aurora, "Focus")]
    [InlineData(DashboardLayout.Nebula, "Bento")]
    [InlineData(DashboardLayout.Constellation, "Ask")]
    [InlineData(DashboardLayout.Cockpit, "Cockpit")]
    [InlineData(DashboardLayout.Atelier, "Canvas")]
    [InlineData(DashboardLayout.Stream, "Stream")]
    [InlineData(DashboardLayout.Atlas, "Atlas")]
    public void DisplayNames_MatchSwift(DashboardLayout layout, string name)
    {
        Assert.Equal(name, layout.DisplayName());
    }

    [Theory]
    [InlineData(DashboardLayout.Classic, "list.bullet.rectangle")]
    [InlineData(DashboardLayout.Aurora, "largecircle.fill.circle")]
    [InlineData(DashboardLayout.Nebula, "square.grid.2x2")]
    [InlineData(DashboardLayout.Constellation, "text.magnifyingglass")]
    [InlineData(DashboardLayout.Cockpit, "gauge.with.dots.needle.67percent")]
    [InlineData(DashboardLayout.Atelier, "photo.artframe")]
    [InlineData(DashboardLayout.Stream, "arrow.down.right.and.arrow.up.left.circle")]
    [InlineData(DashboardLayout.Atlas, "chart.bar.xaxis")]
    public void SymbolNames_MatchSwift(DashboardLayout layout, string symbol)
    {
        Assert.Equal(symbol, layout.SymbolName());
    }

    [Fact]
    public void StorageKey_IsTheStableSharedString()
    {
        Assert.Equal("dashboardLayout", DashboardLayoutMeta.StorageKey);
    }

    [Fact]
    public void Default_IsAurora()
    {
        Assert.Equal(DashboardLayout.Aurora, DashboardLayoutMeta.Default);
    }

    [Fact]
    public void KernelForward_Classification_MatchesSwift()
    {
        Assert.True(DashboardLayout.Atelier.IsKernelForward());
        Assert.True(DashboardLayout.Constellation.IsKernelForward());
        Assert.False(DashboardLayout.Classic.IsKernelForward());
        Assert.False(DashboardLayout.Aurora.IsKernelForward());
        Assert.False(DashboardLayout.Nebula.IsKernelForward());
        Assert.False(DashboardLayout.Cockpit.IsKernelForward());
        Assert.False(DashboardLayout.Stream.IsKernelForward());
        Assert.False(DashboardLayout.Atlas.IsKernelForward());
    }

    [Fact]
    public void DisplayName_And_Glyph_NonEmpty_ForEveryCase()
    {
        foreach (DashboardLayout layout in DashboardLayoutMeta.All)
        {
            Assert.False(string.IsNullOrEmpty(layout.DisplayName()));
            Assert.False(string.IsNullOrEmpty(layout.Glyph()));
            Assert.False(string.IsNullOrEmpty(layout.Tagline()));
        }
    }

    [Fact]
    public void Parse_RoundTripsEveryRawValue()
    {
        foreach (DashboardLayout layout in DashboardLayoutMeta.All)
        {
            Assert.Equal(layout, DashboardLayoutMeta.Parse(layout.RawValue()));
        }
    }

    [Fact]
    public void Parse_FallsBackToAurora_OnNullOrGarbage()
    {
        Assert.Equal(DashboardLayout.Aurora, DashboardLayoutMeta.Parse(null));
        Assert.Equal(DashboardLayout.Aurora, DashboardLayoutMeta.Parse("not-a-layout"));
        Assert.Equal(DashboardLayout.Aurora, DashboardLayoutMeta.Parse(string.Empty));
    }
}

/// <summary>Locks the switcher state machine (<see cref="DashboardLayoutState"/>).</summary>
public sealed class DashboardLayoutStateTests
{
    [Fact]
    public void Default_IsAurora()
    {
        var state = new DashboardLayoutState();
        Assert.Equal(DashboardLayout.Aurora, state.Selection);
    }

    [Fact]
    public void FromRaw_HydratesSelection()
    {
        Assert.Equal(DashboardLayout.Nebula, DashboardLayoutState.FromRaw("nebula").Selection);
        Assert.Equal(DashboardLayout.Aurora, DashboardLayoutState.FromRaw("garbage").Selection);
    }

    [Fact]
    public void Select_SetsSelection_AndRawRoundTrips()
    {
        var state = new DashboardLayoutState();
        state.Select(DashboardLayout.Cockpit);
        Assert.Equal(DashboardLayout.Cockpit, state.Selection);
        Assert.Equal("cockpit", state.RawSelection);
    }

    [Fact]
    public void RawSelection_Setter_ParsesBack()
    {
        var state = new DashboardLayoutState();
        state.RawSelection = "aurora";
        Assert.Equal(DashboardLayout.Aurora, state.Selection);
    }

    [Fact]
    public void SelectNext_CyclesAndWraps()
    {
        var state = new DashboardLayoutState(DashboardLayout.Classic);
        state.SelectNext();
        Assert.Equal(DashboardLayout.Aurora, state.Selection);

        state.Select(DashboardLayout.Atlas); // last
        state.SelectNext();
        Assert.Equal(DashboardLayout.Classic, state.Selection); // wrapped
    }

    [Fact]
    public void SelectPrevious_CyclesAndWraps()
    {
        var state = new DashboardLayoutState(DashboardLayout.Classic);
        state.SelectPrevious();
        Assert.Equal(DashboardLayout.Atlas, state.Selection); // wrapped to last
    }

    [Fact]
    public void Selection_RaisesPropertyChanged()
    {
        var state = new DashboardLayoutState();
        var changed = new List<string?>();
        ((INotifyPropertyChanged)state).PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        state.Select(DashboardLayout.Nebula);

        Assert.Contains(nameof(DashboardLayoutState.Selection), changed);
        Assert.Contains(nameof(DashboardLayoutState.RawSelection), changed);
        Assert.Contains(nameof(DashboardLayoutState.IsKernelForward), changed);
    }

    [Fact]
    public void Selection_SameValue_DoesNotNotify()
    {
        var state = new DashboardLayoutState(DashboardLayout.Nebula);
        var changed = new List<string?>();
        ((INotifyPropertyChanged)state).PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        state.Select(DashboardLayout.Nebula);

        Assert.Empty(changed);
    }

    [Fact]
    public void ShouldCollapseToMenu_WhenSegmentedControlDoesNotFit()
    {
        var state = new DashboardLayoutState();
        // 6 segments * 90pt + gaps + padding is well over 300pt -> collapse.
        Assert.True(state.ShouldCollapseToMenu(availableWidth: 300, perSegmentWidth: 90));
        // A wide rail comfortably fits the segmented control.
        Assert.False(state.ShouldCollapseToMenu(availableWidth: 1200, perSegmentWidth: 90));
    }
}

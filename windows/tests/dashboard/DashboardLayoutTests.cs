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
    public void RawValues_AreStable(DashboardLayout layout, string raw)
    {
        Assert.Equal(raw, layout.RawValue());
    }

    [Theory]
    [InlineData(DashboardLayout.Classic, "rectangle.grid.1x2")]
    [InlineData(DashboardLayout.Aurora, "sun.haze")]
    [InlineData(DashboardLayout.Nebula, "rectangle.grid.2x2")]
    [InlineData(DashboardLayout.Constellation, "sparkles")]
    [InlineData(DashboardLayout.Cockpit, "gauge.with.dots.needle.67percent")]
    [InlineData(DashboardLayout.Atelier, "paintpalette")]
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
    public void Default_IsAtelier()
    {
        Assert.Equal(DashboardLayout.Atelier, DashboardLayoutMeta.Default);
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
    }

    [Fact]
    public void DisplayName_And_Glyph_NonEmpty_ForEveryCase()
    {
        foreach (DashboardLayout layout in DashboardLayoutMeta.All)
        {
            Assert.False(string.IsNullOrEmpty(layout.DisplayName()));
            Assert.False(string.IsNullOrEmpty(layout.Glyph()));
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
    public void Parse_FallsBackToAtelier_OnNullOrGarbage()
    {
        Assert.Equal(DashboardLayout.Atelier, DashboardLayoutMeta.Parse(null));
        Assert.Equal(DashboardLayout.Atelier, DashboardLayoutMeta.Parse("not-a-layout"));
        Assert.Equal(DashboardLayout.Atelier, DashboardLayoutMeta.Parse(string.Empty));
    }
}

/// <summary>Locks the switcher state machine (<see cref="DashboardLayoutState"/>).</summary>
public sealed class DashboardLayoutStateTests
{
    [Fact]
    public void Default_IsAtelier()
    {
        var state = new DashboardLayoutState();
        Assert.Equal(DashboardLayout.Atelier, state.Selection);
    }

    [Fact]
    public void FromRaw_HydratesSelection()
    {
        Assert.Equal(DashboardLayout.Nebula, DashboardLayoutState.FromRaw("nebula").Selection);
        Assert.Equal(DashboardLayout.Atelier, DashboardLayoutState.FromRaw("garbage").Selection);
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

        state.Select(DashboardLayout.Atelier); // last
        state.SelectNext();
        Assert.Equal(DashboardLayout.Classic, state.Selection); // wrapped
    }

    [Fact]
    public void SelectPrevious_CyclesAndWraps()
    {
        var state = new DashboardLayoutState(DashboardLayout.Classic);
        state.SelectPrevious();
        Assert.Equal(DashboardLayout.Atelier, state.Selection); // wrapped to last
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

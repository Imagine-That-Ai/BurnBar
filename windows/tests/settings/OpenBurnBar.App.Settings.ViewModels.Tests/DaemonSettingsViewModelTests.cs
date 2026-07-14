using System.Linq;
using OpenBurnBar.App.Settings.ViewModels.Daemon;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class DaemonSettingsViewModelTests
{
    [Fact]
    public void Summary_ProjectsTheMatrixTotals()
    {
        var vm = new DaemonSettingsViewModel();

        Assert.Equal(13, vm.Summary.SubstitutedAlready);
        Assert.Equal(3, vm.Summary.SubstituteToBuild);
        Assert.Equal(14, vm.Summary.Deferred);
        Assert.Equal(4, vm.Summary.NotApplicable);
        Assert.Equal(34, vm.Summary.Total);
        Assert.Equal(13, vm.Summary.LiveOnV1);
    }

    [Fact]
    public void HeaderLine_MentionsEveryDispositionTally()
    {
        var vm = new DaemonSettingsViewModel();
        Assert.Contains("34 daemon duties", vm.Summary.HeaderLine);
        Assert.Contains("13 substituted", vm.Summary.HeaderLine);
        Assert.Contains("3 to build", vm.Summary.HeaderLine);
        Assert.Contains("14 deferred", vm.Summary.HeaderLine);
        Assert.Contains("4 N/A", vm.Summary.HeaderLine);
    }

    [Fact]
    public void DecisionMetadata_PointsAtWpd0006()
    {
        var vm = new DaemonSettingsViewModel();
        Assert.Equal("WPD-0006", vm.DecisionId);
        Assert.Equal("docs/windows-port/decisions/0006-windows-daemon-strategy.md", vm.DecisionDocPath);
    }

    [Fact]
    public void FinishLine_DefaultsToF1ShipPeer_WithScopeRows()
    {
        var vm = new DaemonSettingsViewModel();
        Assert.Equal(WindowsFinishLineScope.DefaultLabel, vm.FinishLineDefault);
        Assert.Equal(WindowsFinishLineScope.Explainer, vm.FinishLineExplainer);
        Assert.Equal(WindowsFinishLineScope.Rows, vm.FinishLineScope);
        Assert.Equal(8, vm.FinishLineScope.Count);
        Assert.All(vm.FinishLineScope, r =>
        {
            Assert.False(string.IsNullOrWhiteSpace(r.Area));
            Assert.False(string.IsNullOrWhiteSpace(r.F1ShipPeer));
            Assert.False(string.IsNullOrWhiteSpace(r.F2TrueOneToOne));
        });
        Assert.Contains(vm.FinishLineScope, r => r.Area.Equals("Chat", System.StringComparison.Ordinal));
        Assert.Contains(vm.FinishLineScope, r => r.Area.Equals("Computer Use", System.StringComparison.Ordinal));
        Assert.Contains(vm.FinishLineScope, r => r.F2TrueOneToOne.Contains("gateway", System.StringComparison.OrdinalIgnoreCase));
        Assert.Contains("exit criteria", vm.FinishLineExplainer, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void VisibleRows_DefaultToEveryCapability()
    {
        var vm = new DaemonSettingsViewModel();
        Assert.Null(vm.Filter);
        Assert.Equal(34, vm.VisibleCount);
        Assert.Equal(34, vm.VisibleRows.Count);
    }

    [Fact]
    public void Filter_NarrowsVisibleRowsToOneDisposition()
    {
        var vm = new DaemonSettingsViewModel { Filter = DaemonSubstitutionDisposition.SubstitutedAlready };

        Assert.Equal(13, vm.VisibleCount);
        Assert.All(vm.VisibleRows, r => Assert.Equal(DaemonSubstitutionDisposition.SubstitutedAlready, r.Disposition));
        Assert.Equal("Substituted already", vm.FilterLabel);
    }

    [Fact]
    public void ShowAll_ClearsTheFilter()
    {
        var vm = new DaemonSettingsViewModel { Filter = DaemonSubstitutionDisposition.Deferred };
        Assert.Equal(14, vm.VisibleCount);

        vm.ShowAll();

        Assert.Null(vm.Filter);
        Assert.Equal(34, vm.VisibleCount);
        Assert.Equal("All capabilities", vm.FilterLabel);
    }

    [Fact]
    public void FilterOptions_CoverAllPlusEachDispositionWithCounts()
    {
        var vm = new DaemonSettingsViewModel();
        Assert.Equal(5, vm.FilterOptions.Count);

        var all = vm.FilterOptions.Single(o => o.Disposition is null);
        Assert.Equal(34, all.Count);

        Assert.Equal(13, vm.FilterOptions.Single(o => o.Disposition == DaemonSubstitutionDisposition.SubstitutedAlready).Count);
        Assert.Equal(3, vm.FilterOptions.Single(o => o.Disposition == DaemonSubstitutionDisposition.SubstituteToBuild).Count);
        Assert.Equal(14, vm.FilterOptions.Single(o => o.Disposition == DaemonSubstitutionDisposition.Deferred).Count);
        Assert.Equal(4, vm.FilterOptions.Single(o => o.Disposition == DaemonSubstitutionDisposition.NotApplicable).Count);
    }
}

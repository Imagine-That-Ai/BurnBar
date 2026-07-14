// View-model for the Engine Room (Daemon) settings tab.
//
// Per the driver's WPD-0006 decision, the Windows Daemon tab does NOT hide and does
// NOT reproduce the macOS daemon-lifecycle / HTTP-gateway / controller controls
// (those are ModelProxy on Windows, or deferred). It renders the WPD-0006 per-
// capability substitution matrix: each macOS OpenBurnBarDaemon capability and its
// Windows-v1 disposition, plus the disposition summary the decision doc published.
//
// The data is static (DaemonSubstitutionMatrix); this view-model adds the observable
// disposition filter + the header/summary projection the WinUI tab binds.

using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;

namespace OpenBurnBar.App.Settings.ViewModels.Daemon;

/// <summary>The four disposition tallies, matching the WPD-0006 "Disposition summary" table.</summary>
public sealed record DaemonSubstitutionSummary(
    int SubstitutedAlready,
    int SubstituteToBuild,
    int Deferred,
    int NotApplicable)
{
    /// <summary>Total capability rows.</summary>
    public int Total => SubstitutedAlready + SubstituteToBuild + Deferred + NotApplicable;

    /// <summary>Rows that are live (or partly live) on Windows v1 today (SUB-DONE).</summary>
    public int LiveOnV1 => SubstitutedAlready;

    /// <summary>The header tally line, e.g. "34 daemon duties · 12 substituted · 3 to build · 15 deferred · 4 N/A".</summary>
    public string HeaderLine =>
        $"{Total} daemon duties · {SubstitutedAlready} substituted · {SubstituteToBuild} to build · " +
        $"{Deferred} deferred · {NotApplicable} N/A";
}

/// <summary>Backs the Engine Room tab: the WPD-0006 substitution matrix + a disposition filter.</summary>
public sealed class DaemonSettingsViewModel : ObservableSettingsViewModel
{
    private DaemonSubstitutionDisposition? _filter;

    public DaemonSettingsViewModel()
    {
        Summary = new DaemonSubstitutionSummary(
            SubstitutedAlready: DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.SubstitutedAlready),
            SubstituteToBuild: DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.SubstituteToBuild),
            Deferred: DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.Deferred),
            NotApplicable: DaemonSubstitutionMatrix.CountByPrimaryDisposition(DaemonSubstitutionDisposition.NotApplicable));
        RebuildVisibleRows();
    }

    /// <summary>The WPD-0006 decision id shown in the tab header.</summary>
    public string DecisionId => DaemonSubstitutionMatrix.DecisionId;

    /// <summary>The decision-doc path, for a "read the decision" affordance.</summary>
    public string DecisionDocPath => DaemonSubstitutionMatrix.DecisionDocPath;

    /// <summary>One-line explainer for why the tab shows a matrix instead of daemon controls.</summary>
    public string Explainer =>
        "Windows v1 does not ship a monolithic daemon (WPD-0006). Each macOS daemon " +
        "capability is substituted in-process, scheduled to build, deferred to v1.1, " +
        "or not applicable — the full disposition is below.";

    /// <summary>
    /// Default finish line for the Windows port (H0). Never say "100% parity" without naming F1 or F2.
    /// </summary>
    public string FinishLineDefault => WindowsFinishLineScope.DefaultLabel;

    /// <summary>One-line scope explainer for the Engine Room header.</summary>
    public string FinishLineExplainer => WindowsFinishLineScope.Explainer;

    /// <summary>F1 vs F2 capability rows for the Engine Room scope table.</summary>
    public IReadOnlyList<WindowsFinishLineScopeRow> FinishLineScope => WindowsFinishLineScope.Rows;

    /// <summary>The disposition tallies (matches the doc's summary table).</summary>
    public DaemonSubstitutionSummary Summary { get; }

    /// <summary>Every capability row in matrix order (unfiltered).</summary>
    public IReadOnlyList<DaemonSubstitutionRow> AllRows => DaemonSubstitutionMatrix.Rows;

    /// <summary>Rows for the current <see cref="Filter"/> (all rows when the filter is null).</summary>
    public ObservableCollection<DaemonSubstitutionRow> VisibleRows { get; } = new();

    /// <summary>Active disposition filter; <c>null</c> shows every row.</summary>
    public DaemonSubstitutionDisposition? Filter
    {
        get => _filter;
        set
        {
            if (Set(ref _filter, value))
            {
                RebuildVisibleRows();
                OnPropertyChanged(nameof(VisibleCount));
                OnPropertyChanged(nameof(FilterLabel));
            }
        }
    }

    /// <summary>Number of rows currently visible.</summary>
    public int VisibleCount => VisibleRows.Count;

    /// <summary>Human label for the active filter (e.g. "All" or "Substituted already").</summary>
    public string FilterLabel => _filter is { } f
        ? DaemonSubstitutionDispositionMetadata.Label(f)
        : "All capabilities";

    /// <summary>The chip options a segmented filter renders: an "all" entry then each disposition.</summary>
    public IReadOnlyList<DaemonDispositionFilterOption> FilterOptions { get; } = BuildFilterOptions();

    /// <summary>Clear the filter (show every capability).</summary>
    public void ShowAll() => Filter = null;

    private void RebuildVisibleRows()
    {
        VisibleRows.Clear();
        var rows = _filter is { } f ? DaemonSubstitutionMatrix.RowsWith(f) : DaemonSubstitutionMatrix.Rows;
        foreach (var row in rows)
        {
            VisibleRows.Add(row);
        }
    }

    private static IReadOnlyList<DaemonDispositionFilterOption> BuildFilterOptions()
    {
        var options = new List<DaemonDispositionFilterOption>
        {
            new(null, "All", DaemonSubstitutionMatrix.TotalCount),
        };
        foreach (var disposition in new[]
                 {
                     DaemonSubstitutionDisposition.SubstitutedAlready,
                     DaemonSubstitutionDisposition.SubstituteToBuild,
                     DaemonSubstitutionDisposition.Deferred,
                     DaemonSubstitutionDisposition.NotApplicable,
                 })
        {
            options.Add(new DaemonDispositionFilterOption(
                disposition,
                DaemonSubstitutionDispositionMetadata.Code(disposition),
                DaemonSubstitutionMatrix.CountByPrimaryDisposition(disposition)));
        }
        return options;
    }
}

/// <summary>One entry in the disposition filter (a chip: label + count, null disposition = "All").</summary>
public sealed record DaemonDispositionFilterOption(
    DaemonSubstitutionDisposition? Disposition,
    string Label,
    int Count);

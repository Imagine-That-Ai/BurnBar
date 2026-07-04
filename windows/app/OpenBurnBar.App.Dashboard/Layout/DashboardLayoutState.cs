using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Dashboard.Layout;

/// <summary>
/// The layout-switch state machine backing the WinUI dashboard's inline switcher —
/// the portable half of <c>DashboardLayoutSwitcher.swift</c> (segmented control that
/// collapses to a menu when horizontal space is tight) bound to
/// <c>settingsManager.dashboardLayout</c>. Owns the current <see cref="Selection"/>,
/// round-trips it through the shared persistence key, cycles through the concepts, and
/// answers the <c>ViewThatFits</c> "does the segmented control fit?" question so the
/// XAML can pick segmented-vs-menu. <see cref="INotifyPropertyChanged"/> so the WinUI
/// switcher can x:Bind to it.
/// </summary>
public sealed class DashboardLayoutState : INotifyPropertyChanged
{
    private DashboardLayout _selection;

    public DashboardLayoutState(DashboardLayout initial = DashboardLayoutMeta.Default)
    {
        _selection = initial;
    }

    /// <summary>Rehydrate from a persisted raw value (host reads <c>ApplicationData</c>).</summary>
    public static DashboardLayoutState FromRaw(string? raw) => new(DashboardLayoutMeta.Parse(raw));

    /// <summary>All layouts in switcher order.</summary>
    public IReadOnlyList<DashboardLayout> All => DashboardLayoutMeta.All;

    /// <summary>The currently-selected layout.</summary>
    public DashboardLayout Selection
    {
        get => _selection;
        set
        {
            if (_selection != value)
            {
                _selection = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(RawSelection));
                OnPropertyChanged(nameof(SelectionDisplayName));
                OnPropertyChanged(nameof(SelectionGlyph));
                OnPropertyChanged(nameof(IsKernelForward));
            }
        }
    }

    /// <summary>The persisted raw string for <see cref="Selection"/> (writes back on set).</summary>
    public string RawSelection
    {
        get => _selection.RawValue();
        set => Selection = DashboardLayoutMeta.Parse(value);
    }

    public string SelectionDisplayName => _selection.DisplayName();

    public string SelectionGlyph => _selection.Glyph();

    public bool IsKernelForward => _selection.IsKernelForward();

    /// <summary>Select an explicit layout (segment tap / menu pick).</summary>
    public void Select(DashboardLayout layout) => Selection = layout;

    /// <summary>Advance to the next concept, wrapping — a keyboard/cycle affordance.</summary>
    public void SelectNext() => Selection = At(IndexOf(_selection) + 1);

    /// <summary>Step to the previous concept, wrapping.</summary>
    public void SelectPrevious() => Selection = At(IndexOf(_selection) - 1);

    /// <summary>
    /// The <c>ViewThatFits</c> decision: whether the full segmented control fits in
    /// <paramref name="availableWidth"/>. When it does not, the switcher collapses to the
    /// compact menu button. <paramref name="perSegmentWidth"/> is the measured width of one
    /// segment; <paramref name="spacing"/> + <paramref name="padding"/> mirror the Swift
    /// capsule's 3pt inter-segment gap and 4pt inset.
    /// </summary>
    public bool ShouldCollapseToMenu(
        double availableWidth,
        double perSegmentWidth,
        double spacing = 3,
        double padding = 8)
    {
        int count = DashboardLayoutMeta.All.Count;
        double needed = padding + (count * perSegmentWidth) + ((count - 1) * spacing);
        return availableWidth < needed;
    }

    private static int IndexOf(DashboardLayout layout)
    {
        IReadOnlyList<DashboardLayout> all = DashboardLayoutMeta.All;
        for (int i = 0; i < all.Count; i++)
        {
            if (all[i] == layout)
            {
                return i;
            }
        }

        return 0;
    }

    private static DashboardLayout At(int index)
    {
        IReadOnlyList<DashboardLayout> all = DashboardLayoutMeta.All;
        int n = all.Count;
        int wrapped = ((index % n) + n) % n; // positive modulo for wrap-around
        return all[wrapped];
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

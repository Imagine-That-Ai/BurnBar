using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Dashboard.Layout;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Code-behind for the layout switcher. Builds the segment toggles from
/// <see cref="DashboardLayoutMeta.All"/>, mirrors the selection into the compact
/// ComboBox, collapses segmented-to-menu via <see cref="DashboardLayoutState.ShouldCollapseToMenu"/>,
/// and raises <see cref="LayoutChanged"/> so the page swaps concept + backdrop.
/// </summary>
public sealed partial class DashboardLayoutSwitcher : UserControl
{
    private const double PerSegmentWidth = 104;

    private readonly List<ToggleButton> _segments = new();
    private bool _syncing;
    private double _availableWidth = double.NaN;

    public DashboardLayoutSwitcher()
    {
        InitializeComponent();
        State = new DashboardLayoutState();
        BuildSegments();
        BuildMenu();
        State.PropertyChanged += (_, _) => SyncSelectionVisual();
        SyncSelectionVisual();
    }

    /// <summary>The portable switcher state (selection + cycle + collapse math).</summary>
    public DashboardLayoutState State { get; }

    /// <summary>Raised whenever the selected layout changes (page swaps concept + backdrop).</summary>
    public event EventHandler<DashboardLayout>? LayoutChanged;

    /// <summary>Rehydrate the selection from a persisted raw value.</summary>
    public void LoadRaw(string? raw) => State.Selection = DashboardLayoutMeta.Parse(raw);

    private void BuildSegments()
    {
        foreach (DashboardLayout layout in DashboardLayoutMeta.All)
        {
            var icon = new FontIcon
            {
                FontFamily = new FontFamily("Segoe MDL2 Assets"),
                FontSize = 12,
                Glyph = layout.Glyph(),
            };
            var label = new TextBlock
            {
                Text = layout.DisplayName(),
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            content.Children.Add(icon);
            content.Children.Add(label);

            var toggle = new ToggleButton
            {
                Content = content,
                Tag = layout,
                MinWidth = 0,
                Padding = new Thickness(12, 6, 12, 6),
            };
            AutomationProperties.SetAutomationId(toggle, $"Dashboard.Layout.{layout}");
            AutomationProperties.SetName(toggle, layout.DisplayName());
            toggle.Click += OnSegmentClick;
            _segments.Add(toggle);
            SegmentPanel.Children.Add(toggle);
        }
    }

    private void BuildMenu()
    {
        foreach (DashboardLayout layout in DashboardLayoutMeta.All)
        {
            MenuBox.Items.Add(new ComboBoxItem { Content = layout.DisplayName(), Tag = layout });
        }
    }

    private void OnSegmentClick(object sender, RoutedEventArgs e)
    {
        if (sender is ToggleButton { Tag: DashboardLayout layout })
        {
            State.Select(layout);
            RaiseChanged(layout);
        }
    }

    private void OnMenuSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing)
        {
            return;
        }

        if (MenuBox.SelectedItem is ComboBoxItem { Tag: DashboardLayout layout })
        {
            State.Select(layout);
            RaiseChanged(layout);
        }
    }

    private void RaiseChanged(DashboardLayout layout) => LayoutChanged?.Invoke(this, layout);

    private void SyncSelectionVisual()
    {
        _syncing = true;
        DashboardLayout selected = State.Selection;
        foreach (ToggleButton segment in _segments)
        {
            segment.IsChecked = segment.Tag is DashboardLayout l && l == selected;
        }

        int index = IndexOf(selected);
        if (MenuBox.SelectedIndex != index)
        {
            MenuBox.SelectedIndex = index;
        }

        _syncing = false;
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

    /// <summary>
    /// Update the switcher with the container's available width so ShouldCollapseToMenu
    /// is evaluated against the real canvas budget rather than the switcher's own clamped width.
    /// </summary>
    public void UpdateAvailableWidth(double availableWidth)
    {
        _availableWidth = availableWidth;
        ApplyCollapseState();
    }

    private void ApplyCollapseState()
    {
        double widthToEvaluate = !double.IsNaN(_availableWidth) && _availableWidth > 0
            ? _availableWidth
            : ActualWidth;

        bool collapse = State.ShouldCollapseToMenu(widthToEvaluate, PerSegmentWidth);
        SegmentedHost.Visibility = collapse ? Visibility.Collapsed : Visibility.Visible;
        MenuBox.Visibility = collapse ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        ApplyCollapseState();
    }
}

using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Dashboard;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Command-deck kernel picker — Linux <c>KernelSwitcher.tsx</c> parity.
/// Lists all <see cref="KernelCatalog.All"/> entries and persists via
/// <see cref="KernelBackdropPreferences"/>.
/// </summary>
public sealed partial class KernelSwitcherControl : UserControl
{
    private string _kernelId = KernelCatalog.DefaultId;
    private bool _building;

    public KernelSwitcherControl()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    /// <summary>Raised after the user picks a kernel (preference already written).</summary>
    public event EventHandler<string>? KernelChanged;

    public string SelectedKernelId => _kernelId;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        LiquidGlassEnvironment.PreferencesChanged += OnPreferencesChanged;
        RefreshFromPreferences();
        RebuildList();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e) =>
        LiquidGlassEnvironment.PreferencesChanged -= OnPreferencesChanged;

    private void OnPreferencesChanged(object? sender, EventArgs e) => RefreshFromPreferences();

    private void RefreshFromPreferences()
    {
        string id = KernelCatalog.Resolve(
            LiquidGlassEnvironment.Current.GetString(KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId));
        if (string.Equals(_kernelId, id, StringComparison.Ordinal))
        {
            ActiveLabel.Text = KernelCatalog.Label(id);
            return;
        }

        _kernelId = id;
        ActiveLabel.Text = KernelCatalog.Label(id);
        if (!_building)
        {
            RebuildList();
        }
    }

    private void RebuildList()
    {
        _building = true;
        KernelList.Children.Clear();
        foreach (KernelCatalogEntry entry in KernelCatalog.All)
        {
            bool selected = string.Equals(entry.Id, _kernelId, StringComparison.Ordinal);
            var btn = new Button
            {
                Tag = entry.Id,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(10, 6, 10, 6),
                CornerRadius = new CornerRadius(8),
                BorderThickness = new Thickness(0),
                Background = selected
                    ? new SolidColorBrush(Color.FromArgb(0x28, 0xFA, 0x6B, 0x06))
                    : new SolidColorBrush(Colors.Transparent),
            };
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new TextBlock
            {
                Text = selected ? "✓" : string.Empty,
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = new SolidColorBrush(Color.FromArgb(0xFF, 0xFA, 0x6B, 0x06)),
            });
            var title = new TextBlock
            {
                Text = entry.Label,
                FontSize = 12,
                FontWeight = selected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(title, 1);
            row.Children.Add(title);
            btn.Content = row;
            btn.Click += (_, _) => SelectKernel(entry.Id);
            KernelList.Children.Add(btn);
        }

        _building = false;
    }

    private void SelectKernel(string id)
    {
        string resolved = KernelCatalog.Resolve(id);
        _kernelId = resolved;
        ActiveLabel.Text = KernelCatalog.Label(resolved);

        // Ensure the master gate is on so Dashboard actually hosts WebView2.
        if (!LiquidGlassEnvironment.Current.GetBool(KernelBackdropPreferences.EnabledKey, false))
        {
            LiquidGlassEnvironment.Current.SetBool(KernelBackdropPreferences.EnabledKey, true);
        }

        LiquidGlassEnvironment.Current.SetString(KernelBackdropPreferences.KernelKey, resolved);
        RebuildList();
        KernelFlyout.Hide();
        KernelChanged?.Invoke(this, resolved);
    }
}
